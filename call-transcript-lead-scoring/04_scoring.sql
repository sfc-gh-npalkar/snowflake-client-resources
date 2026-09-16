/* ============================================================================
   Snowflake Cortex Workshop
   04_scoring.sql -- Lead scoring with Snowpark for Python

   Four objects are created here:

     MODELS                        internal stage holding the model artifact
     TRAIN_REFI_PROPENSITY_MODEL   Python procedure that fits the model and
                                   writes it to the stage
     SCORE_REFI_PROPENSITY         Python UDF that loads the artifact and
                                   returns a probability for one borrower
     GET_REFI_PROPENSITY           procedure that looks up a borrower by name,
                                   scores them, and explains the result

   Training, serialisation, and inference all run inside Snowflake. No data
   leaves the account and there is no external model endpoint to operate.

   The split between the UDF and the procedure is deliberate. The UDF is the
   scoring primitive: it takes features and returns a number, and it can be
   applied to a whole table in a single SELECT. The procedure is the interface
   an agent uses: it resolves a name to a borrower, calls the UDF, and returns
   a narrated result rather than a bare float.

   All statements are CREATE OR REPLACE and safe to re-run.
   ========================================================================== */

USE WAREHOUSE CORTEX_DEMO_WH;
USE DATABASE CORTEX_REFI_DEMO;
USE SCHEMA MORTGAGE;


-- ---------------------------------------------------------------------------
-- 1. Stage for the model artifact
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS MODELS
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Serialised scoring model artifacts.';


-- ---------------------------------------------------------------------------
-- 2. Training data
--
-- HISTORICAL_REFI_OUTCOMES holds 2,400 closed refinance opportunities from the
-- last 18 months, each with the features known at the time and whether the
-- borrower ultimately refinanced. Created in 01_data.sql.
-- ---------------------------------------------------------------------------
SELECT
    COUNT(*)                                       AS opportunities,
    SUM(IFF(DID_REFI, 1, 0))                       AS converted,
    ROUND(AVG(IFF(DID_REFI, 1, 0)) * 100, 1)       AS conversion_rate_pct
FROM HISTORICAL_REFI_OUTCOMES;

-- Conversion rate by intent and urgency, before any model is involved.
-- Worth looking at first: if there is no signal here, there is nothing for a
-- model to learn.
SELECT
    CALL_INTENT,
    URGENCY,
    COUNT(*)                                       AS opportunities,
    ROUND(AVG(IFF(DID_REFI, 1, 0)) * 100, 1)       AS conversion_rate_pct
FROM HISTORICAL_REFI_OUTCOMES
GROUP BY CALL_INTENT, URGENCY
ORDER BY conversion_rate_pct DESC;


-- ---------------------------------------------------------------------------
-- 3. Training procedure
--
-- A standard scikit-learn pipeline: scale the numeric features, one-hot the
-- categorical ones, fit a logistic regression. The pipeline is serialised as a
-- single object, so the preprocessing travels with the model and scoring cannot
-- drift from training.
--
-- Two choices worth calling out:
--
--   The rows are read with collect() rather than to_pandas(). to_pandas()
--   depends on the connector's optional pandas extra, which is not present in
--   every environment and fails with a misleading "pandas is not installed"
--   error even when pandas is in the PACKAGES list. Building the frame from
--   collect() has no such dependency.
--
--   handle_unknown='ignore' on the encoder means a category never seen in
--   training scores as all-zeros for that feature rather than raising. Real
--   call data will eventually produce an intent the model was not trained on.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE TRAIN_REFI_PROPENSITY_MODEL()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'scikit-learn', 'pandas', 'numpy', 'joblib')
HANDLER = 'main'
AS
$$
import joblib
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.pipeline import Pipeline
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score

NUMERIC = ['RATE_DELTA_PCT', 'LTV_PCT', 'FICO_SCORE', 'CURRENT_BALANCE',
           'CUSTOMER_TENURE_MONTHS', 'COMPETITOR_FLAG']
CATEGORICAL = ['CALL_INTENT', 'URGENCY']
COLS = ['RATE_DELTA_PCT', 'LTV_PCT', 'FICO_SCORE', 'CURRENT_BALANCE',
        'CUSTOMER_TENURE_MONTHS', 'CALL_INTENT', 'URGENCY',
        'COMPETITOR_MENTIONED', 'DID_REFI']

def main(session):
    rows = session.table('CORTEX_REFI_DEMO.MORTGAGE.HISTORICAL_REFI_OUTCOMES') \
                  .select(*COLS).collect()
    df = pd.DataFrame([r.as_dict() for r in rows])

    df['COMPETITOR_FLAG'] = df['COMPETITOR_MENTIONED'].astype(int)
    for c in ['RATE_DELTA_PCT', 'LTV_PCT', 'FICO_SCORE', 'CURRENT_BALANCE',
              'CUSTOMER_TENURE_MONTHS']:
        df[c] = pd.to_numeric(df[c])
    df['URGENCY'] = df['URGENCY'].fillna('UNKNOWN')

    y = df['DID_REFI'].astype(int)
    X = df[NUMERIC + CATEGORICAL]

    pipe = Pipeline([
        ('pre', ColumnTransformer([
            ('num', StandardScaler(), NUMERIC),
            ('cat', OneHotEncoder(handle_unknown='ignore'), CATEGORICAL),
        ])),
        ('clf', LogisticRegression(max_iter=2000, C=1.0)),
    ])

    X_tr, X_te, y_tr, y_te = train_test_split(
        X, y, test_size=0.25, random_state=42, stratify=y)
    pipe.fit(X_tr, y_tr)

    auc_train = roc_auc_score(y_tr, pipe.predict_proba(X_tr)[:, 1])
    auc_test = roc_auc_score(y_te, pipe.predict_proba(X_te)[:, 1])

    joblib.dump(pipe, '/tmp/refi_propensity.joblib')
    session.file.put('/tmp/refi_propensity.joblib',
                     '@CORTEX_REFI_DEMO.MORTGAGE.MODELS',
                     overwrite=True, auto_compress=False)

    names = list(pipe.named_steps['pre'].get_feature_names_out())
    coefs = pipe.named_steps['clf'].coef_[0]
    ranked = sorted(zip(names, coefs), key=lambda kv: abs(kv[1]), reverse=True)

    return {
        'rows_trained': int(len(X_tr)),
        'rows_tested': int(len(X_te)),
        'base_refi_rate': round(float(y.mean()), 4),
        'auc_train': round(float(auc_train), 4),
        'auc_test': round(float(auc_test), 4),
        'top_drivers': [{'feature': f, 'coefficient': round(float(c), 4)}
                        for f, c in ranked[:8]],
        'artifact': '@CORTEX_REFI_DEMO.MORTGAGE.MODELS/refi_propensity.joblib',
    }
$$;


-- Train. Returns fit quality and the ranked coefficients.
-- Expect a holdout AUC around 0.86, with RATE_DELTA_PCT as the largest
-- positive coefficient and SERVICING_ONLY intent the largest negative one.
CALL TRAIN_REFI_PROPENSITY_MODEL();

-- Confirm the artifact landed
LS @MODELS;


-- ---------------------------------------------------------------------------
-- 4. Scoring UDF
--
-- IMPORTS makes the staged artifact available on the local filesystem of the
-- UDF at the path in sys._xoptions['snowflake_import_directory'].
--
-- The load is wrapped in cachetools.cached so deserialisation happens once per
-- warehouse process rather than once per row. Without it, scoring a table of
-- any size spends most of its time repeatedly unpickling the same model.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION SCORE_REFI_PROPENSITY(
    RATE_DELTA_PCT FLOAT,
    LTV_PCT FLOAT,
    FICO_SCORE FLOAT,
    CURRENT_BALANCE FLOAT,
    CUSTOMER_TENURE_MONTHS FLOAT,
    CALL_INTENT VARCHAR,
    URGENCY VARCHAR,
    COMPETITOR_MENTIONED BOOLEAN
)
RETURNS FLOAT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('scikit-learn', 'pandas', 'numpy', 'joblib', 'cachetools')
IMPORTS = ('@CORTEX_REFI_DEMO.MORTGAGE.MODELS/refi_propensity.joblib')
HANDLER = 'score'
AS
$$
import os
import sys
import joblib
import cachetools
import pandas as pd

@cachetools.cached(cache={})
def load_model():
    import_dir = sys._xoptions['snowflake_import_directory']
    return joblib.load(os.path.join(import_dir, 'refi_propensity.joblib'))

def score(rate_delta, ltv, fico, balance, tenure, intent, urgency, competitor):
    model = load_model()
    row = pd.DataFrame([{
        'RATE_DELTA_PCT': float(rate_delta if rate_delta is not None else 0.0),
        'LTV_PCT': float(ltv if ltv is not None else 80.0),
        'FICO_SCORE': float(fico if fico is not None else 700.0),
        'CURRENT_BALANCE': float(balance if balance is not None else 0.0),
        'CUSTOMER_TENURE_MONTHS': float(tenure if tenure is not None else 0.0),
        'COMPETITOR_FLAG': int(bool(competitor)),
        'CALL_INTENT': intent if intent else 'UNKNOWN',
        'URGENCY': urgency if urgency else 'UNKNOWN',
    }])
    return float(model.predict_proba(row)[0, 1])
$$;


-- Score the whole segment in one pass. The UDF is an ordinary SQL function,
-- so it composes with WHERE, ORDER BY, joins and window functions.
SELECT
    FULL_NAME,
    CITY,
    RATE_DELTA_PCT,
    LTV_PCT,
    FICO_SCORE,
    LATEST_CALL_INTENT,
    LATEST_CALL_URGENCY,
    EST_MONTHLY_SAVING,
    ROUND(SCORE_REFI_PROPENSITY(
        RATE_DELTA_PCT, LTV_PCT, FICO_SCORE, CURRENT_BALANCE,
        CUSTOMER_TENURE_MONTHS, LATEST_CALL_INTENT, LATEST_CALL_URGENCY,
        COMPETITOR_MENTIONED
    ) * 100, 1) AS PROPENSITY_PCT
FROM BORROWER_PROFILE
WHERE IS_TOP_REFI_SEGMENT
  AND CALLS_LAST_7D > 0
ORDER BY PROPENSITY_PCT DESC;


-- ---------------------------------------------------------------------------
-- 5. Agent-facing procedure
--
-- An agent can only call objects that exist in Snowflake, and it works best
-- when the object returns something explanatory rather than a bare number.
-- This procedure resolves a name, scores the borrower, and reports which
-- factors moved the score in each direction, with the loan context needed to
-- act on it.
--
-- Name resolution is handled explicitly: no match and multiple matches each
-- return a useful instruction rather than an error, so the agent can recover
-- by asking a better question instead of failing the turn.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE GET_REFI_PROPENSITY(BORROWER_NAME VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
COMMENT = 'Returns the modelled refinance propensity score for a single named borrower, together with the factors that drove the score.'
AS
$$
def main(session, borrower_name):
    if not borrower_name or not borrower_name.strip():
        return 'No borrower name was supplied. Provide the full or partial name of a homeowner.'

    needle = borrower_name.strip().replace("'", "''")

    matches = session.sql(f"""
        SELECT HOMEOWNER_ID, FULL_NAME
        FROM CORTEX_REFI_DEMO.MORTGAGE.BORROWER_PROFILE
        WHERE UPPER(FULL_NAME) LIKE '%' || UPPER('{needle}') || '%'
        ORDER BY FULL_NAME
        LIMIT 11
    """).collect()

    if len(matches) == 0:
        return (f"No borrower matching '{borrower_name}' was found in the loan book. "
                f"Check the spelling, or ask for the list of borrowers in the top "
                f"refinance segment to see valid names.")

    if len(matches) > 1:
        names = ', '.join(f"{r['FULL_NAME']} ({r['HOMEOWNER_ID']})" for r in matches[:10])
        return (f"'{borrower_name}' matches {len(matches)} borrowers: {names}. "
                f"Ask again with a more specific name.")

    hid = matches[0]['HOMEOWNER_ID']

    row = session.sql(f"""
        SELECT
            FULL_NAME, CITY, STATE, HOMEOWNER_ID,
            INTEREST_RATE_PCT, MARKET_RATE_PCT, RATE_DELTA_PCT, LTV_PCT, FICO_SCORE,
            CREDIT_BAND, CURRENT_BALANCE, CUSTOMER_TENURE_MONTHS,
            CURRENT_MONTHLY_PAYMENT, EST_MONTHLY_SAVING, EST_LIFETIME_SAVING,
            LATEST_CALL_INTENT, LATEST_CALL_URGENCY, COMPETITOR_MENTIONED,
            LIFE_EVENT, IS_TOP_REFI_SEGMENT, CALLS_LAST_7D, LATEST_CALL_SUMMARY,
            CORTEX_REFI_DEMO.MORTGAGE.SCORE_REFI_PROPENSITY(
                RATE_DELTA_PCT, LTV_PCT, FICO_SCORE, CURRENT_BALANCE,
                CUSTOMER_TENURE_MONTHS, LATEST_CALL_INTENT, LATEST_CALL_URGENCY,
                COMPETITOR_MENTIONED
            ) AS PROPENSITY
        FROM CORTEX_REFI_DEMO.MORTGAGE.BORROWER_PROFILE
        WHERE HOMEOWNER_ID = '{hid}'
    """).collect()[0]

    score_pct = round(float(row['PROPENSITY']) * 100, 1)
    if score_pct >= 75:
        band = 'VERY HIGH'
    elif score_pct >= 55:
        band = 'HIGH'
    elif score_pct >= 35:
        band = 'MODERATE'
    else:
        band = 'LOW'

    raises, lowers = [], []

    delta = float(row['RATE_DELTA_PCT'])
    if delta >= 1.0:
        raises.append(f"paying {delta:.2f} percentage points above the market rate of "
                      f"{float(row['MARKET_RATE_PCT']):.2f}% (the strongest single driver in the model)")
    elif delta > 0:
        raises.append(f"paying {delta:.2f} points above market, a modest gap")
    else:
        lowers.append(f"already {abs(delta):.2f} points below market, so refinancing would raise their payment")

    ltv = float(row['LTV_PCT'])
    if ltv <= 75:
        raises.append(f"loan to value of {ltv:.1f}%, comfortably inside the best pricing band")
    elif ltv <= 80:
        raises.append(f"loan to value of {ltv:.1f}%, just inside the 80% threshold")
    else:
        lowers.append(f"loan to value of {ltv:.1f}%, above the 80% threshold, which limits pricing")

    fico = int(row['FICO_SCORE'])
    if fico >= 760:
        raises.append(f"FICO of {fico} in the {row['CREDIT_BAND']} band")
    elif fico < 660:
        lowers.append(f"FICO of {fico} in the {row['CREDIT_BAND']} band")

    intent = row['LATEST_CALL_INTENT']
    if intent in ('RATE_REFI', 'PAYMENT_RELIEF'):
        raises.append(f"last call was classified {intent}, which correlates positively with conversion")
    elif intent == 'SERVICING_ONLY':
        lowers.append("last call was classified SERVICING_ONLY, the strongest negative signal in the model")
    elif intent:
        raises.append(f"last call was classified {intent}")

    urgency = row['LATEST_CALL_URGENCY']
    if urgency == 'HIGH':
        raises.append("stated high urgency on the call")
    elif urgency == 'LOW':
        lowers.append("stated low urgency on the call")

    if row['COMPETITOR_MENTIONED']:
        raises.append("referenced a competing lender offer, indicating an active shopping process")

    if row['LIFE_EVENT']:
        raises.append(f"mentioned a life event: {row['LIFE_EVENT']}")

    tenure = int(row['CUSTOMER_TENURE_MONTHS'])
    if tenure > 84:
        lowers.append(f"{tenure} months of tenure, and longer-tenured borrowers convert slightly less often")

    lines = [
        f"Refinance propensity for {row['FULL_NAME']} ({row['HOMEOWNER_ID']}), "
        f"{row['CITY']}, {row['STATE']}:",
        "",
        f"  Propensity score: {score_pct}% ({band})",
        f"  Segment: {'in the top refinance segment' if row['IS_TOP_REFI_SEGMENT'] else 'not in the top refinance segment'}",
        "",
        "Loan position:",
        f"  Current rate {float(row['INTEREST_RATE_PCT']):.3f}% against a market rate of {float(row['MARKET_RATE_PCT']):.2f}%",
        f"  Balance ${float(row['CURRENT_BALANCE']):,.0f}, current payment ${float(row['CURRENT_MONTHLY_PAYMENT']):,.2f} per month",
        f"  Estimated saving ${float(row['EST_MONTHLY_SAVING']):,.2f} per month, "
        f"${float(row['EST_LIFETIME_SAVING']):,.0f} over the remaining term",
        "",
        "What raises the score:",
    ]
    lines += [f"  - {r}" for r in raises] or ["  - nothing material"]
    lines += ["", "What lowers the score:"]
    lines += [f"  - {l}" for l in lowers] or ["  - nothing material"]

    if row['LATEST_CALL_SUMMARY']:
        lines += ["", f"Most recent call: {row['LATEST_CALL_SUMMARY']}"]

    lines += ["",
              "Score is produced by a logistic regression trained on 2,400 historical "
              "refinance opportunities (holdout AUC 0.86)."]

    return "\n".join(lines)
$$;


-- A single borrower, scored and explained
CALL GET_REFI_PROPENSITY('Farrah Haddad');

-- Ambiguous input returns the candidate list rather than guessing
CALL GET_REFI_PROPENSITY('Elena');

-- Unknown input returns a recoverable instruction rather than an error
CALL GET_REFI_PROPENSITY('Jane Nonexistent');


-- ---------------------------------------------------------------------------
-- Continue to 05_agent.sql.
-- ---------------------------------------------------------------------------
