/* ============================================================================
   Snowflake Cortex Workshop
   02_ai_functions.sql -- Turning call transcripts into structured signals

   This file covers five Cortex AI functions applied to the transcript corpus:

     AI_EXTRACT       pull named fields out of unstructured conversation
     AI_CLASSIFY      assign each call to a controlled intent taxonomy
     AI_COUNT_TOKENS  estimate what a call will cost before running it
     AI_COMPLETE      summarise, and handle long transcripts by chunking
     AI_SUMMARIZE_AGG roll many calls up into a single narrative

   Inference runs once and the results are persisted to CALL_SIGNALS. Everything
   downstream -- the semantic view, the agent, the scoring model -- reads that
   table, so the cost of extraction is paid once rather than on every query.

   All statements are CREATE OR REPLACE and safe to re-run.
   ========================================================================== */

USE WAREHOUSE CORTEX_DEMO_WH;
USE DATABASE CORTEX_REFI_DEMO;
USE SCHEMA MORTGAGE;


-- ---------------------------------------------------------------------------
-- 1. AI_EXTRACT on a single call
--
-- responseFormat takes plain-language descriptions of the fields you want.
-- There is no schema to define and no model to train.
--
-- Run this first on one row to see the shape of the response before applying
-- it to the whole corpus.
-- ---------------------------------------------------------------------------
SELECT
    CALL_ID,
    TO_VARCHAR(AI_EXTRACT(
        text => TRANSCRIPT_TEXT,
        responseFormat => {
            'borrower_name'    : 'full name of the caller',
            'property_city'    : 'city where the property is located',
            'current_rate_pct' : 'current mortgage interest rate as a number only',
            'life_event'       : 'any major life event mentioned, or NONE',
            'urgency'          : 'how urgently the caller wants to act: HIGH, MEDIUM or LOW',
            'competitor_mentioned' : 'TRUE if another lender was mentioned, otherwise FALSE',
            'requested_callback'   : 'TRUE if the caller asked to be contacted back, otherwise FALSE'
        }
    )) AS extracted
FROM CALL_TRANSCRIPTS
WHERE CALL_ID = 'C0003';


-- ---------------------------------------------------------------------------
-- 2. AI_CLASSIFY on a single call
--
-- Extraction is good at reading values that appear in the text. Classification
-- is the right tool for assigning a call to a fixed set of business categories,
-- because the category names are yours and the output is constrained to them.
--
-- Extraction reports what was said; classification decides what the call was
-- about.
--
-- Bare label names first, to establish the baseline:
-- ---------------------------------------------------------------------------
SELECT
    CALL_ID,
    TO_VARCHAR(AI_CLASSIFY(
        TRANSCRIPT_TEXT,
        ['RATE_REFI', 'CASH_OUT', 'TERM_SHORTEN', 'PAYMENT_RELIEF', 'SERVICING_ONLY']
    )) AS classified
FROM CALL_TRANSCRIPTS
WHERE CALL_ID IN ('C0001', 'C0004')
ORDER BY CALL_ID;

-- Run against the full corpus, bare labels put 84 of 120 calls into RATE_REFI
-- and returned PAYMENT_RELIEF zero times. A borrower saying "my partner went
-- part time and the payment is the biggest problem in our budget" is a
-- different commercial situation from one shopping a competitor quote, but the
-- label name RATE_REFI is broad enough to absorb both.
--
-- Passing a description alongside each label resolves it. The labels become
-- definitions rather than keywords, which is also where the business meaning
-- gets recorded:
SELECT
    CALL_ID,
    TO_VARCHAR(AI_CLASSIFY(TRANSCRIPT_TEXT, [
        {'label':'RATE_REFI',
         'description':'Borrower wants a lower interest rate, comparing against market or a competitor quote, primarily to reduce total interest cost'},
        {'label':'CASH_OUT',
         'description':'Borrower wants to withdraw equity from the property, typically for renovation, debt consolidation or another large expense'},
        {'label':'TERM_SHORTEN',
         'description':'Borrower wants to pay the loan off sooner and is willing to accept a higher monthly payment'},
        {'label':'PAYMENT_RELIEF',
         'description':'Borrower is under financial strain and needs the monthly payment reduced, and is willing to extend the term to get it'},
        {'label':'SERVICING_ONLY',
         'description':'Borrower called about an account or escrow matter and is not seeking new financing'},
        {'label':'RELOCATION',
         'description':'Borrower is moving and asking how selling or renting the property affects their loan'}
    ])) AS classified
FROM CALL_TRANSCRIPTS
WHERE CALL_ID IN ('C0001', 'C0004')
ORDER BY CALL_ID;


-- ---------------------------------------------------------------------------
-- 3. AI_COUNT_TOKENS -- sizing the work before paying for it
--
-- AI functions bill on tokens, so the prompt design choices above have a price.
-- AI_COUNT_TOKENS estimates the input tokens a call will consume without
-- running inference, which makes that price visible before a job runs rather
-- than after it appears on a bill.
--
-- Two things about the signature that are easy to get wrong:
--
--   The FIRST argument is the FUNCTION name, not the model -- 'ai_complete',
--   lowercase, and it must start with 'ai_'. The model name, where the function
--   needs one, is the second argument. Passing a model first returns NULL with
--   no explanation.
--
--   On any bad input the function returns a bare NULL by default. Pass
--   return_error_details => TRUE to get an object with value and error fields
--   instead, which is the only way to see why a call produced nothing.
-- ---------------------------------------------------------------------------

-- Per-call estimate for the summarisation prompt
SELECT
    CALL_ID,
    LENGTH(TRANSCRIPT_TEXT)                                                AS chars,
    AI_COUNT_TOKENS('ai_complete', 'claude-sonnet-4-5', TRANSCRIPT_TEXT)   AS summarise_tokens
FROM CALL_TRANSCRIPTS
ORDER BY CALL_ID
LIMIT 5;


-- What the label descriptions from section 2 actually cost.
--
-- Classification token count includes the labels themselves, so richer label
-- definitions are billable. Bare labels come to 362 tokens for this call;
-- described labels come to 494. That is 132 extra tokens, about 36% more, and
-- it is what bought the correct six-way split instead of 84 of 120 calls
-- collapsing into RATE_REFI.
--
-- Worth stating plainly: that is a good trade here. The point of measuring it
-- is to be able to say so with a number rather than an opinion.
SELECT
    AI_COUNT_TOKENS('ai_classify', TRANSCRIPT_TEXT,
        ['RATE_REFI','CASH_OUT','TERM_SHORTEN','PAYMENT_RELIEF','SERVICING_ONLY','RELOCATION']
    ) AS bare_labels_tokens,
    AI_COUNT_TOKENS('ai_classify', TRANSCRIPT_TEXT, [
        {'label':'RATE_REFI',
         'description':'Borrower wants a lower interest rate, comparing against market or a competitor quote, primarily to reduce total interest cost'},
        {'label':'CASH_OUT',
         'description':'Borrower wants to withdraw equity from the property, typically for renovation, debt consolidation or another large expense'},
        {'label':'TERM_SHORTEN',
         'description':'Borrower wants to pay the loan off sooner and is willing to accept a higher monthly payment'},
        {'label':'PAYMENT_RELIEF',
         'description':'Borrower is under financial strain and needs the monthly payment reduced, and is willing to extend the term to get it'},
        {'label':'SERVICING_ONLY',
         'description':'Borrower called about an account or escrow matter and is not seeking new financing'},
        {'label':'RELOCATION',
         'description':'Borrower is moving and asking how selling or renting the property affects their loan'}
    ]) AS described_labels_tokens
FROM CALL_TRANSCRIPTS
WHERE CALL_ID = 'C0001';


-- Total input tokens for the whole corpus, before running anything.
-- Expect roughly 22,500 for summarisation and 44,800 for classification
-- across the 120 calls, averaging about 188 tokens per call to summarise.
SELECT
    COUNT(*)                                                                     AS calls,
    SUM(AI_COUNT_TOKENS('ai_complete', 'claude-sonnet-4-5', TRANSCRIPT_TEXT))     AS summarise_input_tokens,
    SUM(AI_COUNT_TOKENS('ai_classify', TRANSCRIPT_TEXT,
        ['RATE_REFI','CASH_OUT','TERM_SHORTEN','PAYMENT_RELIEF','SERVICING_ONLY','RELOCATION']
    ))                                                                           AS classify_input_tokens,
    ROUND(AVG(AI_COUNT_TOKENS('ai_complete', 'claude-sonnet-4-5', TRANSCRIPT_TEXT)), 0) AS avg_tokens_per_call
FROM CALL_TRANSCRIPTS;


-- ---------------------------------------------------------------------------
-- Limits worth knowing
--
--   AI_EXTRACT is not supported. Only ai_classify, ai_complete, ai_embed,
--   ai_sentiment, ai_similarity, ai_translate and ai_redact are. Asking for
--   ai_extract returns 'invalid request parameters: AI_EXTRACT', which you only
--   see with return_error_details turned on -- otherwise it is a silent NULL.
--
--   Only INPUT tokens are estimated. Generated output tokens are also billed
--   and are not included here, so treat these figures as a floor.
--
--   On Claude models the count is an estimate with relative error under 3%.
--   If you use structured output (response_format), the billed input can be
--   materially higher than the estimate.
--
--   For actual billed input and output tokens after the fact, query
--   CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY.
-- ---------------------------------------------------------------------------
SELECT
    AI_COUNT_TOKENS('ai_extract', 'sample text', TRUE):value::INT    AS value,
    AI_COUNT_TOKENS('ai_extract', 'sample text', TRUE):error::STRING AS error;


-- ---------------------------------------------------------------------------
-- 4. CALL_SIGNALS -- the full corpus, extracted, classified and summarised
--
-- Three normalisations worth noting, all of which apply to any production use
-- of these functions:
--
--   Free-text booleans come back with inconsistent casing (TRUE / True), so
--   they are upper-cased before comparison.
--
--   Absent values come back as the string 'None' rather than SQL NULL, so
--   they are converted explicitly. Without this, "how many calls mentioned a
--   life event" counts every call, and "NONE" appears as a fourth urgency
--   level alongside HIGH, MEDIUM and LOW.
--
--   Numerics arrive as strings, so TRY_TO_DOUBLE is used rather than a cast
--   that would fail the whole statement on one unparseable value.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE CALL_SIGNALS AS
WITH inferred AS (
    SELECT
        t.CALL_ID,
        t.HOMEOWNER_ID,
        t.AGENT_ID,
        t.CALL_TIMESTAMP,
        t.DURATION_SECONDS,
        t.TRANSCRIPT_TEXT,
        AI_EXTRACT(
            text => t.TRANSCRIPT_TEXT,
            responseFormat => {
                'borrower_name'    : 'full name of the caller',
                'property_city'    : 'city where the property is located',
                'current_rate_pct' : 'current mortgage interest rate as a number only',
                'life_event'       : 'any major life event mentioned, or NONE',
                'urgency'          : 'how urgently the caller wants to act: HIGH, MEDIUM or LOW',
                'competitor_mentioned' : 'TRUE if another lender was mentioned, otherwise FALSE',
                'requested_callback'   : 'TRUE if the caller asked to be contacted back, otherwise FALSE'
            }
        ) AS x,
        AI_CLASSIFY(t.TRANSCRIPT_TEXT, [
            {'label':'RATE_REFI',
             'description':'Borrower wants a lower interest rate, comparing against market or a competitor quote, primarily to reduce total interest cost'},
            {'label':'CASH_OUT',
             'description':'Borrower wants to withdraw equity from the property, typically for renovation, debt consolidation or another large expense'},
            {'label':'TERM_SHORTEN',
             'description':'Borrower wants to pay the loan off sooner and is willing to accept a higher monthly payment'},
            {'label':'PAYMENT_RELIEF',
             'description':'Borrower is under financial strain and needs the monthly payment reduced, and is willing to extend the term to get it'},
            {'label':'SERVICING_ONLY',
             'description':'Borrower called about an account or escrow matter and is not seeking new financing'},
            {'label':'RELOCATION',
             'description':'Borrower is moving and asking how selling or renting the property affects their loan'}
        ]) AS c,
        AI_COMPLETE(
            'claude-sonnet-4-5',
            'Summarise this mortgage servicing call in one sentence of at most 25 words. '
         || 'State what the borrower wants and any constraint they raised. '
         || 'Reply with the sentence only.\n\n' || t.TRANSCRIPT_TEXT
        ) AS s
    FROM CALL_TRANSCRIPTS t
)
SELECT
    CALL_ID,
    HOMEOWNER_ID,
    AGENT_ID,
    CALL_TIMESTAMP,
    DURATION_SECONDS,
    TO_VARCHAR(x:response:borrower_name)                        AS EXTRACTED_NAME,
    NULLIF(TO_VARCHAR(x:response:property_city), 'None')        AS EXTRACTED_CITY,
    TRY_TO_DOUBLE(TO_VARCHAR(x:response:current_rate_pct))      AS EXTRACTED_RATE_PCT,
    -- 'None' / 'NONE' / 'none' all mean no life event was raised
    CASE
        WHEN UPPER(TO_VARCHAR(x:response:life_event)) IN ('NONE', '') THEN NULL
        ELSE TO_VARCHAR(x:response:life_event)
    END                                                          AS LIFE_EVENT,
    -- Urgency is only meaningful when the caller actually signalled it
    NULLIF(UPPER(TO_VARCHAR(x:response:urgency)), 'NONE')         AS URGENCY,
    UPPER(TO_VARCHAR(x:response:competitor_mentioned)) = 'TRUE'   AS COMPETITOR_MENTIONED,
    UPPER(TO_VARCHAR(x:response:requested_callback))   = 'TRUE'   AS REQUESTED_CALLBACK,
    TO_VARCHAR(c:labels[0])                                      AS CALL_INTENT,
    TRIM(s)                                                      AS CALL_SUMMARY,
    LENGTH(TRANSCRIPT_TEXT)                                      AS TRANSCRIPT_CHARS
FROM inferred;


-- Sanity check: intent distribution and extraction fill rate
SELECT
    CALL_INTENT,
    COUNT(*)                                                     AS calls,
    COUNT(EXTRACTED_RATE_PCT)                                    AS rate_captured,
    COUNT(LIFE_EVENT)                                            AS life_event_raised,
    SUM(IFF(COMPETITOR_MENTIONED, 1, 0))                         AS competitor_named
FROM CALL_SIGNALS
GROUP BY CALL_INTENT
ORDER BY calls DESC;


-- ---------------------------------------------------------------------------
-- 5. Long transcripts: chunk, map, reduce
--
-- A one-hour consultation, or a call history concatenated across several
-- touchpoints, can exceed what you can or want to send in a single request.
--
-- The pattern is map-reduce:
--   chunk the text  ->  summarise each chunk  ->  summarise the summaries
--
-- Be clear about why you would do this, because it is not to save money.
-- Measured with AI_COUNT_TOKENS over the five consultations below:
--
--   one pass    5 calls,  6,213 input tokens
--   chunked    25 calls,  7,376 input tokens   (+18.7%)
--
-- Chunking costs about 19% more input tokens and five times the number of
-- calls, because each chunk re-pays the per-call prompt overhead and splitting
-- mid-sentence wastes a few tokens at every boundary. You chunk when the input
-- will not fit, when you want to parallelise for latency, or when you need
-- per-section attribution -- not to reduce spend.
--
-- LONG_CONSULTATIONS below holds multi-session consultation records built by
-- concatenating a borrower's inbound call with the follow-up stages that
-- followed it, which is how these conversations accumulate in practice. At
-- around 5,500 characters they are long enough to make the pattern real at a
-- realistic size, though they would still fit in one pass on a modern model.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE LONG_CONSULTATIONS AS
WITH top_callers AS (
    SELECT c.CALL_ID, c.HOMEOWNER_ID, c.TRANSCRIPT_TEXT, l.INTEREST_RATE_PCT,
           ROW_NUMBER() OVER (ORDER BY l.INTEREST_RATE_PCT DESC) AS rn
    FROM CALL_TRANSCRIPTS c
    JOIN LOANS l USING (HOMEOWNER_ID)
    QUALIFY rn <= 5
),
stages AS (
    SELECT ARRAY_CONSTRUCT(
      ' [Session 2 -- Discovery] Agent: Picking up where we left off, I want to walk through your goals properly. Caller: Sure. The main thing is the monthly payment, but I also do not want to extend the horizon by another decade. Agent: Understood. Let us separate the two. If we hold the term roughly where it is, the saving is smaller but the total interest drops meaningfully. If we reset the clock, the monthly saving looks dramatic but you pay more overall. Caller: I have heard that framed as good and bad and I never know which is true. Agent: Both are true, they optimise for different things. Which matters more to you right now, monthly cash flow or lifetime cost? Caller: Cash flow this year, lifetime cost after that. Agent: That is a common answer and it points toward a shorter term with a rate reduction rather than a full reset. Caller: Okay. What about the fees, is there a version with no closing costs? Agent: There is, but the rate is higher to compensate, so it only wins if you plan to move or refinance again within a few years. Caller: We are staying put. Agent: Then paying the costs up front is very likely the better economics for you.',
      ' [Session 3 -- Documentation] Agent: I need to collect a few documents before we can issue anything firm. Caller: Go ahead. Agent: Two most recent pay statements, last two years of tax returns, and a current statement for the mortgage. Caller: The tax returns are with my accountant, I can get them this week. Agent: That is fine. Are you self-employed or any variable income? Caller: My base is salaried, but roughly a quarter of my pay is an annual bonus. Agent: We can use bonus income if there is a two-year history of it. Caller: There is, going back further than that. Agent: Good, that helps the debt-to-income calculation considerably. Caller: Does the bonus timing matter? It lands in March. Agent: Not for qualification, only the history matters. Caller: And do you need anything from my partner? Agent: Only if they are going on the loan. If the property is jointly titled but the loan is in your name alone, we handle that with a consent form rather than a full application.',
      ' [Session 4 -- Appraisal and valuation] Agent: The valuation came back and I want to go through it with you. Caller: Was it what you expected? Agent: It came in slightly under the estimate we were working from, which changes the loan-to-value band you fall into. Caller: Does that change my rate? Agent: It can. There are pricing thresholds at certain loan-to-value levels, and you are close to one. Caller: How close? Agent: Close enough that bringing a modest amount to closing would move you into the better band, and the rate improvement would pay that back within about a year and a half. Caller: That seems worth doing. Can you show me the arithmetic? Agent: I will send it in writing. There is also the option to dispute the valuation if you have recent comparable sales, though that adds two to three weeks. Caller: I would rather not delay. Let us look at the amount to close.',
      ' [Session 5 -- Rate lock] Agent: Rates moved this morning and I wanted to reach you before the day ends. Caller: In which direction? Agent: Down, modestly. If you want to lock, this is a reasonable moment. Caller: How long is the lock? Agent: Thirty, forty-five or sixty days. Thirty is cheapest but leaves no room if the file slows down. Caller: What is realistic for my file? Agent: Yours is straightforward, but the documentation is not fully in yet, so I would take forty-five to be safe. Caller: And if rates fall further after I lock? Agent: There is a one-time float-down provision if the market improves by more than a quarter point before closing. Caller: That seems like a reasonable hedge. Agent: It is, and it costs nothing additional on this product. Caller: Then let us lock at forty-five days with the float-down.',
      ' [Session 6 -- Closing coordination] Agent: We are clear to schedule. Caller: Finally. What do I need to do? Agent: Choose a closing date, arrange the funds to close, and review the disclosure when it arrives -- you have three business days with it before we can proceed. Caller: Can we close at the end of the month? Agent: We can, and there is a small advantage to it. Closing later in the month reduces the prepaid interest you bring to the table. Caller: Then let us aim for that. Agent: I will also flag that your first payment on the new loan will not be due for about six weeks, which people often mistake for a missed bill. Caller: Good to know, I would have panicked. Agent: One last item, your existing escrow balance will be refunded separately by the current servicer, usually within three weeks of payoff. Caller: So I should not count on it for the closing funds. Agent: Correct, treat it as money that arrives afterwards.'
    ) AS a
)
SELECT
    'LC' || LPAD(t.rn::STRING, 3, '0')  AS CONSULTATION_ID,
    t.HOMEOWNER_ID,
    t.CALL_ID                            AS ORIGINATING_CALL_ID,
    t.TRANSCRIPT_TEXT
      || GET(s.a, 0)::STRING || GET(s.a, 1)::STRING || GET(s.a, 2)::STRING
      || GET(s.a, 3)::STRING || GET(s.a, 4)::STRING
                                         AS CONSULTATION_TEXT
FROM top_callers t
CROSS JOIN stages s;

-- These records are several thousand characters each
SELECT CONSULTATION_ID, HOMEOWNER_ID, LENGTH(CONSULTATION_TEXT) AS chars
FROM LONG_CONSULTATIONS
ORDER BY CONSULTATION_ID;


-- The token arithmetic behind the note above. Run this after the chunk view and
-- the summaries table exist, to see the one-pass and chunked costs side by side.
WITH one_pass AS (
    SELECT SUM(AI_COUNT_TOKENS('ai_complete','claude-sonnet-4-5', CONSULTATION_TEXT)) AS t,
           COUNT(*) AS calls
    FROM LONG_CONSULTATIONS
),
map_step AS (
    SELECT SUM(AI_COUNT_TOKENS('ai_complete','claude-sonnet-4-5', CHUNK_TEXT)) AS t,
           COUNT(*) AS calls
    FROM CONSULTATION_CHUNKS
),
reduce_step AS (
    SELECT SUM(AI_COUNT_TOKENS('ai_complete','claude-sonnet-4-5', CHUNK_SUMMARIES)) AS t,
           COUNT(*) AS calls
    FROM CONSULTATION_SUMMARIES
)
SELECT
    o.calls                     AS one_pass_calls,
    o.t                         AS one_pass_tokens,
    m.calls + r.calls           AS chunked_calls,
    m.t + r.t                   AS chunked_tokens,
    ROUND((m.t + r.t) * 100.0 / o.t - 100, 1) AS pct_more_input_tokens
FROM one_pass o, map_step m, reduce_step r;


-- Step 1 (chunk): split each consultation into fixed-size windows.
-- The generator supplies chunk indices; the join keeps only the indices each
-- record actually needs, so short records produce one chunk and long records
-- produce many.
CREATE OR REPLACE VIEW CONSULTATION_CHUNKS AS
WITH sized AS (
    SELECT
        CONSULTATION_ID,
        HOMEOWNER_ID,
        CONSULTATION_TEXT,
        CEIL(LENGTH(CONSULTATION_TEXT) / 1500.0) AS n_chunks
    FROM LONG_CONSULTATIONS
),
idx AS (
    SELECT SEQ4() AS i FROM TABLE(GENERATOR(ROWCOUNT => 100))
)
SELECT
    s.CONSULTATION_ID,
    s.HOMEOWNER_ID,
    idx.i + 1                                              AS CHUNK_SEQ,
    s.n_chunks                                             AS CHUNK_TOTAL,
    SUBSTR(s.CONSULTATION_TEXT, idx.i * 1500 + 1, 1500)    AS CHUNK_TEXT
FROM sized s
JOIN idx ON idx.i < s.n_chunks;


-- Step 2 (map): summarise every chunk independently.
-- Step 3 (reduce): concatenate the chunk summaries in order and summarise once
-- more to produce a single coherent account of the whole consultation.
CREATE OR REPLACE TABLE CONSULTATION_SUMMARIES AS
WITH mapped AS (
    SELECT
        CONSULTATION_ID,
        HOMEOWNER_ID,
        CHUNK_SEQ,
        CHUNK_TOTAL,
        AI_COMPLETE(
            'claude-sonnet-4-5',
            'This is one excerpt from a longer mortgage refinance consultation. '
         || 'Summarise only what happens in this excerpt, in at most 40 words. '
         || 'Do not speculate about what came before or after.\n\n' || CHUNK_TEXT
        ) AS chunk_summary
    FROM CONSULTATION_CHUNKS
),
stitched AS (
    SELECT
        CONSULTATION_ID,
        HOMEOWNER_ID,
        ANY_VALUE(CHUNK_TOTAL) AS CHUNKS_PROCESSED,
        LISTAGG(chunk_summary, ' ') WITHIN GROUP (ORDER BY CHUNK_SEQ) AS joined_summaries
    FROM mapped
    GROUP BY CONSULTATION_ID, HOMEOWNER_ID
)
SELECT
    CONSULTATION_ID,
    HOMEOWNER_ID,
    CHUNKS_PROCESSED,
    TRIM(AI_COMPLETE(
        'claude-sonnet-4-5',
        'The following are sequential summaries of sections of a single mortgage '
     || 'refinance consultation. Write one consolidated summary of at most 80 words '
     || 'covering what the borrower wants, the constraints raised, and where the '
     || 'conversation ended. Reply with the summary only.\n\n' || joined_summaries
    ))                       AS CONSOLIDATED_SUMMARY,
    joined_summaries         AS CHUNK_SUMMARIES
FROM stitched;

SELECT CONSULTATION_ID, CHUNKS_PROCESSED, CONSOLIDATED_SUMMARY
FROM CONSULTATION_SUMMARIES
ORDER BY CONSULTATION_ID;


-- ---------------------------------------------------------------------------
-- 6. AI_SUMMARIZE_AGG -- many rows into one narrative
--
-- Where AI_COMPLETE handles one text at a time, AI_SUMMARIZE_AGG is an
-- aggregate: it reduces a whole group of rows to a single summary. Useful for
-- "what were my agents hearing this week" without reading 120 transcripts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE AGENT_DAILY_THEMES AS
SELECT
    AGENT_ID,
    CALL_TIMESTAMP::DATE            AS CALL_DATE,
    COUNT(*)                        AS CALLS_HANDLED,
    AI_SUMMARIZE_AGG(CALL_SUMMARY)  AS THEMES
FROM CALL_SIGNALS
GROUP BY AGENT_ID, CALL_TIMESTAMP::DATE;

SELECT AGENT_ID, CALL_DATE, CALLS_HANDLED, THEMES
FROM AGENT_DAILY_THEMES
ORDER BY CALLS_HANDLED DESC
LIMIT 5;


-- ---------------------------------------------------------------------------
-- Continue to 03_semantic_view.sql, which joins these signals to the loan book.
-- ---------------------------------------------------------------------------
