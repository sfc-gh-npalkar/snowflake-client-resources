-- =============================================================================
-- Domain Abuse Detection Demo - Step 2: Feature Engineering
-- Creates a view with 19 computed features from raw registrations.
-- This view is used by the Feature Store (Step 3) as its data source.
-- =============================================================================

USE DATABASE DOMAIN_RISK_DEMO;
USE SCHEMA BAD_DOMAIN_ML;

CREATE OR REPLACE VIEW DOMAIN_FEATURES_V AS
SELECT
    domain_id,
    registration_date,

    -- Domain name text features
    LENGTH(domain_name)                                AS name_length,
    REGEXP_COUNT(domain_name, '[0-9]')                 AS digit_count,
    REGEXP_COUNT(domain_name, '-')                     AS hyphen_count,
    LENGTH(domain_name) - LENGTH(REPLACE(domain_name, '-', '')) - 1 AS word_count,

    -- Brand impersonation signals
    CASE WHEN domain_name RLIKE '.*(paypal|amazon|microsoft|apple|google|netflix|facebook|chase|wellsfargo|citibank|usps|fedex|bank).*'
         THEN 1 ELSE 0 END                             AS brand_keyword_present,
    CASE WHEN domain_name RLIKE '.*(0|1|l).*'
         AND domain_name RLIKE '.*(paypa|amaz|googl|micros|app1|netf1|faceb|chasse).*'
         THEN 1 ELSE 0 END                             AS leetspeak_substitution,

    -- Suspicious keyword signals
    CASE WHEN domain_name RLIKE '.*(secure|login|verify|account|update|official|alert|confirm).*'
         THEN 1 ELSE 0 END                             AS phishing_keyword_present,
    CASE WHEN domain_name RLIKE '.*(free|prize|reward|gift|money|crypto|bitcoin|loan|cash).*'
         THEN 1 ELSE 0 END                             AS scam_keyword_present,

    -- Domain randomness (high digit ratio = more random/generated)
    ROUND(REGEXP_COUNT(domain_name, '[0-9]')::FLOAT / NULLIF(LENGTH(domain_name), 0), 3) AS digit_ratio,

    -- Registration behavior
    domains_by_registrant,
    CASE WHEN domains_by_registrant >= 10  THEN 1 ELSE 0 END AS bulk_registrant_flag,
    CASE WHEN domains_by_registrant >= 50  THEN 1 ELSE 0 END AS mass_registrant_flag,

    -- WHOIS and content signals
    CASE WHEN whois_privacy           THEN 1 ELSE 0 END AS whois_privacy_flag,
    CASE WHEN has_website_content     THEN 0 ELSE 1 END AS no_content_flag,
    CASE WHEN whois_privacy AND NOT has_website_content
         THEN 1 ELSE 0 END                             AS privacy_no_content_combo,

    -- Geographic risk
    CASE WHEN registrant_country IN ('RU','CN','NG','UA','RO','VN','PH','ID')
         THEN 1 ELSE 0 END                             AS high_risk_country,

    -- Email risk (anonymous/disposable providers)
    CASE WHEN registrant_email_domain IN
         ('protonmail.com','tutanota.com','mail.ru','yandex.com','tempmail.org','guerrillamail.com','sharklasers.com')
         THEN 1 ELSE 0 END                             AS anonymous_email_flag,

    -- Nameserver risk (bulletproof / offshore hosting)
    CASE WHEN nameserver_provider RLIKE '.*(bulletproof|offshore|anon|fastflux|shadow|dark|hidden|proxy|stealth).*'
         THEN 1 ELSE 0 END                             AS suspicious_nameserver_flag,

    -- Website category risk score (0=nonprofit, 2=parked, 3=phishing/malware)
    CASE WHEN website_category IN ('phishing','malware','scam','suspicious') THEN 3
         WHEN website_category IN ('parked','placeholder','redirect')        THEN 2
         WHEN website_category = 'under-construction'                        THEN 1
         ELSE 0 END                                    AS website_risk_score,

    is_suspicious

FROM RAW_REGISTRATIONS;

-- Preview feature distributions by label
SELECT
    CASE WHEN is_suspicious THEN 'Suspicious' ELSE 'Legitimate' END AS category,
    ROUND(AVG(brand_keyword_present), 3)     AS avg_brand_keyword,
    ROUND(AVG(digit_ratio), 3)               AS avg_digit_ratio,
    ROUND(AVG(bulk_registrant_flag), 3)      AS avg_bulk_registrant,
    ROUND(AVG(privacy_no_content_combo), 3)  AS avg_privacy_no_content,
    ROUND(AVG(high_risk_country), 3)         AS avg_high_risk_country,
    ROUND(AVG(suspicious_nameserver_flag), 3) AS avg_sus_nameserver
FROM DOMAIN_FEATURES_V
GROUP BY 1;
