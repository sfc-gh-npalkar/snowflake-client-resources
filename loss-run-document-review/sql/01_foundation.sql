-- 01_foundation.sql
-- Database, schema, warehouse, and an internal stage for loss-run documents.
-- Server-side encryption is required for Cortex AI document functions.

CREATE DATABASE IF NOT EXISTS LOSS_RUN_DEMO;
CREATE SCHEMA IF NOT EXISTS LOSS_RUN_DEMO.PIPELINE;

CREATE WAREHOUSE IF NOT EXISTS LOSS_RUN_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

CREATE STAGE IF NOT EXISTS LOSS_RUN_DEMO.PIPELINE.DOCS
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- Upload documents, then refresh the directory table:
--   PUT file:///path/to/docs/*.pdf @LOSS_RUN_DEMO.PIPELINE.DOCS AUTO_COMPRESS=FALSE;
--   ALTER STAGE LOSS_RUN_DEMO.PIPELINE.DOCS REFRESH;
