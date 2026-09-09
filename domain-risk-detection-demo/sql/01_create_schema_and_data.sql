-- =============================================================================
-- Domain Abuse Detection Demo - Step 1: Create Schema
-- Creates DOMAIN_RISK_DEMO database and BAD_DOMAIN_ML schema, then generates
-- ~10,000 synthetic .org domain registrations with realistic patterns.
-- =============================================================================

CREATE DATABASE IF NOT EXISTS DOMAIN_RISK_DEMO;
CREATE SCHEMA IF NOT EXISTS DOMAIN_RISK_DEMO.BAD_DOMAIN_ML;

USE DATABASE DOMAIN_RISK_DEMO;
USE SCHEMA BAD_DOMAIN_ML;

-- Generate synthetic domain registration data
-- Distribution: ~70% legitimate, ~20% suspicious, ~10% edge cases
CREATE OR REPLACE TABLE RAW_REGISTRATIONS AS
WITH row_gen AS (
    SELECT
        SEQ4() + 1 AS row_num,
        UNIFORM(1, 100, RANDOM()) AS rand_pct,
        ABS(HASH(RANDOM())) AS h1,
        ABS(HASH(RANDOM())) AS h2,
        ABS(HASH(RANDOM())) AS h3,
        ABS(HASH(RANDOM())) AS h4,
        ABS(HASH(RANDOM())) AS h5,
        ABS(HASH(RANDOM())) AS h6,
        UNIFORM(1,100,RANDOM()) AS u1,
        UNIFORM(1,100,RANDOM()) AS u2,
        UNIFORM(1,100,RANDOM()) AS u3
    FROM TABLE(GENERATOR(ROWCOUNT => 10000))
),
categorized AS (
    SELECT *,
        CASE
            WHEN rand_pct <= 22 THEN 'suspicious'
            WHEN rand_pct <= 30 THEN 'edge_case'
            ELSE 'legitimate'
        END AS category
    FROM row_gen
)
SELECT
    'DOM-' || LPAD(row_num::VARCHAR, 6, '0') AS domain_id,

    -- Domain name
    CASE
        WHEN category = 'suspicious' THEN
            CASE h1 % 5
                WHEN 0 THEN
                    ARRAY_CONSTRUCT('paypal','amazon','microsoft','apple','google','netflix','facebook','chase','wellsfargo','citibank')[h2 % 10]::VARCHAR
                    || ARRAY_CONSTRUCT('-secure','-login','-verify','-account','-update','-support','-help','-service','-official','-alert')[h3 % 10]::VARCHAR
                    || CASE WHEN u1 <= 40 THEN (h4 % 99 + 1)::VARCHAR ELSE '' END
                WHEN 1 THEN SUBSTR(MD5(row_num::VARCHAR || 'a'), 1, (h2 % 9) + 8)
                WHEN 2 THEN
                    ARRAY_CONSTRUCT('free-','get-','my-','your-','the-')[h2 % 5]::VARCHAR
                    || ARRAY_CONSTRUCT('money','crypto','gift-card','prize','reward','bitcoin','cashapp','venmo','zelle','loan')[h3 % 10]::VARCHAR
                    || ARRAY_CONSTRUCT('-now','-today','-fast','-easy','-online')[h4 % 5]::VARCHAR
                WHEN 3 THEN
                    ARRAY_CONSTRUCT('secure','official','real','legit','trusted')[h2 % 5]::VARCHAR || '-'
                    || ARRAY_CONSTRUCT('paypal','amazon','microsoft','apple','google','netflix','bank','chase','usps','fedex')[h3 % 10]::VARCHAR
                    || ARRAY_CONSTRUCT('-org','-help','-center','','-portal')[h4 % 5]::VARCHAR
                ELSE
                    ARRAY_CONSTRUCT('amaz0n','g00gle','micros0ft','app1e','netf1ix','paypa1','faceb00k','1inkedin','tw1tter','chasse')[h2 % 10]::VARCHAR
                    || ARRAY_CONSTRUCT('-support','-verify','-secure','-login','-update')[h3 % 5]::VARCHAR
            END
        WHEN category = 'edge_case' THEN
            CASE h1 % 3
                WHEN 0 THEN
                    ARRAY_CONSTRUCT('help','support','global','united','community','future','alliance','action','project','initiative')[h2 % 10]::VARCHAR
                    || '-' || (h3 % 999 + 1)::VARCHAR
                WHEN 1 THEN
                    SUBSTR(MD5(row_num::VARCHAR || 'b'), 1, 6) || '-'
                    || ARRAY_CONSTRUCT('foundation','alliance','project','group','network')[h3 % 5]::VARCHAR
                ELSE
                    ARRAY_CONSTRUCT('new','open','free','smart','next')[h2 % 5]::VARCHAR || '-'
                    || ARRAY_CONSTRUCT('health','education','community','digital','green')[h3 % 5]::VARCHAR || '-'
                    || ARRAY_CONSTRUCT('hub','lab','center','works','connect')[h4 % 5]::VARCHAR
            END
        ELSE -- Legitimate
            ARRAY_CONSTRUCT('save-the','friends-of','help','support','protect','global','community','foundation-for','alliance-for','united')[h1 % 10]::VARCHAR || '-'
            || ARRAY_CONSTRUCT('children','wildlife','ocean','forest','education','health','community','arts','veterans','seniors','hunger','literacy','housing','environment','peace','justice','research','youth','families','animals')[h2 % 20]::VARCHAR
            || CASE WHEN u1 <= 15 THEN '-' || ARRAY_CONSTRUCT('international','america','worldwide','local','national')[h3 % 5]::VARCHAR ELSE '' END
    END AS domain_name,

    -- Registrant org
    CASE
        WHEN category = 'suspicious' THEN
            ARRAY_CONSTRUCT('Digital Services LLC','Web Holdings Corp','Domain Investments Ltd','Internet Marketing Group','Online Solutions Inc','Tech Ventures LLC','Global Digital Corp','Cyber Holdings','Net Services International','Premium Domains Ltd','Quick Register LLC','Auto Domains Inc','Bulk Register Corp','Domain Factory Ltd','WebTech Holdings','DataStream Inc','CloudNet Services','InfoTech Global','ByteForce LLC','NetQuest Holdings')[h3 % 20]::VARCHAR
        WHEN category = 'edge_case' THEN
            CASE WHEN u2 <= 50 THEN
                ARRAY_CONSTRUCT('Wildlife Conservation Society','Habitat for Humanity Local','Community Health Foundation','Education Alliance','Youth Development Inc','Environmental Defense Council','Senior Care Network','Literacy Project','Climate Action Now','Peace Corps Alumni')[h3 % 10]::VARCHAR
            ELSE
                ARRAY_CONSTRUCT('Digital Services LLC','Web Holdings Corp','Online Solutions Inc','Tech Ventures LLC','Global Digital Corp','NetQuest Holdings','DataStream Inc','Quick Register LLC','InfoTech Global','ByteForce LLC')[h3 % 10]::VARCHAR
            END
        ELSE
            ARRAY_CONSTRUCT('Wildlife Conservation Society','Habitat for Humanity','Red Cross Chapter','Community Health Foundation','Education Alliance','Youth Development Inc','Environmental Defense Council','Arts for All Foundation','Senior Care Network','Literacy Project','Food Bank Coalition','Veterans Support Association','Children First Initiative','Ocean Preservation Trust','Climate Action Now','Mental Health Alliance','Refugee Aid Society','Housing Rights Center','Peace Corps Alumni','Scholarship Fund International')[h3 % 20]::VARCHAR
    END AS registrant_org,

    -- Country
    CASE
        WHEN category = 'suspicious' THEN
            CASE WHEN u2 <= 70 THEN ARRAY_CONSTRUCT('RU','CN','NG','UA','RO','IN','BR','PH','VN','ID')[h4 % 10]::VARCHAR
            ELSE ARRAY_CONSTRUCT('US','CA','GB','AU','DE','FR','NL','US','US','US')[h4 % 10]::VARCHAR END
        ELSE ARRAY_CONSTRUCT('US','US','US','US','CA','GB','AU','DE','FR','NL')[h4 % 10]::VARCHAR
    END AS registrant_country,

    DATEADD('day', -UNIFORM(1, 730, RANDOM()), CURRENT_TIMESTAMP()) AS registration_date,

    -- WHOIS privacy (80% suspicious use it, only 15% legit do)
    CASE
        WHEN category = 'suspicious' THEN u3 <= 80
        WHEN category = 'edge_case' THEN u3 <= 40
        ELSE u3 <= 15
    END AS whois_privacy,

    -- Email domain
    CASE
        WHEN category = 'suspicious' THEN ARRAY_CONSTRUCT('protonmail.com','tutanota.com','gmail.com','yahoo.com','mail.ru','yandex.com','outlook.com','tempmail.org','guerrillamail.com','sharklasers.com')[h5 % 10]::VARCHAR
        ELSE ARRAY_CONSTRUCT('orgname.org','orgname.org','orgname.org','gmail.com','outlook.com','orgname.org','yahoo.com','orgname.org','orgname.org','hotmail.com')[h5 % 10]::VARCHAR
    END AS registrant_email_domain,

    -- Nameserver
    CASE
        WHEN category = 'suspicious' AND u1 <= 60 THEN ARRAY_CONSTRUCT('bulletproof-hosting.net','offshore-dns.com','privacy-ns.org','anon-hosting.ru','fastflux-dns.com','shadow-ns.net','dark-dns.org','hidden-host.com','proxy-ns.net','stealth-dns.io')[h6 % 10]::VARCHAR
        ELSE ARRAY_CONSTRUCT('cloudflare.com','godaddy.com','namecheap.com','aws.amazon.com','google.com','digitalocean.com','linode.com','bluehost.com','hostgator.com','siteground.com')[h6 % 10]::VARCHAR
    END AS nameserver_provider,

    -- Domains by registrant (suspicious actors bulk-register)
    CASE
        WHEN category = 'suspicious' THEN UNIFORM(5, 250, RANDOM())
        WHEN category = 'edge_case' THEN UNIFORM(1, 20, RANDOM())
        ELSE UNIFORM(1, 4, RANDOM())
    END AS domains_by_registrant,

    -- Has website content (only 15% of suspicious do, 90% of legit do)
    CASE
        WHEN category = 'suspicious' THEN u2 <= 15
        WHEN category = 'edge_case' THEN u2 <= 55
        ELSE u2 <= 90
    END AS has_website_content,

    -- Website category
    CASE
        WHEN category = 'suspicious' THEN ARRAY_CONSTRUCT('parked','placeholder','suspicious','redirect','phishing','malware','scam','parked','placeholder','redirect')[h6 % 10]::VARCHAR
        WHEN category = 'edge_case' THEN ARRAY_CONSTRUCT('nonprofit','placeholder','parked','nonprofit','under-construction')[h6 % 5]::VARCHAR
        ELSE 'nonprofit'
    END AS website_category,

    -- Ground truth label
    CASE
        WHEN category = 'suspicious' THEN TRUE
        WHEN category = 'edge_case' THEN (u3 <= 30)
        ELSE FALSE
    END AS is_suspicious

FROM categorized;

-- Verify
SELECT
    COUNT(*) as total_rows,
    SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) as suspicious_count,
    ROUND(SUM(CASE WHEN is_suspicious THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 1) as suspicious_pct
FROM RAW_REGISTRATIONS;
