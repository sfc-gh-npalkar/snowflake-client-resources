-- 01_setup.sql — Snowflake side, run once as ACCOUNTADMIN in a Snowsight worksheet.
-- Replace every <PLACEHOLDER> first (see README). Run one statement at a time.

CREATE DATABASE IF NOT EXISTS VOICE_CAPTURE;
CREATE SCHEMA IF NOT EXISTS VOICE_CAPTURE.PIPELINE;
USE SCHEMA VOICE_CAPTURE.PIPELINE;

-- 1. Where the CRM app drops audio. Filename convention: <ASSOCIATE_ID>_<anything>.<ext>
CREATE STAGE IF NOT EXISTS VOICE_STAGE
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  DIRECTORY = (ENABLE = TRUE);

-- 2. Mirror your existing CRM tables into Snowflake (read-only copy, ~30s behind).
--    The review step compares voice-note values against these.
GRANT APPLICATION ROLE SNOWFLAKE.POSTGRES_MIRROR_ADMIN TO ROLE ACCOUNTADMIN;
GRANT USAGE ON POSTGRES INSTANCE <PG_INSTANCE> TO APPLICATION SNOWFLAKE;

CALL SNOWFLAKE.POSTGRES.CREATE_MIRROR(
  mirror_name       => 'voice_crm_mirror',
  postgres_instance => '<PG_INSTANCE>',
  postgres_database => '<PG_DATABASE>',
  target_database   => 'VOICE_CAPTURE_CRM',          -- must not already exist
  postgres_tables   => ['public.prospects', 'public.voice_note_submissions'],
  postgres_schemas  => NULL,
  refresh_interval  => '30 seconds',
  warehouse         => NULL
);
-- Wait until both tables show REPLICATING:
CALL SNOWFLAKE.POSTGRES.LIST_MIRRORED_TABLES('voice_crm_mirror');

-- 3. Outbound path from Snowflake to Postgres for the write-back.
CREATE OR REPLACE NETWORK RULE PG_EGRESS_RULE
  MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('<PG_HOST>:5432');

-- The voice_writer password from 00_postgres_inbox.sql. Paste it here, run, then clear the worksheet.
CREATE OR REPLACE SECRET PG_WRITER_SECRET
  TYPE = PASSWORD USERNAME = 'voice_writer' PASSWORD = '<voice_writer password>';

-- The instance's CA certificate, so the connection verifies the server (not a credential).
EXECUTE IMMEDIATE $$
DECLARE cert STRING;
BEGIN
  DESCRIBE POSTGRES INSTANCE <PG_INSTANCE>;
  SELECT "value" INTO :cert FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "property" = 'certificate';
  EXECUTE IMMEDIATE 'CREATE OR REPLACE SECRET VOICE_CAPTURE.PIPELINE.PG_CA_CERT TYPE = GENERIC_STRING SECRET_STRING = '''
                    || REPLACE(:cert, '''', '''''') || '''';
  RETURN 'PG_CA_CERT created';
END;
$$;

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION VOICE_PG_EAI
  ALLOWED_NETWORK_RULES = (VOICE_CAPTURE.PIPELINE.PG_EGRESS_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (VOICE_CAPTURE.PIPELINE.PG_WRITER_SECRET, VOICE_CAPTURE.PIPELINE.PG_CA_CERT)
  ENABLED = TRUE;

-- 4. Your Postgres network policy must allow Snowflake's outbound IPs on 5432 (AWS Commercial / Azure).
--    Add these ranges to the POSTGRES_INGRESS network rule attached to <PG_INSTANCE>.
--    They expire: refresh them on a schedule (docs: "Securing ingress of Snowflake requests with egress IP addresses").
SELECT value:"ipv4_prefix"::VARCHAR AS cidr, value:"expires"::TIMESTAMP AS expires
FROM TABLE(FLATTEN(INPUT => PARSE_JSON(SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES())));

-- 5. Prove Snowflake can reach the CRM. Expect: connected (CA verified); submissions=0
CREATE OR REPLACE PROCEDURE PG_PING()
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pg8000')
EXTERNAL_ACCESS_INTEGRATIONS = (VOICE_PG_EAI)
SECRETS = ('pg' = VOICE_CAPTURE.PIPELINE.PG_WRITER_SECRET, 'ca' = VOICE_CAPTURE.PIPELINE.PG_CA_CERT)
HANDLER = 'run'
AS
$$
import _snowflake, ssl, pg8000.native
def run(session):
    c = _snowflake.get_username_password('pg')
    ctx = ssl.create_default_context(cadata=_snowflake.get_generic_secret_string('ca'))
    ctx.check_hostname = False   # same as libpq sslmode=verify-ca
    con = pg8000.native.Connection(user=c.username, password=c.password, database='<PG_DATABASE>',
                                   host='<PG_HOST>', port=5432, ssl_context=ctx, timeout=15)
    n = con.run('select count(*) from voice_note_submissions')[0][0]
    con.close()
    return f'connected (CA verified); submissions={n}'
$$;

CALL PG_PING();
