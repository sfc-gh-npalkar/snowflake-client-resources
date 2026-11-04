-- 07_agent.sql
-- Cortex Agent over the loss-run semantic view.
-- Created in SNOWFLAKE_INTELLIGENCE.AGENTS with a color so it appears in Snowflake Cowork.

USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE;
CREATE SCHEMA IF NOT EXISTS SNOWFLAKE_INTELLIGENCE.AGENTS;

CREATE OR REPLACE AGENT SNOWFLAKE_INTELLIGENCE.AGENTS.LOSS_RUN_ANALYST
  COMMENT = 'Answers underwriter questions about extracted loss runs'
  PROFILE = '{"display_name": "Loss Run Analyst", "color": "blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  instructions:
    response: >
      You help underwriters review loss runs. Always cite the source document file name and
      the page number for any claim you mention, for example "(carrier_loss_run.pdf, page 2)".
      Say whether the document is still NEEDS_REVIEW, because unreviewed numbers may change.
      Use amounts exactly as returned; do not estimate.
    orchestration: >
      Use the loss_runs tool for every question about insureds, carriers, claims, paid,
      reserve, incurred, or review status.
  tools:
    - tool_spec:
        type: cortex_analyst_text_to_sql
        name: loss_runs
        description: Extracted loss-run headers and claim lines, with human corrections applied.
  tool_resources:
    loss_runs:
      semantic_view: LOSS_RUN_DEMO.PIPELINE.LOSS_RUN_SV
      execution_environment:
        type: warehouse
        warehouse: LOSS_RUN_WH
  $$;

SHOW AGENTS IN SCHEMA SNOWFLAKE_INTELLIGENCE.AGENTS;
