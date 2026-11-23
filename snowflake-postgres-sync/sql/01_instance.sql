-- 01_instance.sql
-- Run in Snowsight as ACCOUNTADMIN, one statement at a time.
-- Skip this file if you already have a Snowflake Postgres instance (STANDARD or HIGH MEMORY).

-- 1. Who can connect. Replace with your app servers' and your own public IPs.
CREATE DATABASE IF NOT EXISTS PG_ADMIN;
CREATE SCHEMA IF NOT EXISTS PG_ADMIN.NETWORK;

CREATE OR REPLACE NETWORK RULE PG_ADMIN.NETWORK.PG_INGRESS_RULE
  TYPE = IPV4
  VALUE_LIST = ('<your.ip.address>/32')
  MODE = POSTGRES_INGRESS;

CREATE OR REPLACE NETWORK POLICY PG_INGRESS_POLICY
  ALLOWED_NETWORK_RULE_LIST = ('PG_ADMIN.NETWORK.PG_INGRESS_RULE');

-- 2. The instance. Mirroring and pg_lake need STANDARD or HIGH MEMORY (not BURSTABLE).
--    The output includes the snowflake_admin and application passwords. They can't be
--    retrieved later: save them in your password manager before you close the result.
CREATE POSTGRES INSTANCE <PG_INSTANCE>
  COMPUTE_FAMILY = 'STANDARD_M'
  STORAGE_SIZE_GB = 100
  AUTHENTICATION_AUTHORITY = POSTGRES
  NETWORK_POLICY = 'PG_INGRESS_POLICY'
  COMMENT = 'App serving database + mirror source';

-- 3. Wait for state = READY (a few minutes). The host goes in your app's connection string.
DESCRIBE POSTGRES INSTANCE <PG_INSTANCE>
  ->> SELECT "property", "value" FROM $1 WHERE "property" IN ('state', 'host');

-- Then connect and run 00_postgres_setup.sql:
--   psql "host=<PG_HOST> port=5432 dbname=postgres user=snowflake_admin sslmode=require"
