-- 03_sync_snowflake_to_postgres.sql
-- Run in Snowsight as ACCOUNTADMIN, one statement at a time.
-- Pushes only what changed in Snowflake tables into Postgres serving tables.
-- A stream tracks the changes, so there are no diff queries, and nothing runs when nothing changed.

CREATE DATABASE IF NOT EXISTS PG_SYNC;
CREATE SCHEMA IF NOT EXISTS PG_SYNC.PIPELINE;
USE SCHEMA PG_SYNC.PIPELINE;

-- 1. Network path from Snowflake to Postgres on 5432.
CREATE OR REPLACE NETWORK RULE PG_EGRESS_RULE
  MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('<PG_HOST>:5432');

-- The sync_writer password from 00_postgres_setup.sql. Paste it, run, then clear it from the worksheet.
CREATE OR REPLACE SECRET PG_WRITER_SECRET
  TYPE = PASSWORD USERNAME = 'sync_writer' PASSWORD = '<sync_writer password>';

-- The instance's CA certificate, so the connection verifies the server (it isn't a credential).
EXECUTE IMMEDIATE $$
DECLARE cert STRING;
BEGIN
  DESCRIBE POSTGRES INSTANCE <PG_INSTANCE>;
  SELECT "value" INTO :cert FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "property" = 'certificate';
  EXECUTE IMMEDIATE 'CREATE OR REPLACE SECRET PG_SYNC.PIPELINE.PG_CA_CERT TYPE = GENERIC_STRING SECRET_STRING = '''
                    || REPLACE(:cert, '''', '''''') || '''';
  RETURN 'PG_CA_CERT created';
END;
$$;

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION PG_SYNC_EAI
  ALLOWED_NETWORK_RULES = (PG_SYNC.PIPELINE.PG_EGRESS_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (PG_SYNC.PIPELINE.PG_WRITER_SECRET, PG_SYNC.PIPELINE.PG_CA_CERT)
  ENABLED = TRUE;

-- 2. Snowflake's outbound IPs must be allowed into Postgres. Add these CIDRs to the
--    PG_INGRESS_RULE from 01_instance.sql. They expire, so refresh them on a schedule.
SELECT value:"ipv4_prefix"::VARCHAR AS cidr, value:"expires"::TIMESTAMP AS expires
FROM TABLE(FLATTEN(INPUT => PARSE_JSON(SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES())));

-- 3. Example source table. Replace with your own marts; skip this if you have them.
CREATE OR REPLACE TABLE PG_SYNC.PIPELINE.SITE_DAILY_KPIS AS
SELECT 'S' || LPAD(MOD(SEQ4(), 50)::STRING, 3, '0')           AS site_id,
       DATEADD(day, -FLOOR(SEQ4() / 50), CURRENT_DATE())      AS kpi_date,
       UNIFORM(100, 900, RANDOM(1))                           AS orders,
       UNIFORM(500, 3000, RANDOM(2))                          AS customers,
       UNIFORM(1000, 20000, RANDOM(3))::NUMBER(12,2)          AS revenue,
       CURRENT_TIMESTAMP()                                    AS updated_at
FROM TABLE(GENERATOR(ROWCOUNT => 5000));

-- 4. What to sync. One row per table. KEY_COLUMNS must match the Postgres primary key.
CREATE OR REPLACE TABLE SYNC_TABLES (
  stream_name  STRING,        -- stream on the Snowflake source table
  pg_table     STRING,        -- schema.table in Postgres
  key_columns  ARRAY
);

-- SHOW_INITIAL_ROWS = TRUE: the first run loads the whole table, later runs only the changes.
CREATE OR REPLACE STREAM SITE_DAILY_KPIS_STREAM
  ON TABLE PG_SYNC.PIPELINE.SITE_DAILY_KPIS SHOW_INITIAL_ROWS = TRUE;

INSERT INTO SYNC_TABLES
  SELECT 'PG_SYNC.PIPELINE.SITE_DAILY_KPIS_STREAM', 'serving.site_daily_kpis', ['site_id', 'kpi_date'];

-- Changes are copied here from the stream (which moves the stream forward), and deleted only after
-- Postgres commits them. If a push fails, the rows stay here and are retried on the next run.
CREATE OR REPLACE TABLE SYNC_BATCH (
  pg_table     STRING,
  captured_at  TIMESTAMP_LTZ,
  action       STRING,        -- INSERT or DELETE
  is_update    BOOLEAN,       -- an update shows up as a DELETE + INSERT pair with is_update = TRUE
  row_data     VARIANT
);

-- 5. The sync procedure. Generic: it reads column names from Postgres, so adding a table is one
--    SYNC_TABLES row plus a stream, not new code.
CREATE OR REPLACE PROCEDURE SYNC_TO_POSTGRES()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pg8000')
EXTERNAL_ACCESS_INTEGRATIONS = (PG_SYNC_EAI)
SECRETS = ('pg' = PG_SYNC.PIPELINE.PG_WRITER_SECRET, 'ca' = PG_SYNC.PIPELINE.PG_CA_CERT)
HANDLER = 'run'
AS
$$
import json, ssl, _snowflake, pg8000.native

PG_HOST, PG_DB = '<PG_HOST>', 'postgres'
CHUNK = 5000

def q(ident):
    return '"' + ident.replace('"', '""') + '"'

def run(session):
    cfg = session.sql("SELECT stream_name, pg_table, key_columns FROM PG_SYNC.PIPELINE.SYNC_TABLES").collect()

    # Capture: copying from the stream in a committed INSERT moves the stream forward.
    for c in cfg:
        session.sql(f"""
            INSERT INTO PG_SYNC.PIPELINE.SYNC_BATCH
            SELECT ?, CURRENT_TIMESTAMP(), METADATA$ACTION, METADATA$ISUPDATE, OBJECT_CONSTRUCT_KEEP_NULL(*)
            FROM {c['STREAM_NAME']}""", params=[c['PG_TABLE']]).collect()

    cred = _snowflake.get_username_password('pg')
    ctx = ssl.create_default_context(cadata=_snowflake.get_generic_secret_string('ca'))
    ctx.check_hostname = False   # same as libpq sslmode=verify-ca
    con = pg8000.native.Connection(user=cred.username, password=cred.password, database=PG_DB,
                                   host=PG_HOST, port=5432, ssl_context=ctx, timeout=60)
    summary = []
    try:
        for c in cfg:
            schema, table = c['PG_TABLE'].split('.')
            keys = [k.lower() for k in json.loads(c['KEY_COLUMNS'])]
            cols = [r[0] for r in con.run(
                "select column_name from information_schema.columns "
                "where table_schema = :s and table_name = :t order by ordinal_position", s=schema, t=table)]
            if not cols:
                raise Exception(f'{c["PG_TABLE"]} not found in Postgres')
            fq = f'{q(schema)}.{q(table)}'
            col_list = ', '.join(q(x) for x in cols)
            key_list = ', '.join(q(k) for k in keys)
            set_list = ', '.join(f'{q(x)} = excluded.{q(x)}' for x in cols if x not in keys) or f'{q(keys[0])} = excluded.{q(keys[0])}'
            key_match = ' and '.join(f'd.{q(k)} = r.{q(k)}' for k in keys)

            # Oldest capture first, deletes before inserts within a capture (an update is delete + insert).
            groups = session.sql("""
                SELECT captured_at, action, TO_JSON(ARRAY_AGG(row_data)) AS rows_json
                FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY captured_at, action ORDER BY 1) AS rn
                      FROM PG_SYNC.PIPELINE.SYNC_BATCH
                      WHERE pg_table = ? AND (action = 'INSERT' OR NOT is_update))
                GROUP BY captured_at, action, FLOOR(rn / ?)
                ORDER BY captured_at, action""", params=[c['PG_TABLE'], CHUNK]).collect()
            if not groups:
                summary.append(f'{c["PG_TABLE"]}: no changes')
                continue

            upserts = deletes = 0
            con.run('BEGIN')
            for g in groups:
                rows = [{k.lower(): v for k, v in r.items()} for r in json.loads(g['ROWS_JSON'])]
                payload = json.dumps(rows)
                if g['ACTION'] == 'DELETE':
                    con.run(f"delete from {fq} d using jsonb_populate_recordset(null::{fq}, cast(:j as jsonb)) r "
                            f"where {key_match}", j=payload)
                    deletes += len(rows)
                else:
                    con.run(f"insert into {fq} ({col_list}) "
                            f"select {col_list} from jsonb_populate_recordset(null::{fq}, cast(:j as jsonb)) "
                            f"on conflict ({key_list}) do update set {set_list}", j=payload)
                    upserts += len(rows)
            con.run('COMMIT')

            last = max(g['CAPTURED_AT'] for g in groups)
            session.sql("DELETE FROM PG_SYNC.PIPELINE.SYNC_BATCH WHERE pg_table = ? AND captured_at <= ?",
                        params=[c['PG_TABLE'], last]).collect()
            summary.append(f'{c["PG_TABLE"]}: {upserts} upserted, {deletes} deleted')
    except Exception:
        try:
            con.run('ROLLBACK')
        except Exception:
            pass
        raise
    finally:
        con.close()
    return '; '.join(summary)
$$;

-- 6. First run: loads the full table (SHOW_INITIAL_ROWS). Then change something and run again.
CALL SYNC_TO_POSTGRES();       -- expect: serving.site_daily_kpis: 5000 upserted, 0 deleted

UPDATE PG_SYNC.PIPELINE.SITE_DAILY_KPIS SET orders = orders + 1 WHERE site_id = 'S001';
DELETE FROM PG_SYNC.PIPELINE.SITE_DAILY_KPIS WHERE site_id = 'S002' AND kpi_date = CURRENT_DATE();
CALL SYNC_TO_POSTGRES();       -- expect: 100 upserted, 1 deleted (only the changed rows move)
CALL SYNC_TO_POSTGRES();       -- expect: no changes

-- 7. Schedule it. Serverless, and skipped entirely when no stream has data.
--    List every stream you add to SYNC_TABLES in the WHEN clause.
CREATE OR REPLACE TASK SYNC_TO_POSTGRES_TASK
  SCHEDULE = '15 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('PG_SYNC.PIPELINE.SITE_DAILY_KPIS_STREAM')
AS CALL PG_SYNC.PIPELINE.SYNC_TO_POSTGRES();
ALTER TASK SYNC_TO_POSTGRES_TASK RESUME;

-- What it costs: serverless task credits for this task only.
SELECT start_time, credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
WHERE task_name = 'SYNC_TO_POSTGRES_TASK'
ORDER BY start_time DESC;
