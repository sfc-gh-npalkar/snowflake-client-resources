/* ============================================================================
   Snowflake Cortex Workshop
   06_verified_query.sql -- Bringing the score into the semantic layer,
                            and locking answers in with verified queries

   Two changes here:

     BORROWER_SCORED     adds the modelled propensity score as a column on the
                         borrower profile, so it becomes part of the governed
                         semantic layer rather than something only reachable
                         through a tool call

     AI_VERIFIED_QUERIES attaches reviewed SQL to specific questions on the
                         semantic view

   A verified query is a question paired with SQL that a human has confirmed is
   correct. When a question matches, Cortex Analyst uses the reviewed SQL rather
   than generating new SQL, so the answer is the same every time it is asked.
   Verified queries also inform generation for related questions that are not
   exact matches.

   Note the division of labour once both exist:

     "Rank the segment by propensity"          -> semantic view, verified query
     "Why is this borrower's score 87%?"       -> the scoring procedure

   Ranking is a set operation and belongs in the semantic layer. Explaining one
   score is a per-borrower narrative and belongs in the procedure. Both read the
   same model, so the numbers agree.

   All statements are CREATE OR REPLACE and safe to re-run.
   ========================================================================== */

USE WAREHOUSE CORTEX_DEMO_WH;
USE DATABASE CORTEX_REFI_DEMO;
USE SCHEMA MORTGAGE;


-- ---------------------------------------------------------------------------
-- 1. Add the score to the borrower profile
--
-- The UDF is applied here rather than materialised into a table, so the score
-- always reflects the current model artifact. Retrain and every downstream
-- answer moves with it, with no rebuild step.
--
-- If the volume of borrowers ever made per-query inference too expensive, this
-- becomes a table refreshed on a schedule, or a dynamic table. The semantic
-- view above it would not change.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW BORROWER_SCORED AS
SELECT
    p.*,
    ROUND(SCORE_REFI_PROPENSITY(
        RATE_DELTA_PCT, LTV_PCT, FICO_SCORE, CURRENT_BALANCE,
        CUSTOMER_TENURE_MONTHS, LATEST_CALL_INTENT, LATEST_CALL_URGENCY,
        COMPETITOR_MENTIONED) * 100, 1) AS PROPENSITY_PCT
FROM BORROWER_PROFILE p;


-- ---------------------------------------------------------------------------
-- 2. Rebuild the semantic view over the scored profile, with verified queries
--
-- Changes from the version in 03_semantic_view.sql:
--   base table is BORROWER_SCORED rather than BORROWER_PROFILE
--   a propensity fact, plus avg_propensity and max_propensity metrics
--   SAMPLE_VALUES and IS_ENUM on the closed-vocabulary dimensions
--   an AI_VERIFIED_QUERIES clause
--
-- SAMPLE_VALUES with IS_ENUM tells Cortex Analyst that the listed values are
-- the complete set, so it filters using those exact literals instead of
-- guessing at capitalisation or wording. This is the single cheapest
-- improvement to text-to-SQL reliability on a categorical column.
--
-- The AI_VERIFIED_QUERIES clause goes after COMMENT. The SQL inside it is
-- written against the semantic view's logical names -- borrowers.borrower_name,
-- borrowers.monthly_saving -- not against physical column names.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW REFI_INTELLIGENCE
  TABLES (
    borrowers AS CORTEX_REFI_DEMO.MORTGAGE.BORROWER_SCORED
      PRIMARY KEY (HOMEOWNER_ID)
      WITH SYNONYMS ('homeowners', 'customers', 'borrowers', 'loan book', 'accounts')
      COMMENT = 'One row per homeowner: loan terms, property valuation, credit profile, refinance economics, modelled refinance propensity, and the signals extracted from their most recent inbound call.',
    calls AS CORTEX_REFI_DEMO.MORTGAGE.CALL_SIGNALS
      PRIMARY KEY (CALL_ID)
      WITH SYNONYMS ('phone calls', 'inbound calls', 'transcripts', 'contacts')
      COMMENT = 'One row per inbound call, with fields extracted from the transcript by Cortex AI functions.'
  )
  RELATIONSHIPS (
    calls_to_borrower AS calls (HOMEOWNER_ID) REFERENCES borrowers
  )
  FACTS (
    borrowers.current_balance AS CURRENT_BALANCE COMMENT = 'Outstanding principal on the existing mortgage in dollars.',
    borrowers.estimated_value AS ESTIMATED_VALUE COMMENT = 'Current estimated market value of the property in dollars.',
    borrowers.interest_rate AS INTEREST_RATE_PCT COMMENT = 'Interest rate on the existing mortgage, as a percentage.',
    borrowers.rate_delta AS RATE_DELTA_PCT COMMENT = 'Percentage points by which the borrower rate exceeds the prevailing market rate. Positive means the borrower is paying above market.',
    borrowers.ltv AS LTV_PCT COMMENT = 'Loan to value ratio as a percentage of current property value.',
    borrowers.fico AS FICO_SCORE COMMENT = 'Credit score.',
    borrowers.monthly_saving AS EST_MONTHLY_SAVING COMMENT = 'Estimated reduction in monthly payment if refinanced at the market rate over the same remaining term.',
    borrowers.lifetime_saving AS EST_LIFETIME_SAVING COMMENT = 'Estimated total interest saving over the remaining term if refinanced at the market rate.',
    borrowers.current_payment AS CURRENT_MONTHLY_PAYMENT COMMENT = 'Monthly principal and interest payment on the existing loan.',
    borrowers.tenure_months AS CUSTOMER_TENURE_MONTHS COMMENT = 'Months the borrower has been a customer.',
    borrowers.recent_calls AS CALLS_LAST_7D COMMENT = 'Number of inbound calls from this borrower in the last 7 days.',
    borrowers.propensity AS PROPENSITY_PCT COMMENT = 'Modelled probability that this borrower refinances, as a percentage from 0 to 100. Produced by a Snowpark logistic regression scored per borrower.',
    calls.duration_seconds AS DURATION_SECONDS COMMENT = 'Length of the call in seconds.'
  )
  DIMENSIONS (
    borrowers.homeowner_id AS HOMEOWNER_ID WITH SYNONYMS ('borrower id', 'customer id') COMMENT = 'Unique homeowner identifier.',
    borrowers.borrower_name AS FULL_NAME WITH SYNONYMS ('name', 'homeowner name', 'customer name', 'borrower') COMMENT = 'Full name of the homeowner.',
    borrowers.city AS CITY COMMENT = 'City where the property is located.',
    borrowers.state AS STATE COMMENT = 'Two letter state code for the property.',
    borrowers.credit_band AS CREDIT_BAND WITH SYNONYMS ('credit tier', 'credit quality') COMMENT = 'Credit quality band.' SAMPLE_VALUES ('EXCELLENT','GOOD','FAIR','POOR') IS_ENUM,
    borrowers.income_band AS INCOME_BAND COMMENT = 'Annual household income band.',
    borrowers.property_type AS PROPERTY_TYPE COMMENT = 'Property type.' SAMPLE_VALUES ('SINGLE_FAMILY','CONDO','TOWNHOUSE','MULTI_FAMILY') IS_ENUM,
    borrowers.loan_term_months AS TERM_MONTHS COMMENT = 'Original loan term in months. 360 is a 30 year loan, 180 is a 15 year loan.',
    borrowers.origination_date AS ORIGINATION_DATE COMMENT = 'Date the existing mortgage was originated.',
    borrowers.refi_segment AS CASE WHEN IS_TOP_REFI_SEGMENT THEN 'TOP_REFI_SEGMENT' ELSE 'NOT_IN_SEGMENT' END
      WITH SYNONYMS ('top refinance segment', 'refinance segment', 'priority segment', 'target segment', 'best refi candidates')
      COMMENT = 'Top refinance segment. A borrower is TOP_REFI_SEGMENT when they are paying at least 1.0 percentage point above market rate, have loan to value at or below 80 percent, sit in the GOOD or EXCELLENT credit band, have no late payment in 24 months, and carry a balance of at least 150000 dollars. Everyone else is NOT_IN_SEGMENT. Use this dimension whenever asked about the top refinance segment rather than reconstructing the criteria.'
      SAMPLE_VALUES ('TOP_REFI_SEGMENT','NOT_IN_SEGMENT') IS_ENUM,
    borrowers.recent_contact AS CASE WHEN CALLS_LAST_7D > 0 THEN 'CALLED_LAST_7D' ELSE 'NO_RECENT_CALL' END
      WITH SYNONYMS ('called recently', 'recent caller', 'contacted us', 'called last week')
      COMMENT = 'Whether the borrower called in during the last 7 days.'
      SAMPLE_VALUES ('CALLED_LAST_7D','NO_RECENT_CALL') IS_ENUM,
    borrowers.latest_call_intent AS LATEST_CALL_INTENT WITH SYNONYMS ('call reason', 'why they called', 'intent')
      COMMENT = 'Intent of the most recent call, classified by Cortex from the transcript.'
      SAMPLE_VALUES ('RATE_REFI','CASH_OUT','TERM_SHORTEN','PAYMENT_RELIEF','SERVICING_ONLY','RELOCATION') IS_ENUM,
    borrowers.latest_call_urgency AS LATEST_CALL_URGENCY WITH SYNONYMS ('urgency', 'how urgent')
      COMMENT = 'How urgently the borrower wanted to act on their most recent call. Null when the borrower gave no urgency signal.'
      SAMPLE_VALUES ('HIGH','MEDIUM','LOW') IS_ENUM,
    borrowers.latest_call_summary AS LATEST_CALL_SUMMARY COMMENT = 'One sentence summary of the most recent call, generated by Cortex from the transcript.',
    borrowers.life_event AS LIFE_EVENT COMMENT = 'Major life event the borrower mentioned on their most recent call, if any. Null when none was raised.',
    borrowers.mentioned_competitor AS CASE WHEN COMPETITOR_MENTIONED THEN 'MENTIONED_COMPETITOR' ELSE 'NO_COMPETITOR' END
      WITH SYNONYMS ('competitor', 'shopping around', 'retention risk')
      COMMENT = 'Whether the borrower referenced a competing lender offer on their most recent call.'
      SAMPLE_VALUES ('MENTIONED_COMPETITOR','NO_COMPETITOR') IS_ENUM,
    borrowers.requested_callback AS CASE WHEN REQUESTED_CALLBACK THEN 'REQUESTED_CALLBACK' ELSE 'NO_CALLBACK_REQUESTED' END
      COMMENT = 'Whether the borrower asked to be contacted back.'
      SAMPLE_VALUES ('REQUESTED_CALLBACK','NO_CALLBACK_REQUESTED') IS_ENUM,
    borrowers.has_late_payment AS CASE WHEN HAS_LATE_PAYMENT_24M THEN 'LATE_PAYMENT_24M' ELSE 'CLEAN_24M' END
      COMMENT = 'Whether the borrower has had a late payment in the last 24 months.'
      SAMPLE_VALUES ('LATE_PAYMENT_24M','CLEAN_24M') IS_ENUM,
    calls.call_id AS CALL_ID COMMENT = 'Unique call identifier.',
    calls.agent_id AS AGENT_ID WITH SYNONYMS ('rep', 'loan officer', 'agent') COMMENT = 'Identifier of the agent who handled the call.',
    calls.call_timestamp AS CALL_TIMESTAMP WITH SYNONYMS ('call date', 'call time', 'when they called') COMMENT = 'When the call took place.',
    calls.call_intent AS CALL_INTENT COMMENT = 'Classified intent of this specific call.',
    calls.call_urgency AS URGENCY COMMENT = 'Urgency expressed on this specific call.',
    calls.call_summary AS CALL_SUMMARY COMMENT = 'One sentence Cortex generated summary of this specific call.'
  )
  METRICS (
    borrowers.borrower_count AS COUNT(borrowers.HOMEOWNER_ID) WITH SYNONYMS ('number of borrowers', 'how many homeowners', 'headcount') COMMENT = 'Number of distinct homeowners.',
    borrowers.total_balance AS SUM(borrowers.current_balance) COMMENT = 'Total outstanding principal in dollars.',
    borrowers.avg_rate AS AVG(borrowers.interest_rate) COMMENT = 'Average interest rate on existing loans, as a percentage.',
    borrowers.avg_rate_delta AS AVG(borrowers.rate_delta) COMMENT = 'Average percentage points above market rate.',
    borrowers.avg_ltv AS AVG(borrowers.ltv) COMMENT = 'Average loan to value ratio as a percentage.',
    borrowers.avg_fico AS AVG(borrowers.fico) COMMENT = 'Average credit score.',
    borrowers.total_monthly_saving AS SUM(borrowers.monthly_saving) WITH SYNONYMS ('total monthly savings opportunity', 'aggregate monthly saving') COMMENT = 'Sum of estimated monthly payment reductions available across the selected borrowers, in dollars.',
    borrowers.avg_monthly_saving AS AVG(borrowers.monthly_saving) COMMENT = 'Average estimated monthly payment reduction per borrower, in dollars.',
    borrowers.total_lifetime_saving AS SUM(borrowers.lifetime_saving) COMMENT = 'Sum of estimated lifetime interest savings across the selected borrowers, in dollars.',
    borrowers.avg_tenure AS AVG(borrowers.tenure_months) COMMENT = 'Average customer tenure in months.',
    borrowers.avg_propensity AS AVG(borrowers.propensity) WITH SYNONYMS ('average propensity', 'average likelihood to refinance') COMMENT = 'Average modelled refinance propensity across the selected borrowers, as a percentage.',
    borrowers.max_propensity AS MAX(borrowers.propensity) COMMENT = 'Highest modelled refinance propensity in the selection, as a percentage.',
    calls.call_count AS COUNT(calls.CALL_ID) WITH SYNONYMS ('number of calls', 'call volume', 'how many calls') COMMENT = 'Number of inbound calls.',
    calls.avg_call_duration AS AVG(calls.duration_seconds) COMMENT = 'Average call length in seconds.'
  )
  COMMENT = 'Refinance lead intelligence. Joins the mortgage loan book and property valuations to signals extracted from inbound call transcripts by Cortex AI functions, and to the modelled refinance propensity for each borrower. The top refinance segment is defined on the refi_segment dimension.'
  AI_VERIFIED_QUERIES (
    top_segment_recent_callers AS (
      QUESTION 'Which homeowners from last week''s calls match our top refinance segment?'
      VERIFIED_AT 1789000000
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = mortgage_analytics)'
      SQL 'SELECT
               b.borrower_name,
               b.city,
               b.state,
               b.latest_call_intent,
               b.latest_call_urgency,
               AVG(b.rate_delta) AS rate_delta_pct,
               SUM(b.monthly_saving) AS est_monthly_saving
             FROM borrowers AS b
             WHERE b.refi_segment = ''TOP_REFI_SEGMENT''
               AND b.recent_contact = ''CALLED_LAST_7D''
             GROUP BY b.borrower_name, b.city, b.state, b.latest_call_intent, b.latest_call_urgency
             ORDER BY est_monthly_saving DESC NULLS LAST'
    ),
    highest_propensity_in_segment AS (
      QUESTION 'Which borrowers in the top refinance segment have the highest propensity to refinance?'
      VERIFIED_AT 1789000000
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = mortgage_analytics)'
      SQL 'SELECT
               b.borrower_name,
               b.city,
               b.state,
               b.latest_call_intent,
               MAX(b.propensity) AS propensity_pct,
               SUM(b.monthly_saving) AS est_monthly_saving
             FROM borrowers AS b
             WHERE b.refi_segment = ''TOP_REFI_SEGMENT''
             GROUP BY b.borrower_name, b.city, b.state, b.latest_call_intent
             ORDER BY propensity_pct DESC NULLS LAST'
    ),
    segment_size_and_opportunity AS (
      QUESTION 'How many borrowers are in the top refinance segment and what is the total monthly saving available?'
      VERIFIED_AT 1789000000
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = mortgage_analytics)'
      SQL 'SELECT
               b.refi_segment,
               COUNT(b.homeowner_id) AS borrower_count,
               SUM(b.monthly_saving) AS total_monthly_saving,
               AVG(b.propensity) AS avg_propensity_pct
             FROM borrowers AS b
             GROUP BY b.refi_segment
             ORDER BY total_monthly_saving DESC NULLS LAST'
    )
  );


-- ---------------------------------------------------------------------------
-- 3. Confirm the verified queries are attached
--
-- GET_DDL returns the full definition including AI_VERIFIED_QUERIES.
-- ---------------------------------------------------------------------------
SELECT GET_DDL('SEMANTIC_VIEW', 'REFI_INTELLIGENCE', TRUE) AS ddl;


-- ---------------------------------------------------------------------------
-- 4. The score is now available as a governed metric
--
-- Average and maximum propensity by segment. The gap between the two segments
-- is the check that the segment definition and the model agree with each other:
-- if the segment were arbitrary, propensity inside it would look like
-- propensity outside it.
-- ---------------------------------------------------------------------------
SELECT * FROM SEMANTIC_VIEW(
    REFI_INTELLIGENCE
    DIMENSIONS borrowers.refi_segment
    METRICS    borrowers.borrower_count,
               borrowers.avg_propensity,
               borrowers.max_propensity,
               borrowers.total_monthly_saving
) ORDER BY 1;


-- ---------------------------------------------------------------------------
-- 5. Ask the agent the verified question
--
-- The answer now comes from reviewed SQL. Ask it repeatedly and the ordering
-- and the numbers do not move.
-- ---------------------------------------------------------------------------
WITH r AS (
  SELECT PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'SNOWFLAKE_INTELLIGENCE.AGENTS.REFI_INTELLIGENCE_AGENT',
    '{"messages":[{"role":"user","content":[{"type":"text","text":"Which borrowers in the top refinance segment have the highest propensity to refinance?"}]}]}'
  )) AS j
)
SELECT f.value:type::STRING                                        AS content_type,
       COALESCE(f.value:text::STRING, f.value:tool_use:name::STRING) AS detail
FROM r, LATERAL FLATTEN(input => j:content) f;


-- The equivalent question about one borrower still routes to the procedure,
-- and returns the same number with an explanation attached.
CALL GET_REFI_PROPENSITY('Elena Whitfield');
