/* ============================================================================
   Snowflake Cortex Workshop
   01_data.sql -- Loan book, property data, and inbound call transcripts

   All data in this file is synthetic. No real borrowers, balances, rates,
   or personally identifiable information.

   Values are derived deterministically from ABS(HASH(...)) of each row key
   rather than from RANDOM(), so the dataset is reproducible: the same rows and
   the same figures are generated on every run and in every account.

   All statements are CREATE OR REPLACE and safe to re-run.
   ========================================================================== */

USE WAREHOUSE CORTEX_DEMO_WH;
USE DATABASE CORTEX_REFI_DEMO;
USE SCHEMA MORTGAGE;

-- Prevailing market rate for a 30-year fixed, defined once and referenced
-- everywhere downstream. Refinance opportunity is measured as the gap between
-- this rate and the borrower's current rate.
CREATE OR REPLACE VIEW MARKET_RATE AS SELECT 6.10::FLOAT AS RATE_PCT;


-- ---------------------------------------------------------------------------
-- HOMEOWNERS -- 400 borrowers on the book
--
-- Names are drawn from the full cross product of 40 first and 40 last names,
-- ordered deterministically and then limited to 400, which guarantees every
-- borrower name is unique. Selecting a name per row independently would be
-- simpler but produces collisions -- 400 draws from 1,600 combinations yields
-- around 50 duplicated names -- and a duplicated name breaks any lookup that
-- resolves a borrower by name.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE HOMEOWNERS AS
WITH firsts AS (
    SELECT VALUE::STRING AS fn FROM TABLE(FLATTEN(input => ARRAY_CONSTRUCT(
        'Dana','Marcus','Priya','Elena','Trevor','Nadia','Colin','Rosa',
        'Devon','Imani','Grant','Sofia','Miles','Farrah','Bruno','Alina',
        'Teddy','Camila','Roman','Naomi','Sasha','Otis','Leila','Hugo',
        'Wren','Desmond','Anita','Felix','Joss','Marisol','Kenji','Bianca',
        'Ravi','Tessa','Lorne','Delia','Amos','Yuki','Clement','Sabine')))
),
lasts AS (
    SELECT VALUE::STRING AS ln FROM TABLE(FLATTEN(input => ARRAY_CONSTRUCT(
        'Whitfield','Ortega','Raman','Kowalski','Boone','Haddad','Fletcher',
        'Delgado','Ashby','Okafor','Sandoval','Merritt','Vance','Nakamura',
        'Cardoso','Pruitt','Lindqvist','Barrios','Ferreira','Calloway',
        'Mbeki','Thackeray','Solis','Grimaldi','Nazarian','Ellsworth',
        'Batista','Kirkland','Vasquez','Holloway','Redmond','Achebe',
        'Sterling','Moreau','Panagakos','Whitlock','Ibarra','Draper',
        'Kensington','Alvarado')))
),
combos AS (
    SELECT f.fn, l.ln,
           ROW_NUMBER() OVER (ORDER BY ABS(HASH(f.fn, l.ln, 'pick'))) AS n
    FROM firsts f CROSS JOIN lasts l
    QUALIFY n <= 400
),
places AS (
    SELECT ARRAY_CONSTRUCT(
        'Aurora|CO','Naperville|IL','Frisco|TX','Bellevue|WA','Cary|NC',
        'Gilbert|AZ','Overland Park|KS','Franklin|TN','Novi|MI','Reston|VA',
        'Katy|TX','Roswell|GA','Chandler|AZ','Eden Prairie|MN','Dublin|OH',
        'Carlsbad|CA','Wheaton|IL','Apex|NC','Draper|UT','Sugar Land|TX',
        'Brookfield|WI','Leesburg|VA','Peachtree City|GA','Beaverton|OR'
    ) AS a
)
SELECT
    'H' || LPAD(c.n::STRING, 4, '0')                         AS HOMEOWNER_ID,
    c.fn || ' ' || c.ln                                      AS FULL_NAME,
    SPLIT_PART(GET(p.a, MOD(ABS(HASH(c.n, 'city')), 24))::STRING, '|', 1) AS CITY,
    SPLIT_PART(GET(p.a, MOD(ABS(HASH(c.n, 'city')), 24))::STRING, '|', 2) AS STATE,
    -- Credit distribution weighted toward the middle of the book
    CASE
        WHEN MOD(ABS(HASH(c.n, 'credit')), 100) < 12 THEN 'POOR'
        WHEN MOD(ABS(HASH(c.n, 'credit')), 100) < 38 THEN 'FAIR'
        WHEN MOD(ABS(HASH(c.n, 'credit')), 100) < 76 THEN 'GOOD'
        ELSE 'EXCELLENT'
    END                                                      AS CREDIT_BAND,
    -- Representative FICO within the assigned band
    CASE
        WHEN MOD(ABS(HASH(c.n, 'credit')), 100) < 12 THEN 580 + MOD(ABS(HASH(c.n,'fico')), 40)
        WHEN MOD(ABS(HASH(c.n, 'credit')), 100) < 38 THEN 640 + MOD(ABS(HASH(c.n,'fico')), 40)
        WHEN MOD(ABS(HASH(c.n, 'credit')), 100) < 76 THEN 700 + MOD(ABS(HASH(c.n,'fico')), 40)
        ELSE 760 + MOD(ABS(HASH(c.n,'fico')), 45)
    END                                                      AS FICO_SCORE,
    CASE MOD(ABS(HASH(c.n, 'inc')), 5)
        WHEN 0 THEN '50-75K'   WHEN 1 THEN '75-100K'
        WHEN 2 THEN '100-150K' WHEN 3 THEN '150-225K'
        ELSE '225K+'
    END                                                      AS INCOME_BAND,
    12 + MOD(ABS(HASH(c.n, 'ten')), 96)                      AS CUSTOMER_TENURE_MONTHS,
    CASE WHEN MOD(ABS(HASH(c.n, 'esc')), 100) < 63 THEN TRUE ELSE FALSE END AS HAS_ESCROW
FROM combos c
CROSS JOIN places p;

-- Every borrower name must be unique, because the scoring tool in
-- 04_scoring.sql resolves borrowers by name. Expect 400 / 400.
SELECT COUNT(*) AS borrowers, COUNT(DISTINCT FULL_NAME) AS distinct_names
FROM HOMEOWNERS;


-- ---------------------------------------------------------------------------
-- PROPERTIES -- one property per homeowner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE PROPERTIES AS
SELECT
    'P' || SUBSTR(HOMEOWNER_ID, 2)                           AS PROPERTY_ID,
    HOMEOWNER_ID,
    CASE MOD(ABS(HASH(HOMEOWNER_ID, 'ptype')), 10)
        WHEN 0 THEN 'CONDO'
        WHEN 1 THEN 'TOWNHOUSE'
        WHEN 2 THEN 'MULTI_FAMILY'
        ELSE 'SINGLE_FAMILY'
    END                                                      AS PROPERTY_TYPE,
    ROUND((240000 + MOD(ABS(HASH(HOMEOWNER_ID, 'val')), 860000)) / 1000) * 1000 AS ESTIMATED_VALUE,
    2 + MOD(ABS(HASH(HOMEOWNER_ID, 'bed')), 4)               AS BEDROOMS,
    1960 + MOD(ABS(HASH(HOMEOWNER_ID, 'yr')), 62)            AS YEAR_BUILT
FROM HOMEOWNERS;


-- ---------------------------------------------------------------------------
-- LOANS -- one active mortgage per homeowner
--
-- Interest rates are correlated to origination year to mirror the shape of a
-- real book: 2020-2021 originations sit near 3%, while 2023-2024 originations
-- sit between 6.5% and 7.9%. This produces a genuine, identifiable refinance
-- population rather than a uniform spread.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE LOANS AS
WITH base AS (
    SELECT
        h.HOMEOWNER_ID,
        p.ESTIMATED_VALUE,
        DATEADD(day, -(MOD(ABS(HASH(h.HOMEOWNER_ID, 'orig')), 2400) + 120), CURRENT_DATE()) AS ORIGINATION_DATE,
        MOD(ABS(HASH(h.HOMEOWNER_ID, 'ltv')), 100)  AS ltv_roll,
        MOD(ABS(HASH(h.HOMEOWNER_ID, 'jit')), 60)   AS rate_jitter
    FROM HOMEOWNERS h
    JOIN PROPERTIES p USING (HOMEOWNER_ID)
),
rated AS (
    SELECT
        b.*,
        ROUND(
            CASE YEAR(b.ORIGINATION_DATE)
                WHEN 2019 THEN 4.10 WHEN 2020 THEN 3.00
                WHEN 2021 THEN 2.85 WHEN 2022 THEN 5.20
                WHEN 2023 THEN 6.90 WHEN 2024 THEN 7.10
                ELSE 6.45
            END + (b.rate_jitter / 100.0)
        , 3)                                          AS INTEREST_RATE_PCT
    FROM base b
)
SELECT
    'L' || SUBSTR(HOMEOWNER_ID, 2)                    AS LOAN_ID,
    HOMEOWNER_ID,
    ORIGINATION_DATE,
    INTEREST_RATE_PCT,
    CASE WHEN MOD(ABS(HASH(HOMEOWNER_ID, 'term')), 10) < 8 THEN 360 ELSE 180 END AS TERM_MONTHS,
    'FIXED'                                           AS RATE_TYPE,
    -- Original balance implied by a 5-25% down payment at origination
    ROUND(ESTIMATED_VALUE * (0.75 + (ltv_roll / 500.0)) / 1000) * 1000 AS ORIGINAL_BALANCE,
    -- Current balance amortised in proportion to the age of the loan
    ROUND(
        ESTIMATED_VALUE * (0.75 + (ltv_roll / 500.0))
        * (1 - LEAST(0.34, DATEDIFF(month, ORIGINATION_DATE, CURRENT_DATE()) * 0.0022))
        / 1000
    ) * 1000                                          AS CURRENT_BALANCE,
    DATEDIFF(month, ORIGINATION_DATE, CURRENT_DATE()) AS MONTHS_ON_BOOK,
    CASE WHEN MOD(ABS(HASH(HOMEOWNER_ID, 'del')), 100) < 6 THEN TRUE ELSE FALSE END AS HAS_LATE_PAYMENT_24M
FROM rated;


-- ---------------------------------------------------------------------------
-- CALL_TRANSCRIPTS -- 120 inbound calls over the last 7 days
--
-- Transcripts are composed from eight distinct conversation shapes with each
-- borrower's own name, city, rate, and balance substituted in, so the text
-- carries genuine per-row content for extraction to operate on.
--
-- Call intent is never stated in a structured field anywhere in this table.
-- It is expressed only in the language of the conversation, which is what the
-- AI functions in 02_ai_functions.sql are asked to infer.
--
-- Call volume is skewed toward higher-rate loans, consistent with the fact
-- that borrowers holding above-market rates are the ones who make contact.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE CALL_TRANSCRIPTS AS
WITH picked AS (
    SELECT
        h.HOMEOWNER_ID, h.FULL_NAME, h.CITY, h.STATE,
        l.INTEREST_RATE_PCT, l.CURRENT_BALANCE, l.TERM_MONTHS, l.MONTHS_ON_BOOK,
        ROW_NUMBER() OVER (
            ORDER BY (l.INTEREST_RATE_PCT * 100)::INT DESC,
                     ABS(HASH(h.HOMEOWNER_ID, 'call'))
        ) AS rn
    FROM HOMEOWNERS h
    JOIN LOANS l USING (HOMEOWNER_ID)
    QUALIFY rn <= 120
),
shaped AS (
    SELECT
        p.*,
        MOD(ABS(HASH(p.HOMEOWNER_ID, 'tmpl')), 8) AS tmpl,
        ROUND(p.INTEREST_RATE_PCT, 3)::STRING     AS rate_s,
        TRIM(TO_VARCHAR(p.CURRENT_BALANCE, '999,999')) AS bal_s,
        FLOOR((p.TERM_MONTHS - p.MONTHS_ON_BOOK) / 12)::STRING AS yrs_left
    FROM picked p
)
SELECT
    'C' || LPAD(rn::STRING, 4, '0')                AS CALL_ID,
    HOMEOWNER_ID,
    'A' || LPAD((MOD(ABS(HASH(HOMEOWNER_ID, 'agt')), 9) + 1)::STRING, 2, '0') AS AGENT_ID,
    DATEADD(
        minute,
        -(MOD(ABS(HASH(HOMEOWNER_ID, 'min')), 600) + 480),
        DATEADD(day, -(MOD(ABS(HASH(HOMEOWNER_ID, 'day')), 7) + 1), CURRENT_TIMESTAMP())
    )                                              AS CALL_TIMESTAMP,
    240 + MOD(ABS(HASH(HOMEOWNER_ID, 'dur')), 900) AS DURATION_SECONDS,
    CASE tmpl
      WHEN 0 THEN
        'Agent: Thank you for calling, this is Reece. Who do I have the pleasure of speaking with today? '
        || 'Caller: Hi Reece, this is ' || FULL_NAME || '. '
        || 'Agent: Great, and can you confirm the property address city for me? '
        || 'Caller: Sure, we are in ' || CITY || ', ' || STATE || '. '
        || 'Agent: Perfect, I have your file up. What can I help with? '
        || 'Caller: So I have been watching the news and everyone keeps saying rates came down. '
        || 'We are sitting at ' || rate_s || ' percent right now and honestly the payment is starting to squeeze us. '
        || 'I want to understand whether it is worth refinancing or whether the closing costs eat the whole benefit. '
        || 'Agent: That is exactly the right question. Your balance is around ' || bal_s || '. '
        || 'Caller: Right. And I do not want to reset back to thirty years, we have about ' || yrs_left || ' years left and I would rather not start over. '
        || 'Agent: Understood, we can look at a term-matched option. '
        || 'Caller: How fast could this happen? My wife and I are trying to decide before the end of the quarter.'
      WHEN 1 THEN
        'Agent: Thanks for calling, this is Priya speaking. '
        || 'Caller: Hi, my name is ' || FULL_NAME || ', I have a mortgage with you on my place in ' || CITY || '. '
        || 'Agent: Thanks, pulling that up now. '
        || 'Caller: Here is my situation. We need to do a fairly big kitchen and roof project, we are looking at maybe sixty thousand dollars. '
        || 'I would rather pull it out of the house than take a personal loan at a ridiculous rate. '
        || 'Agent: So you are thinking cash out rather than a straight rate reduction. '
        || 'Caller: Correct. Though if the rate happens to improve too I will take it. We are at ' || rate_s || ' percent currently. '
        || 'Agent: And you have owned roughly how long? '
        || 'Caller: A few years now. The house has gone up a lot, that is really why I am calling. '
        || 'Agent: Let me check what your available equity looks like. '
        || 'Caller: Please. And I need to know if this affects my escrow, that caught me out last time.'
      WHEN 2 THEN
        'Agent: Good afternoon, Marcus here. '
        || 'Caller: Afternoon. ' || FULL_NAME || ', calling about the loan on the ' || CITY || ' property. '
        || 'Agent: Of course. '
        || 'Caller: I am really just doing due diligence at this point. Someone at work refinanced and would not stop talking about it. '
        || 'I am at ' || rate_s || ' percent. I am not in any rush and I am not unhappy, I just want to know if I am leaving money on the table. '
        || 'Agent: Fair enough, no pressure from me either. '
        || 'Caller: What I do not want is to pay two thousand in fees to save forty dollars a month. '
        || 'Agent: Completely reasonable. I can run the breakeven for you. '
        || 'Caller: That would be helpful. Send it in writing if you can, I want to look at it with my accountant.'
      WHEN 3 THEN
        'Agent: Thanks for calling, this is Nadia. '
        || 'Caller: Hello. This is ' || FULL_NAME || '. I will be quick because I am between meetings. '
        || 'Agent: No problem. '
        || 'Caller: I need to get out of ' || rate_s || ' percent. We just had our second child, my partner has gone down to part time, '
        || 'and the mortgage payment is now the single biggest problem in our budget. '
        || 'Agent: I hear you, and I am sorry, that is a lot at once. '
        || 'Caller: So whatever gets the monthly payment down the most, that is what I want to hear about. '
        || 'Even if that means stretching the term back out, I know that costs more over time but I need breathing room now. '
        || 'Agent: That is a completely valid trade and we can absolutely model it. Balance is about ' || bal_s || '. '
        || 'Caller: Yes. How soon can someone call me back with actual numbers? Today if possible.'
      WHEN 4 THEN
        'Agent: Thanks for calling, Devon speaking. '
        || 'Caller: Hi Devon, ' || FULL_NAME || ' here, property is in ' || CITY || ' ' || STATE || '. '
        || 'Agent: Got it. '
        || 'Caller: I actually want to go the other direction from what you probably normally hear. '
        || 'I want to shorten the term. We are at ' || rate_s || ' percent on a thirty and I hate the idea of paying interest into my seventies. '
        || 'Agent: So a fifteen or twenty year option. '
        || 'Caller: Right. I can handle a higher payment, I would rather kill the balance faster. '
        || 'Agent: That often comes with a better rate too, so it may not hurt as much as you expect. '
        || 'Caller: Good. I have about ' || yrs_left || ' years left as it stands. Show me what a fifteen looks like.'
      WHEN 5 THEN
        'Agent: Good morning, Rosa speaking, how can I help? '
        || 'Caller: Hi, this is ' || FULL_NAME || '. Honestly I am calling because I got a letter from another lender. '
        || 'Agent: Ah, understood. '
        || 'Caller: They are quoting me something well under what I am paying now, I am at ' || rate_s || ' percent. '
        || 'I have been with you for years and I would rather not move, but I am not going to pay more out of loyalty. '
        || 'Agent: That is completely fair and I would rather keep your business. '
        || 'Caller: Then match it or get close. My balance is around ' || bal_s || ' and my credit is good, I checked. '
        || 'Agent: Let me see what we can put together. '
        || 'Caller: I need to know this week, their quote has an expiry on it.'
      WHEN 6 THEN
        'Agent: Thanks for calling, this is Colin. '
        || 'Caller: Hi Colin. ' || FULL_NAME || ', ' || CITY || '. '
        || 'Agent: Thanks, how can I help today? '
        || 'Caller: A couple of things. First, I think my escrow is wrong, the payment jumped and nobody explained why. '
        || 'Agent: Let me look. That is usually a tax reassessment. '
        || 'Caller: That would make sense, the county revalued us. Second thing, while I have you, what are rates doing? '
        || 'Agent: Currently better than where your loan sits, you are at ' || rate_s || ' percent. '
        || 'Caller: Hm. I was not really planning to refinance but that is a bigger gap than I thought. '
        || 'Agent: No obligation, I can just send you the comparison. '
        || 'Caller: Sure, send it. I am not committing to anything today though, I want to sort the escrow thing out first.'
      ELSE
        'Agent: Thank you for calling, this is Imani. '
        || 'Caller: Hello, ' || FULL_NAME || ' calling, we have the loan on the house in ' || CITY || '. '
        || 'Agent: I have you here. '
        || 'Caller: We are relocating for my job and I am trying to understand my options. '
        || 'Agent: Are you selling, or keeping it as a rental? '
        || 'Caller: Undecided, that is the thing. If we rent it out, does my ' || rate_s || ' percent change? '
        || 'Agent: The existing loan terms would not change, but a new investment property loan would price differently. '
        || 'Caller: Right, and refinancing before it becomes a rental would presumably be cheaper than after. '
        || 'Agent: That is generally true, yes. '
        || 'Caller: Okay, that is useful. I am maybe two months from making a decision, so keep me in the loop.'
    END                                            AS TRANSCRIPT_TEXT
FROM shaped;


-- ---------------------------------------------------------------------------
-- HISTORICAL_REFI_OUTCOMES -- 2,400 closed opportunities for model training
--
-- Each row is a refinance opportunity from the last 18 months, with the
-- features that were known at the time and whether the borrower went on to
-- refinance. Used by 04_scoring.sql to fit the propensity model.
--
-- The label is generated from an explicit logistic relationship over the
-- features, then sampled against a deterministic uniform. That means there is
-- real, learnable signal in the data with genuine noise on top -- the model has
-- something to find, but cannot reach perfect separation.
--
-- Feature ranges here are deliberately wider than the current book, including
-- below-market rates and high LTV, so the model is not extrapolating when it
-- meets a borrower outside the current segment.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE HISTORICAL_REFI_OUTCOMES AS
WITH seq AS (
    SELECT SEQ4() + 1 AS n FROM TABLE(GENERATOR(ROWCOUNT => 2400))
),
feat AS (
  SELECT
    'HX' || LPAD(n::STRING, 5, '0')                                     AS RECORD_ID,
    DATEADD(day, -(30 + MOD(ABS(HASH(n,'d')), 520)), CURRENT_DATE())    AS OPPORTUNITY_DATE,
    ROUND(-1.0 + MOD(ABS(HASH(n,'rd')), 380) / 100.0, 3)                AS RATE_DELTA_PCT,
    ROUND(55 + MOD(ABS(HASH(n,'ltv')), 40)
             + MOD(ABS(HASH(n,'ltv2')), 100) / 100.0, 1)                AS LTV_PCT,
    580 + MOD(ABS(HASH(n,'fi')), 225)                                   AS FICO_SCORE,
    ROUND((90000 + MOD(ABS(HASH(n,'bal')), 810000)) / 1000) * 1000      AS CURRENT_BALANCE,
    6 + MOD(ABS(HASH(n,'ten')), 132)                                    AS CUSTOMER_TENURE_MONTHS,
    CASE MOD(ABS(HASH(n,'int')), 6)
      WHEN 0 THEN 'RATE_REFI'      WHEN 1 THEN 'RATE_REFI'
      WHEN 2 THEN 'CASH_OUT'       WHEN 3 THEN 'PAYMENT_RELIEF'
      WHEN 4 THEN 'TERM_SHORTEN'   ELSE 'SERVICING_ONLY'
    END                                                                 AS CALL_INTENT,
    CASE MOD(ABS(HASH(n,'urg')), 3)
      WHEN 0 THEN 'HIGH' WHEN 1 THEN 'MEDIUM' ELSE 'LOW'
    END                                                                 AS URGENCY,
    MOD(ABS(HASH(n,'comp')), 100) < 22                                  AS COMPETITOR_MENTIONED,
    MOD(ABS(HASH(n,'u')), 10000) / 10000.0                              AS u
  FROM seq
),
scored AS (
  SELECT f.*,
    -1.85
      + 1.25  * RATE_DELTA_PCT
      - 0.030 * (LTV_PCT - 75)
      + 0.011 * (FICO_SCORE - 700)
      + CASE CALL_INTENT
          WHEN 'RATE_REFI'      THEN 0.60
          WHEN 'PAYMENT_RELIEF' THEN 0.40
          WHEN 'CASH_OUT'       THEN 0.25
          WHEN 'TERM_SHORTEN'   THEN 0.10
          ELSE -0.70 END
      + CASE URGENCY WHEN 'HIGH' THEN 0.80 WHEN 'MEDIUM' THEN 0.25 ELSE 0 END
      + IFF(COMPETITOR_MENTIONED, 0.45, 0)
      - 0.0035 * CUSTOMER_TENURE_MONTHS
      + 0.0000004 * (CURRENT_BALANCE - 400000)
      AS logit
  FROM feat f
)
SELECT
  RECORD_ID, OPPORTUNITY_DATE, RATE_DELTA_PCT, LTV_PCT, FICO_SCORE,
  CURRENT_BALANCE, CUSTOMER_TENURE_MONTHS, CALL_INTENT, URGENCY,
  COMPETITOR_MENTIONED,
  IFF(1.0 / (1.0 + EXP(-logit)) > u, TRUE, FALSE) AS DID_REFI
FROM scored;


-- ---------------------------------------------------------------------------
-- Row counts
-- ---------------------------------------------------------------------------
SELECT 'HOMEOWNERS' AS table_name, COUNT(*) AS row_count FROM HOMEOWNERS
UNION ALL SELECT 'PROPERTIES',                COUNT(*) FROM PROPERTIES
UNION ALL SELECT 'LOANS',                     COUNT(*) FROM LOANS
UNION ALL SELECT 'CALL_TRANSCRIPTS',          COUNT(*) FROM CALL_TRANSCRIPTS
UNION ALL SELECT 'HISTORICAL_REFI_OUTCOMES',  COUNT(*) FROM HISTORICAL_REFI_OUTCOMES
ORDER BY table_name;
