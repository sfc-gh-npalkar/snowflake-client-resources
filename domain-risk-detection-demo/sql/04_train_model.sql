-- =============================================================================
-- Domain Abuse Detection Demo - Step 4: Train ML Classification Model
-- Uses Snowflake's built-in ML Classification — no Python required.
-- =============================================================================

USE DATABASE DOMAIN_RISK_DEMO;
USE SCHEMA BAD_DOMAIN_ML;

-- Train binary classifier (suspicious = TRUE vs FALSE)
-- Snowflake auto-selects the best algorithm and handles cross-validation
CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION DOMAIN_RISK_DEMO.BAD_DOMAIN_ML.BAD_DOMAIN_CLASSIFIER(
    INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'DOMAIN_RISK_DEMO.BAD_DOMAIN_ML.TRAINING_FEATURES'),
    TARGET_COLNAME => 'IS_SUSPICIOUS',
    CONFIG_OBJECT => {'on_error': 'skip'}
);

-- Evaluate model performance
-- Key metric: recall on suspicious=TRUE (don't miss bad actors)
-- Key metric: precision on suspicious=TRUE (don't block real legitimate registrants)
CALL BAD_DOMAIN_CLASSIFIER!SHOW_EVALUATION_METRICS();

-- Feature importance: which signals matter most?
CALL BAD_DOMAIN_CLASSIFIER!SHOW_FEATURE_IMPORTANCE();

-- Sample predictions (spot check)
SELECT
    r.domain_name || '.org' AS domain,
    r.is_suspicious         AS actual,
    BAD_DOMAIN_CLASSIFIER!PREDICT(
        INPUT_DATA => OBJECT_CONSTRUCT(
            'NAME_LENGTH',              f.NAME_LENGTH,
            'DIGIT_COUNT',              f.DIGIT_COUNT,
            'HYPHEN_COUNT',             f.HYPHEN_COUNT,
            'WORD_COUNT',               f.WORD_COUNT,
            'BRAND_KEYWORD_PRESENT',    f.BRAND_KEYWORD_PRESENT,
            'LEETSPEAK_SUBSTITUTION',   f.LEETSPEAK_SUBSTITUTION,
            'PHISHING_KEYWORD_PRESENT', f.PHISHING_KEYWORD_PRESENT,
            'SCAM_KEYWORD_PRESENT',     f.SCAM_KEYWORD_PRESENT,
            'DIGIT_RATIO',              f.DIGIT_RATIO,
            'DOMAINS_BY_REGISTRANT',    f.DOMAINS_BY_REGISTRANT,
            'BULK_REGISTRANT_FLAG',     f.BULK_REGISTRANT_FLAG,
            'MASS_REGISTRANT_FLAG',     f.MASS_REGISTRANT_FLAG,
            'WHOIS_PRIVACY_FLAG',       f.WHOIS_PRIVACY_FLAG,
            'NO_CONTENT_FLAG',          f.NO_CONTENT_FLAG,
            'PRIVACY_NO_CONTENT_COMBO', f.PRIVACY_NO_CONTENT_COMBO,
            'HIGH_RISK_COUNTRY',        f.HIGH_RISK_COUNTRY,
            'ANONYMOUS_EMAIL_FLAG',     f.ANONYMOUS_EMAIL_FLAG,
            'SUSPICIOUS_NAMESERVER_FLAG', f.SUSPICIOUS_NAMESERVER_FLAG,
            'WEBSITE_RISK_SCORE',       f.WEBSITE_RISK_SCORE
        )
    ):class::VARCHAR                                       AS predicted,
    ROUND(
        BAD_DOMAIN_CLASSIFIER!PREDICT(
            INPUT_DATA => OBJECT_CONSTRUCT(
                'NAME_LENGTH',              f.NAME_LENGTH,
                'DIGIT_COUNT',              f.DIGIT_COUNT,
                'HYPHEN_COUNT',             f.HYPHEN_COUNT,
                'WORD_COUNT',               f.WORD_COUNT,
                'BRAND_KEYWORD_PRESENT',    f.BRAND_KEYWORD_PRESENT,
                'LEETSPEAK_SUBSTITUTION',   f.LEETSPEAK_SUBSTITUTION,
                'PHISHING_KEYWORD_PRESENT', f.PHISHING_KEYWORD_PRESENT,
                'SCAM_KEYWORD_PRESENT',     f.SCAM_KEYWORD_PRESENT,
                'DIGIT_RATIO',              f.DIGIT_RATIO,
                'DOMAINS_BY_REGISTRANT',    f.DOMAINS_BY_REGISTRANT,
                'BULK_REGISTRANT_FLAG',     f.BULK_REGISTRANT_FLAG,
                'MASS_REGISTRANT_FLAG',     f.MASS_REGISTRANT_FLAG,
                'WHOIS_PRIVACY_FLAG',       f.WHOIS_PRIVACY_FLAG,
                'NO_CONTENT_FLAG',          f.NO_CONTENT_FLAG,
                'PRIVACY_NO_CONTENT_COMBO', f.PRIVACY_NO_CONTENT_COMBO,
                'HIGH_RISK_COUNTRY',        f.HIGH_RISK_COUNTRY,
                'ANONYMOUS_EMAIL_FLAG',     f.ANONYMOUS_EMAIL_FLAG,
                'SUSPICIOUS_NAMESERVER_FLAG', f.SUSPICIOUS_NAMESERVER_FLAG,
                'WEBSITE_RISK_SCORE',       f.WEBSITE_RISK_SCORE
            )
        ):probability:"True"::FLOAT * 100, 1
    )                                                      AS confidence_pct
FROM RAW_REGISTRATIONS r
JOIN "DOMAIN_RISK_FEATURES$V1" f ON r.DOMAIN_ID = f.DOMAIN_ID
WHERE r.IS_SUSPICIOUS = TRUE
ORDER BY RANDOM()
LIMIT 10;
