-- 00_postgres_inbox.sql
-- Run in YOUR CRM's Postgres database (psql, your migration tool, or wherever you run CRM DDL).
-- Adds one table and one login role. Nothing in your existing CRM tables changes.

-- Inbox: Snowflake writes reviewed voice notes here. Your CRM app (or the write-back proc) promotes
-- approved fields into the core tables. file_path is the idempotency key, so re-sends are safe.
CREATE TABLE IF NOT EXISTS voice_note_submissions (
  file_path     text PRIMARY KEY,
  prospect_id   text,                       -- your prospect key (NULL = new prospect)
  associate_id  text NOT NULL,
  transcript    text,
  extracted     jsonb NOT NULL,             -- everything the model pulled out of the note
  status        text NOT NULL CHECK (status IN ('CLEAN','NEEDS_REVIEW','APPROVED','REJECTED','PROMOTED')),
  reasons       jsonb NOT NULL DEFAULT '[]',
  submitted_at  timestamptz NOT NULL DEFAULT now(),
  reviewed_by   text,
  reviewed_at   timestamptz,
  promoted_at   timestamptz
);

-- Least-privilege login for Snowflake. Do not use snowflake_admin.
CREATE ROLE voice_writer LOGIN PASSWORD '<choose-a-strong-password>';
GRANT USAGE ON SCHEMA public TO voice_writer;
GRANT SELECT, INSERT, UPDATE ON voice_note_submissions TO voice_writer;
-- Only if Snowflake should promote approved fields directly (see README, "Promotion"):
GRANT SELECT ON prospects TO voice_writer;
GRANT UPDATE (phone, email, interest_category, budget_band, move_in_date, next_step, next_followup_date)
  ON prospects TO voice_writer;      -- column-level: voice notes can't touch anything else
