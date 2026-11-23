-- 02_mirror_postgres_to_snowflake.sql
-- Run in Snowsight as ACCOUNTADMIN. Continuously copies the Postgres "app" schema into Snowflake.
-- Schema-level: tables you create in "app" later are picked up automatically, snapshot included.

GRANT APPLICATION ROLE SNOWFLAKE.POSTGRES_MIRROR_ADMIN TO ROLE ACCOUNTADMIN;
GRANT USAGE ON POSTGRES INSTANCE <PG_INSTANCE> TO APPLICATION SNOWFLAKE;

CALL SNOWFLAKE.POSTGRES.CREATE_MIRROR(
  mirror_name       => 'app_mirror',
  postgres_instance => '<PG_INSTANCE>',
  postgres_database => 'postgres',
  target_database   => 'APP_MIRROR',          -- must not already exist; the mirror creates it
  postgres_tables   => NULL,
  postgres_schemas  => ['app'],
  refresh_interval  => '1 minute'
);

-- SNAPSHOTTING during the first copy, then REPLICATING.
-- The name is case-sensitive here: lowercase returns no rows and no error.
CALL SNOWFLAKE.POSTGRES.LIST_MIRRORED_TABLES('APP_MIRROR');

-- Prove it: insert in Postgres, read it here.
--   Postgres:  INSERT INTO app.request_log (endpoint, site_id, latency_ms) VALUES ('/orders', 'S001', 12);
SELECT COUNT(*) FROM APP_MIRROR.APP.REQUEST_LOG;        -- merged on the refresh interval
SELECT COUNT(*) FROM APP_MIRROR.APP.REQUEST_LOG$live;   -- includes unmerged changes, ~30s behind

-- Prove new tables need no reconfiguration:
--   Postgres:  CREATE TABLE app.order_events (id bigint PRIMARY KEY, status text, created_at timestamptz DEFAULT now());
--              INSERT INTO app.order_events VALUES (1, 'created');
CALL SNOWFLAKE.POSTGRES.LIST_MIRRORED_TABLES('APP_MIRROR');   -- order_events appears, REPLICATING
SELECT * FROM APP_MIRROR.APP.ORDER_EVENTS$live;

-- What it costs: the apply task is serverless and named APPLY_MIRROR_<mirror_name>.
SELECT start_time, credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
WHERE task_name ILIKE 'APPLY_MIRROR_APP_MIRROR%'
ORDER BY start_time DESC;
