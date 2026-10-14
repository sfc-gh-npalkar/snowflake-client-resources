-- Step 5: decide, then write reviewed notes back to the CRM in Snowflake Postgres. Run one statement at a time.
-- Every reviewed note lands in voice_note_submissions (idempotent on file_path).
-- PROMOTE => TRUE also applies approved fields to prospects in the same Postgres transaction.
-- PROMOTE => FALSE leaves promotion to your CRM app (recommended if your app owns business rules / audit).

CREATE OR REPLACE PROCEDURE VOICE_CAPTURE.PIPELINE.WRITE_BACK(PROMOTE BOOLEAN)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pg8000')
EXTERNAL_ACCESS_INTEGRATIONS = (VOICE_PG_EAI)
SECRETS = ('pg' = VOICE_CAPTURE.PIPELINE.PG_WRITER_SECRET, 'ca' = VOICE_CAPTURE.PIPELINE.PG_CA_CERT)
HANDLER = 'run'
AS
$$
import ssl, _snowflake, pg8000.native

PG_HOST, PG_DB = '<PG_HOST>', '<PG_DATABASE>'
# ADAPT: queue field name -> your prospects column. Only these can ever be written.
COLS = {'phone':'phone', 'email':'email', 'interest_category':'interest_category', 'budget_band':'budget_band',
        'move_in_date':'move_in_date', 'next_step':'next_step', 'next_followup_date':'next_followup_date'}
DATE_COLS = {'move_in_date', 'next_followup_date'}

def run(session, promote):
    rows = session.sql("""
        SELECT q.file_path, q.prospect_id, q.field, q.new_value, q.decision, q.decided_by, q.needs_review,
               r.associate_id, r.transcript, TO_JSON(e.extracted) AS extracted
        FROM VOICE_CAPTURE.PIPELINE.PENDING_UPDATES q
        JOIN VOICE_CAPTURE.PIPELINE.VOICE_NOTES_RAW r USING (file_path)
        JOIN VOICE_CAPTURE.PIPELINE.VOICE_NOTE_EXTRACT e USING (file_path)
        WHERE q.decision IN ('APPROVED','REJECTED') AND q.written_back_at IS NULL
        ORDER BY q.file_path""").collect()
    if not rows:
        return 'nothing to write back'

    c = _snowflake.get_username_password('pg')
    ctx = ssl.create_default_context(cadata=_snowflake.get_generic_secret_string('ca'))
    ctx.check_hostname = False   # same as libpq sslmode=verify-ca
    con = pg8000.native.Connection(user=c.username, password=c.password, database=PG_DB,
                                   host=PG_HOST, port=5432, ssl_context=ctx, timeout=30)
    notes, applied = {}, 0
    try:
        con.run('BEGIN')
        for r in rows:
            notes.setdefault(r['FILE_PATH'], {'row': r, 'approved': []})
            if r['DECISION'] == 'APPROVED':
                notes[r['FILE_PATH']]['approved'].append(r)
        for fp, n in notes.items():
            r = n['row']
            if promote and r['PROSPECT_ID'] is not None:
                for a in n['approved']:
                    if a['FIELD'] not in COLS:
                        continue
                    col = COLS[a['FIELD']]
                    cast = '::date' if col in DATE_COLS else ''
                    con.run(f"update prospects set {col} = :v{cast} where prospect_id = :p",
                            v=a['NEW_VALUE'], p=r['PROSPECT_ID'])
                    applied += 1
            if not n['approved']:
                status = 'REJECTED'
            elif promote and r['PROSPECT_ID'] is not None:
                status = 'PROMOTED'
            else:
                status = 'APPROVED'          # your CRM app promotes it (and handles new prospects)
            reasons = sorted({x['FIELD'] for x in rows if x['FILE_PATH'] == fp and x['NEEDS_REVIEW']})
            con.run("""insert into voice_note_submissions
                         (file_path, prospect_id, associate_id, transcript, extracted, status, reasons,
                          reviewed_by, reviewed_at, promoted_at)
                       values (:f, :p, :a, :t, cast(:x as jsonb), :s, cast(:rs as jsonb), :rb, now(),
                               case when :s = 'PROMOTED' then now() end)
                       on conflict (file_path) do update set
                         prospect_id = excluded.prospect_id, extracted = excluded.extracted, status = excluded.status,
                         reasons = excluded.reasons, reviewed_by = excluded.reviewed_by, reviewed_at = now(),
                         promoted_at = excluded.promoted_at""",
                    f=fp, p=r['PROSPECT_ID'], a=r['ASSOCIATE_ID'], t=r['TRANSCRIPT'], x=r['EXTRACTED'],
                    s=status, rs=str(reasons).replace("'", '"'), rb=r['DECIDED_BY'])
        con.run('COMMIT')
    except Exception:
        con.run('ROLLBACK')
        raise
    finally:
        con.close()

    session.sql("""UPDATE VOICE_CAPTURE.PIPELINE.PENDING_UPDATES SET written_back_at = CURRENT_TIMESTAMP()
                   WHERE decision IN ('APPROVED','REJECTED') AND written_back_at IS NULL
                     AND file_path IN (SELECT value::STRING FROM TABLE(FLATTEN(INPUT => PARSE_JSON(?))))""",
                params=[str(list(notes)).replace("'", '"')]).collect()
    return f'wrote {len(notes)} notes to the inbox; promoted {applied} fields'
$$;

-- Approve or reject (this is what the review UI does). Example: approve every change for one note.
UPDATE VOICE_CAPTURE.PIPELINE.PENDING_UPDATES
   SET decision = 'APPROVED', decided_by = CURRENT_USER(), decided_at = CURRENT_TIMESTAMP()
 WHERE file_path = '<file_path>' AND decision = 'PENDING';

CALL VOICE_CAPTURE.PIPELINE.WRITE_BACK(FALSE);    -- inbox only
-- CALL VOICE_CAPTURE.PIPELINE.WRITE_BACK(TRUE);  -- inbox + promote approved fields

-- Read it back through the mirror (~30s):
-- SELECT file_path, status, reasons, reviewed_by FROM VOICE_CAPTURE_CRM.PUBLIC.VOICE_NOTE_SUBMISSIONS;

-- Optional: run the write-back automatically every 5 minutes.
-- CREATE TASK VOICE_CAPTURE.PIPELINE.WRITE_BACK_TASK SCHEDULE = '5 MINUTE' AS CALL VOICE_CAPTURE.PIPELINE.WRITE_BACK(FALSE);
-- ALTER TASK VOICE_CAPTURE.PIPELINE.WRITE_BACK_TASK RESUME;
