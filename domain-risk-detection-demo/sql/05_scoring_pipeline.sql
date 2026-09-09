-- =============================================================================
-- Domain Abuse Detection Demo - Step 5: Scoring Pipeline
-- Creates a Dynamic Table that automatically scores all domain registrations.
-- Refreshes every hour — new registrations are flagged within 60 minutes.
-- =============================================================================

USE DATABASE DOMAIN_RISK_DEMO;
USE SCHEMA BAD_DOMAIN_ML;

CREATE OR REPLACE DYNAMIC TABLE DOMAIN_RISK_SCORES
    TARGET_LAG = '1 hour'
    WAREHOUSE = COMPUTE_WH
AS
WITH ml_scored AS (
    SELECT
        r.DOMAIN_ID,
        r.DOMAIN_NAME,
        r.REGISTRANT_ORG,
        r.REGISTRANT_COUNTRY,
        r.REGISTRATION_DATE,
        r.WHOIS_PRIVACY,
        r.DOMAINS_BY_REGISTRANT,
        r.HAS_WEBSITE_CONTENT,
        r.WEBSITE_CATEGORY,
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
        ):class::VARCHAR                                        AS ml_prediction,
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
        ):probability:"True"::FLOAT                            AS ml_confidence
    FROM RAW_REGISTRATIONS r
    JOIN "DOMAIN_RISK_FEATURES$V1" f ON r.DOMAIN_ID = f.DOMAIN_ID
)
SELECT
    *,
    CASE
        WHEN ml_confidence >= 0.85 THEN 'HIGH'
        WHEN ml_confidence >= 0.50 THEN 'MEDIUM'
        ELSE                             'LOW'
    END AS risk_tier,
    CASE
        WHEN ml_confidence >= 0.85 THEN 'BLOCK'
        WHEN ml_confidence >= 0.50 THEN 'REVIEW'
        ELSE                             'ALLOW'
    END AS recommended_action
FROM ml_scored;

-- Verify output
SELECT risk_tier, recommended_action, COUNT(*) AS cnt
FROM DOMAIN_RISK_SCORES
GROUP BY 1, 2
ORDER BY cnt DESC;

-- Top flagged domains
SELECT
    domain_name || '.org'              AS domain,
    registrant_org,
    registrant_country,
    ROUND(ml_confidence * 100, 1)      AS confidence_pct,
    risk_tier,
    recommended_action
FROM DOMAIN_RISK_SCORES
WHERE risk_tier = 'HIGH'
ORDER BY ml_confidence DESC
LIMIT 20;

-- =============================================================================
-- Cortex AI Enrichment (optional — uses LLM credits)
-- Run on a subset of high-risk domains for semantic risk assessment.
-- =============================================================================
SELECT
    domain_name || '.org'   AS domain,
    registrant_org,
    SNOWFLAKE.CORTEX.COMPLETE('mistral-large2',
        'You are a domain abuse analyst for a domain registry. '
        || 'Assess this domain registration for potential abuse. '
        || 'Domain: '      || domain_name || '.org, '
        || 'Registrant: '  || registrant_org || ', '
        || 'Country: '     || registrant_country || '. '
        || 'Respond in JSON: {"risk_level": "high/medium/low", "abuse_type": "brand_impersonation/phishing/scam/squatting/legitimate", "reason": "one sentence"}'
    ) AS ai_assessment
FROM RAW_REGISTRATIONS
WHERE is_suspicious = TRUE
ORDER BY RANDOM()
LIMIT 5;

-- =============================================================================
-- Live demo: score a new suspicious registration on the spot
-- =============================================================================
SELECT
    'paypal-verify-now.org'    AS domain,
    BAD_DOMAIN_CLASSIFIER!PREDICT(INPUT_DATA => OBJECT_CONSTRUCT(
        'NAME_LENGTH', 18, 'DIGIT_COUNT', 0, 'HYPHEN_COUNT', 2, 'WORD_COUNT', 2,
        'BRAND_KEYWORD_PRESENT', 1, 'LEETSPEAK_SUBSTITUTION', 0,
        'PHISHING_KEYWORD_PRESENT', 1, 'SCAM_KEYWORD_PRESENT', 0,
        'DIGIT_RATIO', 0.0, 'DOMAINS_BY_REGISTRANT', 87,
        'BULK_REGISTRANT_FLAG', 1, 'MASS_REGISTRANT_FLAG', 1,
        'WHOIS_PRIVACY_FLAG', 1, 'NO_CONTENT_FLAG', 1,
        'PRIVACY_NO_CONTENT_COMBO', 1, 'HIGH_RISK_COUNTRY', 1,
        'ANONYMOUS_EMAIL_FLAG', 1, 'SUSPICIOUS_NAMESERVER_FLAG', 1,
        'WEBSITE_RISK_SCORE', 2
    )):class::VARCHAR          AS predicted_class,
    ROUND(
        BAD_DOMAIN_CLASSIFIER!PREDICT(INPUT_DATA => OBJECT_CONSTRUCT(
            'NAME_LENGTH', 18, 'DIGIT_COUNT', 0, 'HYPHEN_COUNT', 2, 'WORD_COUNT', 2,
            'BRAND_KEYWORD_PRESENT', 1, 'LEETSPEAK_SUBSTITUTION', 0,
            'PHISHING_KEYWORD_PRESENT', 1, 'SCAM_KEYWORD_PRESENT', 0,
            'DIGIT_RATIO', 0.0, 'DOMAINS_BY_REGISTRANT', 87,
            'BULK_REGISTRANT_FLAG', 1, 'MASS_REGISTRANT_FLAG', 1,
            'WHOIS_PRIVACY_FLAG', 1, 'NO_CONTENT_FLAG', 1,
            'PRIVACY_NO_CONTENT_COMBO', 1, 'HIGH_RISK_COUNTRY', 1,
            'ANONYMOUS_EMAIL_FLAG', 1, 'SUSPICIOUS_NAMESERVER_FLAG', 1,
            'WEBSITE_RISK_SCORE', 2
        )):probability:"True"::FLOAT * 100, 1
    )                          AS confidence_pct,
    'BLOCK'                    AS recommended_action;
