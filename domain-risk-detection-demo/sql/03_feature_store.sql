-- =============================================================================
-- Domain Abuse Detection Demo - Step 3: Feature Store
-- NOTE: The Feature Store entity and FeatureView are created via the Python API
-- (python/setup_feature_store.py) because the Snowpark Python client handles
-- the metadata registration and Dynamic Table creation.
--
-- This script shows what the Feature Store creates under the hood, and how
-- to query the resulting objects.
-- =============================================================================

USE DATABASE DOMAIN_RISK_DEMO;
USE SCHEMA BAD_DOMAIN_ML;

-- After running python/setup_feature_store.py, verify the Feature Store objects:

-- The Feature Store registers metadata tags on the Dynamic Table
SHOW DYNAMIC TABLES LIKE 'DOMAIN_RISK_FEATURES%' IN SCHEMA DOMAIN_RISK_DEMO.BAD_DOMAIN_ML;

-- Query the Feature View (backed by a managed Dynamic Table)
SELECT * FROM "DOMAIN_RISK_FEATURES$V1" LIMIT 10;

-- Check Dynamic Table refresh status
SELECT
    name,
    scheduling_state,
    target_lag,
    rows,
    data_timestamp
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES())
WHERE schema_name = 'BAD_DOMAIN_ML';

-- Create training dataset by joining features with labels
CREATE OR REPLACE TABLE TRAINING_FEATURES AS
SELECT
    f.NAME_LENGTH,
    f.DIGIT_COUNT,
    f.HYPHEN_COUNT,
    f.WORD_COUNT,
    f.BRAND_KEYWORD_PRESENT,
    f.LEETSPEAK_SUBSTITUTION,
    f.PHISHING_KEYWORD_PRESENT,
    f.SCAM_KEYWORD_PRESENT,
    f.DIGIT_RATIO,
    f.DOMAINS_BY_REGISTRANT,
    f.BULK_REGISTRANT_FLAG,
    f.MASS_REGISTRANT_FLAG,
    f.WHOIS_PRIVACY_FLAG,
    f.NO_CONTENT_FLAG,
    f.PRIVACY_NO_CONTENT_COMBO,
    f.HIGH_RISK_COUNTRY,
    f.ANONYMOUS_EMAIL_FLAG,
    f.SUSPICIOUS_NAMESERVER_FLAG,
    f.WEBSITE_RISK_SCORE,
    r.IS_SUSPICIOUS
FROM "DOMAIN_RISK_FEATURES$V1" f
JOIN RAW_REGISTRATIONS r ON f.DOMAIN_ID = r.DOMAIN_ID;
