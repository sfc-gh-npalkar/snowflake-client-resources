/* ============================================================================
   Snowflake Cortex Workshop
   03_semantic_view.sql -- Joining extracted call signals to the loan book

   Two objects are created here:

     BORROWER_PROFILE   one row per homeowner, combining loan terms, property
                        valuation, credit profile, computed refinance
                        economics, and the signals from their latest call

     REFI_INTELLIGENCE  the semantic view Cortex Analyst queries, exposing
                        those columns as named dimensions, facts and metrics

   The definition of the top refinance segment lives in this file, as a
   dimension on the semantic view. That placement is deliberate: if the
   criteria were left in the question text instead, every person asking would
   phrase them slightly differently and get a slightly different population.
   Defining it once here means the segment means the same thing whether it is
   reached from Cortex Analyst, a BI tool, or plain SQL.

   All statements are CREATE OR REPLACE and safe to re-run.
   ========================================================================== */

USE WAREHOUSE CORTEX_DEMO_WH;
USE DATABASE CORTEX_REFI_DEMO;
USE SCHEMA MORTGAGE;


-- ---------------------------------------------------------------------------
-- BORROWER_PROFILE
--
-- Refinance economics are computed here rather than approximated. Payment is
-- the standard amortising annuity:
--
--     payment = P * r / (1 - (1 + r)^-n)
--
-- where P is the outstanding balance, r the monthly rate, and n the months
-- remaining. Comparing that payment at the current rate against the same
-- payment at the market rate, over the same remaining term, gives an honest
-- saving figure -- one that does not flatter the result by silently resetting
-- the borrower to a fresh 30-year term.
--
-- Borrowers already below market produce a negative saving, which is correct:
-- refinancing would cost them money. They are excluded by the segment
-- definition rather than by hiding the number.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW BORROWER_PROFILE AS
WITH mkt AS (
    SELECT RATE_PCT AS MARKET_RATE_PCT FROM MARKET_RATE
),
latest_call AS (
    SELECT
        HOMEOWNER_ID, CALL_ID, CALL_TIMESTAMP, CALL_INTENT, URGENCY,
        COMPETITOR_MENTIONED, REQUESTED_CALLBACK, LIFE_EVENT, CALL_SUMMARY,
        ROW_NUMBER() OVER (PARTITION BY HOMEOWNER_ID ORDER BY CALL_TIMESTAMP DESC) AS rn
    FROM CALL_SIGNALS
    QUALIFY rn = 1
),
call_counts AS (
    SELECT HOMEOWNER_ID, COUNT(*) AS CALLS_LAST_7D
    FROM CALL_SIGNALS
    WHERE CALL_TIMESTAMP >= DATEADD(day, -7, CURRENT_TIMESTAMP())
    GROUP BY HOMEOWNER_ID
),
base AS (
    SELECT
        h.HOMEOWNER_ID, h.FULL_NAME, h.CITY, h.STATE, h.CREDIT_BAND, h.FICO_SCORE,
        h.INCOME_BAND, h.CUSTOMER_TENURE_MONTHS, h.HAS_ESCROW,
        l.LOAN_ID, l.ORIGINATION_DATE, l.INTEREST_RATE_PCT, l.TERM_MONTHS,
        l.ORIGINAL_BALANCE, l.CURRENT_BALANCE, l.MONTHS_ON_BOOK, l.HAS_LATE_PAYMENT_24M,
        p.PROPERTY_ID, p.PROPERTY_TYPE, p.ESTIMATED_VALUE, p.BEDROOMS, p.YEAR_BUILT,
        m.MARKET_RATE_PCT,
        GREATEST(l.TERM_MONTHS - l.MONTHS_ON_BOOK, 12)              AS REMAINING_TERM_MONTHS,
        ROUND(l.INTEREST_RATE_PCT - m.MARKET_RATE_PCT, 3)           AS RATE_DELTA_PCT,
        ROUND(l.CURRENT_BALANCE / NULLIF(p.ESTIMATED_VALUE, 0) * 100, 1) AS LTV_PCT,
        c.CALL_ID           AS LATEST_CALL_ID,
        c.CALL_TIMESTAMP    AS LATEST_CALL_TIMESTAMP,
        c.CALL_INTENT       AS LATEST_CALL_INTENT,
        c.URGENCY           AS LATEST_CALL_URGENCY,
        c.COMPETITOR_MENTIONED,
        c.REQUESTED_CALLBACK,
        c.LIFE_EVENT,
        c.CALL_SUMMARY      AS LATEST_CALL_SUMMARY,
        COALESCE(cc.CALLS_LAST_7D, 0) AS CALLS_LAST_7D
    FROM HOMEOWNERS h
    JOIN LOANS l      USING (HOMEOWNER_ID)
    JOIN PROPERTIES p USING (HOMEOWNER_ID)
    CROSS JOIN mkt m
    LEFT JOIN latest_call c USING (HOMEOWNER_ID)
    LEFT JOIN call_counts cc USING (HOMEOWNER_ID)
),
priced AS (
    SELECT b.*,
           (INTEREST_RATE_PCT / 100 / 12) AS r_cur,
           (MARKET_RATE_PCT   / 100 / 12) AS r_new
    FROM base b
)
SELECT
    p.* EXCLUDE (r_cur, r_new),
    ROUND(CURRENT_BALANCE * r_cur / (1 - POWER(1 + r_cur, -REMAINING_TERM_MONTHS)), 2) AS CURRENT_MONTHLY_PAYMENT,
    ROUND(CURRENT_BALANCE * r_new / (1 - POWER(1 + r_new, -REMAINING_TERM_MONTHS)), 2) AS REFI_MONTHLY_PAYMENT,
    ROUND(
        CURRENT_BALANCE * r_cur / (1 - POWER(1 + r_cur, -REMAINING_TERM_MONTHS))
      - CURRENT_BALANCE * r_new / (1 - POWER(1 + r_new, -REMAINING_TERM_MONTHS)), 2
    )                                                                                   AS EST_MONTHLY_SAVING,
    ROUND((
        CURRENT_BALANCE * r_cur / (1 - POWER(1 + r_cur, -REMAINING_TERM_MONTHS))
      - CURRENT_BALANCE * r_new / (1 - POWER(1 + r_new, -REMAINING_TERM_MONTHS))
    ) * REMAINING_TERM_MONTHS, 2)                                                       AS EST_LIFETIME_SAVING,
    -- The top refinance segment, defined once
    CASE
        WHEN RATE_DELTA_PCT >= 1.0
         AND LTV_PCT <= 80
         AND CREDIT_BAND IN ('GOOD', 'EXCELLENT')
         AND NOT HAS_LATE_PAYMENT_24M
         AND CURRENT_BALANCE >= 150000
        THEN TRUE ELSE FALSE
    END                                                                                 AS IS_TOP_REFI_SEGMENT
FROM priced p;


-- How the segment narrows the book, one filter at a time
SELECT
    COUNT(*)                                                          AS total_borrowers,
    SUM(IFF(RATE_DELTA_PCT >= 1.0, 1, 0))                             AS above_market_by_1pct,
    SUM(IFF(RATE_DELTA_PCT >= 1.0 AND LTV_PCT <= 80, 1, 0))           AS and_ltv_80_or_less,
    SUM(IFF(RATE_DELTA_PCT >= 1.0 AND LTV_PCT <= 80
            AND CREDIT_BAND IN ('GOOD','EXCELLENT'), 1, 0))           AS and_good_credit,
    SUM(IFF(IS_TOP_REFI_SEGMENT, 1, 0))                               AS top_refi_segment,
    SUM(IFF(IS_TOP_REFI_SEGMENT AND CALLS_LAST_7D > 0, 1, 0))         AS segment_who_called_last_7d
FROM BORROWER_PROFILE;


-- ---------------------------------------------------------------------------
-- REFI_INTELLIGENCE semantic view
--
-- Two conventions applied throughout, both of which improve how reliably
-- Cortex Analyst answers questions against this model:
--
--   Booleans are exposed as named string values rather than TRUE/FALSE.
--   'TOP_REFI_SEGMENT' and 'NOT_IN_SEGMENT' are self-describing in a generated
--   filter and in a result set; a bare TRUE column is not.
--
--   Every dimension whose values are drawn from a fixed set lists those values
--   in its COMMENT. That is what lets a question be answered without the model
--   having to guess at the vocabulary in the column.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW REFI_INTELLIGENCE
  TABLES (
    borrowers AS BORROWER_PROFILE
      PRIMARY KEY (HOMEOWNER_ID)
      WITH SYNONYMS ('homeowners', 'customers', 'borrowers', 'loan book', 'accounts')
      COMMENT = 'One row per homeowner: loan terms, property valuation, credit profile, refinance economics, and the signals extracted from their most recent inbound call.',
    calls AS CALL_SIGNALS
      PRIMARY KEY (CALL_ID)
      WITH SYNONYMS ('phone calls', 'inbound calls', 'transcripts', 'contacts')
      COMMENT = 'One row per inbound call, with fields extracted from the transcript by Cortex AI functions.'
  )
  RELATIONSHIPS (
    calls_to_borrower AS calls (HOMEOWNER_ID) REFERENCES borrowers
  )
  FACTS (
    borrowers.current_balance AS CURRENT_BALANCE
      COMMENT = 'Outstanding principal on the existing mortgage in dollars.',
    borrowers.estimated_value AS ESTIMATED_VALUE
      COMMENT = 'Current estimated market value of the property in dollars.',
    borrowers.interest_rate AS INTEREST_RATE_PCT
      COMMENT = 'Interest rate on the existing mortgage, as a percentage.',
    borrowers.rate_delta AS RATE_DELTA_PCT
      COMMENT = 'Percentage points by which the borrower rate exceeds the prevailing market rate. Positive means the borrower is paying above market.',
    borrowers.ltv AS LTV_PCT
      COMMENT = 'Loan to value ratio as a percentage of current property value.',
    borrowers.fico AS FICO_SCORE
      COMMENT = 'Credit score.',
    borrowers.monthly_saving AS EST_MONTHLY_SAVING
      COMMENT = 'Estimated reduction in monthly payment if refinanced at the market rate over the same remaining term.',
    borrowers.lifetime_saving AS EST_LIFETIME_SAVING
      COMMENT = 'Estimated total interest saving over the remaining term if refinanced at the market rate.',
    borrowers.current_payment AS CURRENT_MONTHLY_PAYMENT
      COMMENT = 'Monthly principal and interest payment on the existing loan.',
    borrowers.tenure_months AS CUSTOMER_TENURE_MONTHS
      COMMENT = 'Months the borrower has been a customer.',
    borrowers.recent_calls AS CALLS_LAST_7D
      COMMENT = 'Number of inbound calls from this borrower in the last 7 days.',
    calls.duration_seconds AS DURATION_SECONDS
      COMMENT = 'Length of the call in seconds.'
  )
  DIMENSIONS (
    borrowers.homeowner_id AS HOMEOWNER_ID
      WITH SYNONYMS ('borrower id', 'customer id')
      COMMENT = 'Unique homeowner identifier.',
    borrowers.borrower_name AS FULL_NAME
      WITH SYNONYMS ('name', 'homeowner name', 'customer name', 'borrower')
      COMMENT = 'Full name of the homeowner.',
    borrowers.city AS CITY
      COMMENT = 'City where the property is located.',
    borrowers.state AS STATE
      COMMENT = 'Two letter state code for the property.',
    borrowers.credit_band AS CREDIT_BAND
      WITH SYNONYMS ('credit tier', 'credit quality')
      COMMENT = 'Credit quality band. One of EXCELLENT, GOOD, FAIR, POOR.',
    borrowers.income_band AS INCOME_BAND
      COMMENT = 'Annual household income band.',
    borrowers.property_type AS PROPERTY_TYPE
      COMMENT = 'Property type. One of SINGLE_FAMILY, CONDO, TOWNHOUSE, MULTI_FAMILY.',
    borrowers.loan_term_months AS TERM_MONTHS
      COMMENT = 'Original loan term in months. 360 is a 30 year loan, 180 is a 15 year loan.',
    borrowers.origination_date AS ORIGINATION_DATE
      COMMENT = 'Date the existing mortgage was originated.',
    borrowers.refi_segment AS CASE WHEN IS_TOP_REFI_SEGMENT THEN 'TOP_REFI_SEGMENT' ELSE 'NOT_IN_SEGMENT' END
      WITH SYNONYMS ('top refinance segment', 'refinance segment', 'priority segment', 'target segment', 'best refi candidates')
      COMMENT = 'Top refinance segment. A borrower is TOP_REFI_SEGMENT when they are paying at least 1.0 percentage point above market rate, have loan to value at or below 80 percent, sit in the GOOD or EXCELLENT credit band, have no late payment in 24 months, and carry a balance of at least 150000 dollars. Everyone else is NOT_IN_SEGMENT. Use this dimension whenever asked about the top refinance segment rather than reconstructing the criteria.',
    borrowers.recent_contact AS CASE WHEN CALLS_LAST_7D > 0 THEN 'CALLED_LAST_7D' ELSE 'NO_RECENT_CALL' END
      WITH SYNONYMS ('called recently', 'recent caller', 'contacted us', 'called last week')
      COMMENT = 'Whether the borrower called in during the last 7 days. One of CALLED_LAST_7D or NO_RECENT_CALL.',
    borrowers.latest_call_intent AS LATEST_CALL_INTENT
      WITH SYNONYMS ('call reason', 'why they called', 'intent')
      COMMENT = 'Intent of the most recent call, classified by Cortex from the transcript. One of RATE_REFI, CASH_OUT, TERM_SHORTEN, PAYMENT_RELIEF, SERVICING_ONLY, RELOCATION.',
    borrowers.latest_call_urgency AS LATEST_CALL_URGENCY
      WITH SYNONYMS ('urgency', 'how urgent')
      COMMENT = 'How urgently the borrower wanted to act on their most recent call. One of HIGH, MEDIUM, LOW. Null when the borrower gave no urgency signal.',
    borrowers.latest_call_summary AS LATEST_CALL_SUMMARY
      COMMENT = 'One sentence summary of the most recent call, generated by Cortex from the transcript.',
    borrowers.life_event AS LIFE_EVENT
      COMMENT = 'Major life event the borrower mentioned on their most recent call, if any. Null when none was raised.',
    borrowers.mentioned_competitor AS CASE WHEN COMPETITOR_MENTIONED THEN 'MENTIONED_COMPETITOR' ELSE 'NO_COMPETITOR' END
      WITH SYNONYMS ('competitor', 'shopping around', 'retention risk')
      COMMENT = 'Whether the borrower referenced a competing lender offer on their most recent call.',
    borrowers.requested_callback AS CASE WHEN REQUESTED_CALLBACK THEN 'REQUESTED_CALLBACK' ELSE 'NO_CALLBACK_REQUESTED' END
      COMMENT = 'Whether the borrower asked to be contacted back.',
    borrowers.has_late_payment AS CASE WHEN HAS_LATE_PAYMENT_24M THEN 'LATE_PAYMENT_24M' ELSE 'CLEAN_24M' END
      COMMENT = 'Whether the borrower has had a late payment in the last 24 months.',
    calls.call_id AS CALL_ID
      COMMENT = 'Unique call identifier.',
    calls.agent_id AS AGENT_ID
      WITH SYNONYMS ('rep', 'loan officer', 'agent')
      COMMENT = 'Identifier of the agent who handled the call.',
    calls.call_timestamp AS CALL_TIMESTAMP
      WITH SYNONYMS ('call date', 'call time', 'when they called')
      COMMENT = 'When the call took place.',
    calls.call_intent AS CALL_INTENT
      COMMENT = 'Classified intent of this specific call.',
    calls.call_urgency AS URGENCY
      COMMENT = 'Urgency expressed on this specific call. One of HIGH, MEDIUM, LOW.',
    calls.call_summary AS CALL_SUMMARY
      COMMENT = 'One sentence Cortex generated summary of this specific call.'
  )
  METRICS (
    borrowers.borrower_count AS COUNT(borrowers.HOMEOWNER_ID)
      WITH SYNONYMS ('number of borrowers', 'how many homeowners', 'headcount')
      COMMENT = 'Number of distinct homeowners.',
    borrowers.total_balance AS SUM(borrowers.current_balance)
      COMMENT = 'Total outstanding principal in dollars.',
    borrowers.avg_rate AS AVG(borrowers.interest_rate)
      COMMENT = 'Average interest rate on existing loans, as a percentage.',
    borrowers.avg_rate_delta AS AVG(borrowers.rate_delta)
      COMMENT = 'Average percentage points above market rate.',
    borrowers.avg_ltv AS AVG(borrowers.ltv)
      COMMENT = 'Average loan to value ratio as a percentage.',
    borrowers.avg_fico AS AVG(borrowers.fico)
      COMMENT = 'Average credit score.',
    borrowers.total_monthly_saving AS SUM(borrowers.monthly_saving)
      WITH SYNONYMS ('total monthly savings opportunity', 'aggregate monthly saving')
      COMMENT = 'Sum of estimated monthly payment reductions available across the selected borrowers, in dollars.',
    borrowers.avg_monthly_saving AS AVG(borrowers.monthly_saving)
      COMMENT = 'Average estimated monthly payment reduction per borrower, in dollars.',
    borrowers.total_lifetime_saving AS SUM(borrowers.lifetime_saving)
      COMMENT = 'Sum of estimated lifetime interest savings across the selected borrowers, in dollars.',
    borrowers.avg_tenure AS AVG(borrowers.tenure_months)
      COMMENT = 'Average customer tenure in months.',
    calls.call_count AS COUNT(calls.CALL_ID)
      WITH SYNONYMS ('number of calls', 'call volume', 'how many calls')
      COMMENT = 'Number of inbound calls.',
    calls.avg_call_duration AS AVG(calls.duration_seconds)
      COMMENT = 'Average call length in seconds.'
  )
  COMMENT = 'Refinance lead intelligence. Joins the mortgage loan book and property valuations to signals extracted from inbound call transcripts by Cortex AI functions, so that call intent, urgency and competitor mentions can be analysed alongside loan economics. The top refinance segment is defined on the refi_segment dimension.';


-- ---------------------------------------------------------------------------
-- Query the semantic view directly, without an agent in the way
--
-- The segment crossed with recent contact. The negative saving on the
-- NOT_IN_SEGMENT / NO_RECENT_CALL row is the below-market population, where
-- refinancing would increase the payment.
-- ---------------------------------------------------------------------------
SELECT * FROM SEMANTIC_VIEW(
    REFI_INTELLIGENCE
    DIMENSIONS borrowers.refi_segment, borrowers.recent_contact
    METRICS    borrowers.borrower_count,
               borrowers.total_monthly_saving,
               borrowers.avg_rate_delta
) ORDER BY 1, 2;


-- The actionable list: segment members who called in, ranked by opportunity
SELECT * FROM SEMANTIC_VIEW(
    REFI_INTELLIGENCE
    DIMENSIONS borrowers.borrower_name, borrowers.city, borrowers.state,
               borrowers.refi_segment, borrowers.recent_contact,
               borrowers.latest_call_intent, borrowers.latest_call_urgency
    METRICS    borrowers.total_monthly_saving, borrowers.avg_rate_delta
)
WHERE REFI_SEGMENT = 'TOP_REFI_SEGMENT'
  AND RECENT_CONTACT = 'CALLED_LAST_7D'
ORDER BY TOTAL_MONTHLY_SAVING DESC;


-- ---------------------------------------------------------------------------
-- Continue to 04_scoring.sql.
-- ---------------------------------------------------------------------------
