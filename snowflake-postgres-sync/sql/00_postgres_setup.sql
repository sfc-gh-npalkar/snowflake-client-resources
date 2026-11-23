-- 00_postgres_setup.sql
-- Run in your Snowflake Postgres database (psql, or any Postgres client), as snowflake_admin.
-- Creates the schema your app reads from, one example serving table, and a least-privilege
-- login that Snowflake uses to push changes in (03_sync_snowflake_to_postgres.sql).

-- Lets apps connect through the built-in PgBouncer pooler on port 5431 (non-superuser roles only).
CREATE EXTENSION IF NOT EXISTS snowflake_pooler;

CREATE SCHEMA IF NOT EXISTS serving;
GRANT USAGE ON SCHEMA serving TO application;
GRANT SELECT ON ALL TABLES IN SCHEMA serving TO application;
ALTER DEFAULT PRIVILEGES IN SCHEMA serving GRANT SELECT ON TABLES TO application;

-- One table per Snowflake table you sync. Column names must match the Snowflake columns
-- (case-insensitive). The primary key must match KEY_COLUMNS in SYNC_TABLES (step 03).
CREATE TABLE IF NOT EXISTS serving.site_daily_kpis (
  site_id      text    NOT NULL,
  kpi_date     date    NOT NULL,
  washes       integer,
  members      integer,
  revenue      numeric(12,2),
  updated_at   timestamptz,
  PRIMARY KEY (site_id, kpi_date)
);

-- The login Snowflake uses. It can write to the serving schema and nothing else.
CREATE ROLE sync_writer LOGIN PASSWORD '<choose-a-strong-password>';
GRANT USAGE ON SCHEMA serving TO sync_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA serving TO sync_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA serving GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO sync_writer;

-- Where your app writes (logs, events, operational rows). Everything in this schema is
-- mirrored to Snowflake automatically, including tables you create later (step 02).
CREATE SCHEMA IF NOT EXISTS app;

CREATE TABLE IF NOT EXISTS app.request_log (
  request_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- a PK is required for UPDATE/DELETE to mirror
  endpoint     text NOT NULL,
  site_id      text,
  latency_ms   integer,
  created_at   timestamptz NOT NULL DEFAULT now()
);
