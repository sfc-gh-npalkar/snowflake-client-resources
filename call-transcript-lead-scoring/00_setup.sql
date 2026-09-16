/* ============================================================================
   Snowflake Cortex Workshop
   00_setup.sql -- Environment setup and prerequisite check

   Run this file first. It creates the database, schema, and warehouse used
   throughout the workshop, then verifies that your account can call Cortex
   AI functions.

   All statements are idempotent and safe to re-run.
   ========================================================================== */

-- ---------------------------------------------------------------------------
-- 1. Enable Cortex AI functions
--
-- Cortex AI functions (AI_EXTRACT, AI_CLASSIFY, AI_COMPLETE, and others) are
-- controlled by an account-level grant. Without it, calling one returns
-- "Unknown function AI_EXTRACT" -- the function exists, but the active role is
-- not entitled to use it.
--
-- Must be run by ACCOUNTADMIN. Grant to any additional roles that will run
-- the workshop.
-- ---------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE ACCOUNTADMIN;

-- GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE <additional_role>;


-- ---------------------------------------------------------------------------
-- 2. Create the workshop environment
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS CORTEX_REFI_DEMO
  COMMENT = 'Cortex workshop. Synthetic data only.';

CREATE SCHEMA IF NOT EXISTS CORTEX_REFI_DEMO.MORTGAGE
  COMMENT = 'Refinance lead intelligence: call transcripts, loan book, scoring.';

CREATE WAREHOUSE IF NOT EXISTS CORTEX_DEMO_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Compute for the Cortex workshop.';

USE WAREHOUSE CORTEX_DEMO_WH;
USE DATABASE CORTEX_REFI_DEMO;
USE SCHEMA MORTGAGE;


-- ---------------------------------------------------------------------------
-- 3. Verify AI_EXTRACT
--
-- AI_EXTRACT pulls structured fields out of unstructured text. You define the
-- fields you want in responseFormat, using plain-language descriptions rather
-- than a rigid schema.
--
-- The function returns an OBJECT shaped { error, response }, so the requested
-- fields are addressed under :response.
--
-- Expected: borrower_name = Dana Whitfield, current_rate_pct = 7.125
-- ---------------------------------------------------------------------------
SELECT
    TO_VARCHAR(r:response:borrower_name)    AS borrower_name,
    TO_VARCHAR(r:response:property_city)    AS property_city,
    TO_VARCHAR(r:response:current_rate_pct) AS current_rate_pct,
    TO_VARCHAR(r:response:urgency)          AS urgency
FROM (
    SELECT AI_EXTRACT(
        text => 'Caller: Hi, I am Dana Whitfield, I own a home in Aurora CO. '
             || 'My current mortgage rate is 7.125% and I have about 18 years '
             || 'left. I want to know if refinancing makes sense.',
        responseFormat => {
            'borrower_name'    : 'full name of the caller',
            'property_city'    : 'city where the property is located',
            'current_rate_pct' : 'current mortgage interest rate as a number',
            'urgency'          : 'one of: HIGH, MEDIUM, LOW'
        }
    ) AS r
);


-- ---------------------------------------------------------------------------
-- 4. Verify AI_COMPLETE
--
-- AI_COMPLETE runs a prompt against a hosted model. Used later to summarise
-- long transcripts.
--
-- Model aliases are versioned and older ones are retired over time. If this
-- call returns a "legacy state" error, substitute the current model alias
-- from the AI_COMPLETE documentation.
--
-- If it instead reports the model is unavailable in your region, enable
-- cross-region inference (ACCOUNTADMIN, account level only):
--
--   ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';
-- ---------------------------------------------------------------------------
SELECT AI_COMPLETE(
    'claude-sonnet-4-5',
    'Reply with exactly the word READY and nothing else.'
) AS model_check;


-- ---------------------------------------------------------------------------
-- 5. Verify the Python packages the scoring model needs
--
-- 04_scoring.sql trains a scikit-learn model inside a Python stored procedure.
-- Those packages come from the Snowflake Anaconda channel, which an ORGADMIN
-- must enable once per account by accepting the third-party terms:
--
--   Snowsight » Admin » Billing & Terms » Anaconda » Enable
--
-- Until that is done, creating the procedure fails with an error about the
-- packages not being available. This query should return six rows. If it
-- returns none, the channel is not enabled yet.
-- ---------------------------------------------------------------------------
SELECT PACKAGE_NAME, MAX(VERSION) AS latest_version
FROM INFORMATION_SCHEMA.PACKAGES
WHERE LANGUAGE = 'python'
  AND PACKAGE_NAME IN (
      'snowflake-snowpark-python', 'scikit-learn', 'pandas',
      'numpy', 'joblib', 'cachetools'
  )
GROUP BY PACKAGE_NAME
ORDER BY PACKAGE_NAME;


-- ---------------------------------------------------------------------------
-- 6. Ensure the agent location exists
--
-- 05_agent.sql creates the agent in SNOWFLAKE_INTELLIGENCE.AGENTS, which is
-- where Snowflake CoWork looks for agents to show in its picker. On some
-- accounts this database does not exist until something creates it, so create
-- it here rather than letting 05 fail.
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE
  COMMENT = 'Home for Cortex Agents surfaced in Snowflake CoWork.';

CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_INTELLIGENCE.AGENTS
  COMMENT = 'Cortex Agent objects.';


-- ---------------------------------------------------------------------------
-- Preflight summary
--
-- You are ready to continue when:
--   step 3 returned Dana Whitfield and 7.125
--   step 4 returned READY
--   step 5 returned six package rows
--   step 6 completed without error
--
-- Continue to 01_data.sql.
-- ---------------------------------------------------------------------------
