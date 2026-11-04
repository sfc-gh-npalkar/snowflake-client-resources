-- 04_extract.sql
-- Hybrid extraction.
--   Header fields: entity extraction with scores => TRUE (one score per field).
--   Claim lines:   table extraction on the FILE (keeps layout), one aggregate score per table.
-- Text-mode table extraction scrambled columns in testing, so lines are extracted from the file
-- and mapped back to a page by searching for the claim number in DOCUMENT_PAGES.
-- Table output is capped at 4,096 tokens, so very long loss runs may truncate; the
-- row-count check in 05_checks.sql flags that.

USE SCHEMA LOSS_RUN_DEMO.PIPELINE;
USE WAREHOUSE LOSS_RUN_WH;

CREATE OR REPLACE TABLE EXTRACTIONS AS
SELECT
    t.FILE_PATH,
    AI_EXTRACT(
        file => TO_FILE('@LOSS_RUN_DEMO.PIPELINE.DOCS', t.FILE_PATH),
        responseFormat => {
            'insured_name':   'What is the named insured?',
            'carrier_name':   'What insurance carrier issued this loss run?',
            'policy_number':  'What is the policy number?',
            'policy_period':  'What is the policy period (effective to expiration)?',
            'valuation_date': 'What is the valuation or as-of date of this loss run?',
            'claim_count':    'How many claims are listed in total?',
            'total_paid':     'What is the total loss paid amount printed on the document?',
            'total_incurred': 'What is the total incurred amount printed on the document?'
        },
        scores => TRUE
    ) AS HEADER_RESULT,
    AI_EXTRACT(
        file => TO_FILE('@LOSS_RUN_DEMO.PIPELINE.DOCS', t.FILE_PATH),
        responseFormat => {'schema': {'type': 'object', 'properties': {
            'claims': {
                'description': 'One row per individual claim or loss. Skip policy summary, loss ratio, and total rows.',
                'type': 'object',
                'column_ordering': ['claim_number','loss_date','status','coverage','description','paid','reserve','expense','incurred'],
                'properties': {
                    'claim_number': {'description': 'Claim number, loss file #, or occurrence number', 'type': 'array'},
                    'loss_date':    {'description': 'Date of loss', 'type': 'array'},
                    'status':       {'description': 'Open, Closed, or Report Only', 'type': 'array'},
                    'coverage':     {'description': 'Coverage or line of business', 'type': 'array'},
                    'description':  {'description': 'Loss description', 'type': 'array'},
                    'paid':         {'description': 'Loss paid amount', 'type': 'array'},
                    'reserve':      {'description': 'Outstanding loss reserve', 'type': 'array'},
                    'expense':      {'description': 'Expense paid amount', 'type': 'array'},
                    'incurred':     {'description': 'Total incurred, only if printed', 'type': 'array'}
                }}}}},
        scores => TRUE
    ) AS LINES_RESULT
FROM DOCUMENT_TYPES t
WHERE t.DOCUMENT_TYPE = 'loss run';

-- Header fields: one row per document, value + score per field.
CREATE OR REPLACE TABLE LOSS_RUN_HEADER_FIELDS AS
SELECT
    e.FILE_PATH,
    f.key                                                   AS FIELD_NAME,
    NULLIF(f.value::VARCHAR, 'None')                        AS FIELD_VALUE,
    e.HEADER_RESULT:scoring:scores[f.key]:score::FLOAT      AS SCORE
FROM EXTRACTIONS e,
     LATERAL FLATTEN(input => e.HEADER_RESULT:response) f;

-- Parses one money cell. A cell holding more than one number (merged columns)
-- returns NULL so the row is flagged for review instead of producing a bogus value.
CREATE OR REPLACE FUNCTION PARSE_AMOUNT(RAW VARCHAR)
RETURNS NUMBER(18,2)
AS
$$
    IFF(REGEXP_COUNT(RAW, '[0-9][0-9,]*(\\.[0-9]+)?') = 1,
        TRY_TO_NUMBER(REGEXP_REPLACE(RAW, '[^0-9.-]', ''), 18, 2),
        NULL)
$$;

-- Claim lines: zip the column arrays back into rows. Raw strings are kept for review.
CREATE OR REPLACE TABLE LOSS_RUN_LINES AS
WITH c AS (
    SELECT FILE_PATH,
           LINES_RESULT:response:claims AS T,
           LINES_RESULT:scoring:scores:claims:score::FLOAT AS TABLE_SCORE
    FROM EXTRACTIONS
),
z AS (
    SELECT
        c.FILE_PATH,
        n.index                                                AS LINE_NUMBER,
        NULLIF(c.T:claim_number[n.index]::VARCHAR, 'None')     AS CLAIM_NUMBER,
        NULLIF(c.T:loss_date[n.index]::VARCHAR, 'None')        AS LOSS_DATE_RAW,
        NULLIF(c.T:status[n.index]::VARCHAR, 'None')           AS STATUS,
        NULLIF(c.T:coverage[n.index]::VARCHAR, 'None')         AS COVERAGE,
        NULLIF(c.T:description[n.index]::VARCHAR, 'None')      AS DESCRIPTION,
        NULLIF(c.T:paid[n.index]::VARCHAR, 'None')             AS PAID_RAW,
        NULLIF(c.T:reserve[n.index]::VARCHAR, 'None')          AS RESERVE_RAW,
        NULLIF(c.T:expense[n.index]::VARCHAR, 'None')          AS EXPENSE_RAW,
        NULLIF(c.T:incurred[n.index]::VARCHAR, 'None')         AS INCURRED_RAW,
        c.TABLE_SCORE
    FROM c,
         LATERAL FLATTEN(input => c.T:claim_number) n
)
SELECT
    z.*,
    REGEXP_SUBSTR(CLAIM_NUMBER, '[A-Za-z0-9][A-Za-z0-9-]{4,}')     AS CLAIM_KEY,
    TRY_TO_DATE(LOSS_DATE_RAW, 'MM/DD/YYYY')                         AS LOSS_DATE,
    PARSE_AMOUNT(PAID_RAW)                                           AS PAID,
    PARSE_AMOUNT(RESERVE_RAW)                                        AS RESERVE,
    PARSE_AMOUNT(EXPENSE_RAW)                                        AS EXPENSE,
    PARSE_AMOUNT(INCURRED_RAW)                                       AS INCURRED_PRINTED,
    (PAID_RAW IS NOT NULL AND PARSE_AMOUNT(PAID_RAW) IS NULL)
      OR (RESERVE_RAW IS NOT NULL AND PARSE_AMOUNT(RESERVE_RAW) IS NULL)
      OR (EXPENSE_RAW IS NOT NULL AND PARSE_AMOUNT(EXPENSE_RAW) IS NULL) AS AMOUNT_PARSE_ISSUE
FROM z;

-- Map each claim line to the first page that mentions its claim number.
CREATE OR REPLACE TABLE LOSS_RUN_LINE_PAGES AS
SELECT l.FILE_PATH, l.LINE_NUMBER, MIN(p.PAGE_INDEX) AS PAGE_INDEX
FROM LOSS_RUN_LINES l
JOIN DOCUMENT_PAGES p
  ON p.FILE_PATH = l.FILE_PATH
 AND l.CLAIM_KEY IS NOT NULL
 AND CONTAINS(p.PAGE_CONTENT, l.CLAIM_KEY)
GROUP BY l.FILE_PATH, l.LINE_NUMBER;
