# Voice Notes to CRM on Snowflake Postgres

Sales associates dictate a note after a customer visit. Snowflake transcribes it, pulls out the CRM
fields, shows a reviewer what would change, and writes the approved changes back to a CRM that runs on
**Snowflake Postgres**. Nothing leaves Snowflake, and nothing reaches the CRM without review.

```
CRM app / phone ── audio ──► stage ──► AI_TRANSCRIBE ──► AI_COMPLETE (JSON schema) ──► review queue
                                                                                           │ approve
your CRM (Snowflake Postgres) ◄── Snowpark proc: voice_note_submissions inbox ◄────────────┘
          │
          └── managed mirror ──► Snowflake (the review step compares new values against it)
```

## What you already have, and what this adds

You already run your CRM on a Snowflake Postgres instance. This guide doesn't create an instance or
touch your existing tables. It adds:

| In Postgres | In Snowflake |
|---|---|
| One table, `voice_note_submissions` (the inbox) | A stage for audio, two tasks (transcribe, extract), a review queue |
| One login role, `voice_writer` (least privilege) | A mirror of your prospects table and the inbox, refreshed every 30 seconds |
| | A procedure that writes reviewed notes to the inbox |

## Files

| File | Run where | What it does |
|---|---|---|
| [`sql/00_postgres_inbox.sql`](sql/00_postgres_inbox.sql) | Your CRM's Postgres database | Inbox table and `voice_writer` role |
| [`sql/01_setup.sql`](sql/01_setup.sql) | Snowsight, as ACCOUNTADMIN | Stage, mirror, secrets, network access, connectivity check |
| [`sql/02_transcribe.sql`](sql/02_transcribe.sql) | Snowsight | Audio to text, triggered automatically when a file lands |
| [`sql/03_extract.sql`](sql/03_extract.sql) | Snowsight | Text to CRM fields, triggered automatically |
| [`sql/04_review.sql`](sql/04_review.sql) | Snowsight | Match note to prospect, compare to CRM, flag conflicts |
| [`sql/05_writeback.sql`](sql/05_writeback.sql) | Snowsight | Write reviewed notes to the CRM inbox (optionally promote) |
| [`streamlit/streamlit_app.py`](streamlit/streamlit_app.py) | Streamlit in Snowflake | Upload or record, then review and approve |

## Before you start

- **Region.** `AI_TRANSCRIBE` runs in AWS US West 2, AWS US East 1, AWS EU Central 1 and Azure East US 2
  ([docs](https://docs.snowflake.com/en/sql-reference/functions/ai_transcribe)). Snowflake Postgres
  mirroring is AWS and Azure only.
- **Roles.** ACCOUNTADMIN for `01_setup.sql`; any role with `SNOWFLAKE.CORTEX_USER` for steps 02–05.
- **Python packages.** The Anaconda terms must be accepted (Snowsight » Admin » Terms).
- **Your Postgres instance tier** is STANDARD or HIGH MEMORY (mirroring doesn't support BURSTABLE).

Replace these placeholders in every file:

| Placeholder | Where to find it |
|---|---|
| `<PG_INSTANCE>` | `SHOW POSTGRES INSTANCES;` → `name` |
| `<PG_HOST>` | `SHOW POSTGRES INSTANCES;` → `host` |
| `<PG_DATABASE>` | The Postgres database your CRM tables live in |

This should print nothing when you're done:
```bash
grep -rn "<PG_" sql/ streamlit/
```

## Setup

**1. Postgres: add the inbox.** Run `sql/00_postgres_inbox.sql` wherever you run CRM DDL today. Choose
the `voice_writer` password there.

**2. Snowflake: connect to the CRM.** Run `sql/01_setup.sql` one statement at a time. Paste the
`voice_writer` password into the `CREATE SECRET`, run it, then clear it from the worksheet. Add the
two Snowflake egress ranges that step 4 prints to your Postgres instance's network rule.

You should see `connected (CA verified); submissions=0` from `CALL PG_PING();`

**3. Transcription.** Run `sql/02_transcribe.sql`. Then upload a test memo named `<your associate id>_test.m4a`:
```sql
-- after uploading via Snowsight (Catalog » VOICE_CAPTURE » PIPELINE » Stages » VOICE_STAGE » + Files)
ALTER STAGE VOICE_CAPTURE.PIPELINE.VOICE_STAGE REFRESH;
SELECT associate_id, audio_seconds, transcript FROM VOICE_CAPTURE.PIPELINE.VOICE_NOTES_RAW;
```
You should see your words within about a minute. Internal stages don't refresh themselves; the
Streamlit app runs the refresh for you.

**4. Extraction.** Edit the category list in `sql/03_extract.sql` to match your picklist, then run it.
Within a minute `VOICE_NOTE_EXTRACT` has one row per note, with empty fields for anything the
associate didn't say.

**5. Review queue.** Edit `sql/04_review.sql` so the column names and budget labels match your
prospects table, then run it. `PENDING_UPDATES` shows one row per proposed change:

| rule | Meaning | Needs review |
|---|---|---|
| `FILL` | CRM field is empty, the note supplies a value | No (unless the name match was fuzzy) |
| `CONFLICT` | Note disagrees with the CRM | Yes |
| `PAST_DATE` | Follow-up date is already in the past | Yes |
| `NEW_PROSPECT` | No matching prospect in this associate's book | Yes |
| `NO_CHANGE` | Same as the CRM | Not queued |

**6. Write-back.** Run `sql/05_writeback.sql`, approve a note, then call
`WRITE_BACK(FALSE)`. The note appears in `voice_note_submissions` in Postgres, and in
`VOICE_CAPTURE_CRM.PUBLIC.VOICE_NOTE_SUBMISSIONS` about 30 seconds later through the mirror.

**7. App (optional).** Create a Streamlit in Snowflake app from `streamlit/streamlit_app.py`, with
database `VOICE_CAPTURE` and schema `PIPELINE`.

## Promotion: who updates the core CRM tables?

- **`WRITE_BACK(FALSE)` (recommended to start).** Snowflake writes reviewed notes to the inbox with
  status `APPROVED` or `REJECTED`. Your CRM app promotes approved fields into its own tables, so your
  existing business rules, audit trail and UI stay in charge.
- **`WRITE_BACK(TRUE)`.** Snowflake also updates the prospect columns listed in `COLS`, in the same
  Postgres transaction, and marks the note `PROMOTED`. `voice_writer` can only update the columns
  granted in `00_postgres_inbox.sql`.

## Design choices

- **Why `AI_COMPLETE` with a JSON schema, not `AI_EXTRACT`.** We tested both on real dictations.
  `AI_EXTRACT` returned the text "None" for missing fields, added objections nobody mentioned, and got
  relative dates ("Friday") wrong. A schema with no required fields lets the model leave out anything
  the associate didn't say, and an `enum` keeps categories to your picklist.
- **The recording date goes into the prompt**, so "follow up Friday" becomes an actual date.
- **Name matching is fuzzy and scoped to the associate's own prospects.** Speech-to-text misspells
  names (in testing, "Luis" came back as "Louise"). A fuzzy match is still applied, but always flagged
  for a human to confirm.
- **Idempotent on `file_path`.** Re-uploading or re-running never creates duplicates.
- **TLS verifies the instance's CA certificate** (equivalent to `sslmode=verify-ca`).

## What it costs

| Driver | How it's billed |
|---|---|
| `AI_TRANSCRIBE` | 50 tokens per second of audio; minimum 10 seconds per file |
| `AI_COMPLETE` extraction | Input plus output tokens per note; measure yours with `AI_COUNT_TOKENS` on a sample |
| Tasks | Serverless, and they only run when a new file or transcript arrives |
| Mirror | Serverless apply task every 30 seconds, plus storage of the mirrored tables |

To estimate: number of associates × notes per day × average note length in seconds.

## Known gaps

- **Laptops behind a corporate proxy (e.g. Zscaler)** may not reach Snowflake Postgres on port 5432 with
  psql. This pipeline doesn't need laptop access to Postgres; Snowflake connects to it directly.
- **Snowflake's egress IP ranges expire.** Automate refreshing your Postgres network rule
  ([docs](https://docs.snowflake.com/en/user-guide/egress-ip/network-egress)).
- **Multiple customers in one note** isn't handled yet; the extraction assumes one customer per note.

## Clean up

```sql
CALL SNOWFLAKE.POSTGRES.DROP_MIRROR('voice_crm_mirror', drop_target_database => TRUE);
DROP DATABASE VOICE_CAPTURE;
DROP INTEGRATION VOICE_PG_EAI;
```
In Postgres: `DROP TABLE voice_note_submissions; DROP ROLE voice_writer;`
