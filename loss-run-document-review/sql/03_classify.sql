-- 03_classify.sql
-- Classify every page, because one PDF can be several documents merged together.
-- Document type = the most common page label.

USE SCHEMA LOSS_RUN_DEMO.PIPELINE;

CREATE OR REPLACE TABLE PAGE_CLASSIFICATIONS AS
SELECT
    FILE_PATH,
    PAGE_INDEX,
    AI_CLASSIFY(
        LEFT(PAGE_CONTENT, 6000),
        [
          {'label': 'loss run', 'description': 'carrier loss history: claims listed with dates, paid, reserved, incurred amounts'},
          {'label': 'acord application', 'description': 'ACORD insurance application or submission form'},
          {'label': 'safety or dot report', 'description': 'CAB, FMCSA, DOT, or safety rating report'},
          {'label': 'cover letter or email', 'description': 'correspondence, cover letter, or email text'},
          {'label': 'other', 'description': 'anything else'}
        ]
    ):labels[0]::VARCHAR AS PAGE_TYPE
FROM DOCUMENT_PAGES;

CREATE OR REPLACE VIEW DOCUMENT_TYPES AS
SELECT FILE_PATH, PAGE_TYPE AS DOCUMENT_TYPE,
       COUNT(*) AS PAGES_WITH_TYPE
FROM PAGE_CLASSIFICATIONS
GROUP BY FILE_PATH, PAGE_TYPE
QUALIFY ROW_NUMBER() OVER (PARTITION BY FILE_PATH ORDER BY COUNT(*) DESC) = 1;
