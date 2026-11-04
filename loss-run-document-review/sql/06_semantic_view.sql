-- 06_semantic_view.sql
-- Semantic view over corrected claim lines and document headers, for Cortex Analyst.

USE SCHEMA LOSS_RUN_DEMO.PIPELINE;

CREATE OR REPLACE SEMANTIC VIEW LOSS_RUN_SV
  TABLES (
    docs AS LOSS_RUN_DEMO.PIPELINE.DOCUMENT_GATE
      PRIMARY KEY (FILE_PATH)
      COMMENT = 'One row per loss-run document with header fields and review status',
    claims AS LOSS_RUN_DEMO.PIPELINE.LOSS_RUN_LINES_CURRENT
      PRIMARY KEY (FILE_PATH, LINE_NUMBER)
      COMMENT = 'One row per claim and coverage line, with human corrections applied'
  )
  RELATIONSHIPS (
    claims_to_docs AS claims (FILE_PATH) REFERENCES docs
  )
  FACTS (
    claims.paid_amount     AS PAID     COMMENT = 'Loss paid',
    claims.reserve_amount  AS RESERVE  COMMENT = 'Outstanding loss reserve',
    claims.expense_amount  AS EXPENSE  COMMENT = 'Expense paid',
    claims.incurred_amount AS INCURRED_CALC COMMENT = 'Paid + reserve + expense'
  )
  DIMENSIONS (
    docs.file_path      AS FILE_PATH      COMMENT = 'Source document file name',
    docs.insured_name   AS INSURED_NAME   WITH SYNONYMS = ('insured', 'account') COMMENT = 'Named insured',
    docs.carrier_name   AS CARRIER_NAME   WITH SYNONYMS = ('carrier', 'insurer') COMMENT = 'Carrier that issued the loss run',
    docs.policy_number  AS POLICY_NUMBER  COMMENT = 'Policy number',
    docs.review_status  AS STATUS         COMMENT = 'NEEDS_REVIEW, APPROVED, AUTO_APPROVED, or REJECTED',
    claims.claim_number AS CLAIM_NUMBER   COMMENT = 'Claim or loss file number',
    claims.claim_status AS STATUS_GROUP WITH SYNONYMS = ('open or closed') COMMENT = 'Open, Closed, Report Only, or Other',
    claims.carrier_status AS STATUS COMMENT = 'Status text exactly as printed by the carrier',
    claims.coverage     AS COVERAGE       COMMENT = 'Coverage or line of business',
    claims.description  AS DESCRIPTION    COMMENT = 'Loss description',
    claims.loss_date    AS LOSS_DATE      COMMENT = 'Date of loss',
    claims.page_number  AS PAGE_INDEX + 1 COMMENT = 'Page in the source PDF where the claim appears (1-based)'
  )
  METRICS (
    claims.total_paid     AS SUM(claims.paid_amount)     COMMENT = 'Total loss paid',
    claims.total_reserve  AS SUM(claims.reserve_amount)  COMMENT = 'Total outstanding reserve',
    claims.total_incurred AS SUM(claims.incurred_amount) COMMENT = 'Total incurred (paid + reserve + expense)',
    claims.claim_count    AS COUNT(DISTINCT claims.CLAIM_KEY) COMMENT = 'Number of distinct claims'
  )
  COMMENT = 'Loss runs extracted with Cortex AI, with human corrections applied';
