-- Step 4: entity resolution + review queue. Run one statement at a time.
-- ADAPT: column names below assume a prospects table with prospect_id, name, associate_id, phone, email,
-- interest_category, budget_band, move_in_date, next_step, next_followup_date. Rename to your CRM's columns,
-- and change the budget_band labels to your picklist values. List fields (products, decision makers,
-- objections) are not compared; they travel in voice_note_submissions.extracted.

-- 4a. Match each note to a prospect in the associate's own book (fuzzy, speech-to-text safe).
CREATE OR REPLACE VIEW VOICE_CAPTURE.PIPELINE.V_NOTE_MATCH AS
SELECT e.file_path, e.associate_id, e.prospect_name AS spoken_name,
       IFF(m.score >= 90, m.prospect_id, NULL) AS prospect_id,
       m.name  AS crm_name,
       m.score AS match_score,
       CASE WHEN m.score = 100 THEN 'EXACT'
            WHEN m.score >= 90 THEN 'FUZZY'
            ELSE 'NEW_PROSPECT' END AS match_type
FROM VOICE_CAPTURE.PIPELINE.VOICE_NOTE_EXTRACT e
LEFT JOIN (
  SELECT e2.file_path, p.prospect_id, p.name,
         GREATEST(JAROWINKLER_SIMILARITY(LOWER(e2.prospect_name), LOWER(p.name)),
                  IFF(STARTSWITH(LOWER(p.name), LOWER(e2.prospect_name)), 95, 0)) AS score
  FROM VOICE_CAPTURE.PIPELINE.VOICE_NOTE_EXTRACT e2
  JOIN VOICE_CAPTURE_CRM.PUBLIC.PROSPECTS p ON p.associate_id = e2.associate_id
  QUALIFY ROW_NUMBER() OVER (PARTITION BY e2.file_path ORDER BY score DESC) = 1
) m ON m.file_path = e.file_path;

-- 4b. One row per proposed field change: CRM value vs voice-note value, with a rule verdict.
CREATE OR REPLACE VIEW VOICE_CAPTURE.PIPELINE.V_PROPOSED_UPDATES AS
WITH x AS (
  SELECT e.*, m.prospect_id, m.match_type, m.match_score, m.crm_name,
         CASE WHEN e.budget_usd IS NULL THEN NULL          -- ADAPT: your budget picklist
              WHEN e.budget_usd < 2000  THEN 'Under $2K'
              WHEN e.budget_usd < 5000  THEN '$2K-$5K'
              WHEN e.budget_usd < 10000 THEN '$5K-$10K'
              ELSE '$10K+' END AS budget_band_new
  FROM VOICE_CAPTURE.PIPELINE.VOICE_NOTE_EXTRACT e
  JOIN VOICE_CAPTURE.PIPELINE.V_NOTE_MATCH m USING (file_path)
),
f AS (   -- unpivot: only fields the associate actually said
  SELECT file_path, prospect_id, match_type, match_score, 'phone' AS field, phone AS new_value FROM x WHERE phone IS NOT NULL
  UNION ALL SELECT file_path, prospect_id, match_type, match_score, 'email', email FROM x WHERE email IS NOT NULL
  UNION ALL SELECT file_path, prospect_id, match_type, match_score, 'interest_category', interest_category FROM x WHERE interest_category IS NOT NULL
  UNION ALL SELECT file_path, prospect_id, match_type, match_score, 'budget_band', budget_band_new FROM x WHERE budget_band_new IS NOT NULL
  UNION ALL SELECT file_path, prospect_id, match_type, match_score, 'move_in_date', move_in_date::STRING FROM x WHERE move_in_date IS NOT NULL
  UNION ALL SELECT file_path, prospect_id, match_type, match_score, 'next_step', next_step FROM x WHERE next_step IS NOT NULL
  UNION ALL SELECT file_path, prospect_id, match_type, match_score, 'next_followup_date', next_followup_date::STRING FROM x WHERE next_followup_date IS NOT NULL
)
SELECT f.file_path, f.prospect_id, f.match_type, f.match_score, f.field,
       CASE f.field
         WHEN 'phone' THEN p.phone WHEN 'email' THEN p.email
         WHEN 'interest_category' THEN p.interest_category
         WHEN 'budget_band' THEN p.budget_band WHEN 'move_in_date' THEN p.move_in_date::STRING
         WHEN 'next_step' THEN p.next_step WHEN 'next_followup_date' THEN p.next_followup_date::STRING
       END AS old_value,
       f.new_value,
       CASE
         WHEN f.prospect_id IS NULL THEN 'NEW_PROSPECT'
         WHEN f.field = 'next_followup_date' AND TRY_TO_DATE(f.new_value) < CURRENT_DATE() THEN 'PAST_DATE'
         WHEN old_value IS NULL THEN 'FILL'
         WHEN old_value = f.new_value THEN 'NO_CHANGE'
         ELSE 'CONFLICT'
       END AS rule
FROM f
LEFT JOIN VOICE_CAPTURE_CRM.PUBLIC.PROSPECTS p ON p.prospect_id = f.prospect_id;

-- 4c. The review queue. Persisted so approve/reject decisions stick.
CREATE TABLE IF NOT EXISTS VOICE_CAPTURE.PIPELINE.PENDING_UPDATES (
  file_path    STRING,
  prospect_id  STRING,
  match_type   STRING,
  field        STRING,
  old_value    STRING,
  new_value    STRING,
  rule         STRING,          -- FILL / CONFLICT / NO_CHANGE / PAST_DATE / NEW_PROSPECT
  needs_review BOOLEAN,
  decision     STRING DEFAULT 'PENDING',   -- PENDING / APPROVED / REJECTED
  decided_by   STRING,
  decided_at   TIMESTAMP_LTZ,
  queued_at    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  written_back_at TIMESTAMP_LTZ,
  PRIMARY KEY (file_path, field)
);

INSERT INTO VOICE_CAPTURE.PIPELINE.PENDING_UPDATES
  (file_path, prospect_id, match_type, field, old_value, new_value, rule, needs_review)
SELECT file_path, prospect_id, match_type, field, old_value, new_value, rule,
       rule IN ('CONFLICT','PAST_DATE','NEW_PROSPECT') OR match_type = 'FUZZY'
FROM VOICE_CAPTURE.PIPELINE.V_PROPOSED_UPDATES v
WHERE rule <> 'NO_CHANGE'
  AND NOT EXISTS (SELECT 1 FROM VOICE_CAPTURE.PIPELINE.PENDING_UPDATES q
                  WHERE q.file_path = v.file_path AND q.field = v.field);

-- Review screen:
-- SELECT file_path, prospect_id, match_type, field, old_value, new_value, rule, needs_review
-- FROM VOICE_CAPTURE.PIPELINE.PENDING_UPDATES WHERE decision = 'PENDING' ORDER BY needs_review DESC, file_path, field;
