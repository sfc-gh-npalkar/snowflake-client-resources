-- Step 2: landing table + stream on the stage directory + transcription task.
-- Run one statement at a time.

CREATE TABLE IF NOT EXISTS VOICE_CAPTURE.PIPELINE.VOICE_NOTES_RAW (
  file_path      STRING PRIMARY KEY,           -- idempotency key, carried to Postgres
  associate_id   STRING,                       -- parsed from filename prefix (<ASSOCIATE_ID>_...)
  uploaded_at    TIMESTAMP_LTZ,
  audio_seconds  FLOAT,
  transcript     STRING,
  transcribe_raw VARIANT,
  transcribed_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE STREAM IF NOT EXISTS VOICE_CAPTURE.PIPELINE.VOICE_STAGE_STREAM
  ON STAGE VOICE_CAPTURE.PIPELINE.VOICE_STAGE;

CREATE TASK IF NOT EXISTS VOICE_CAPTURE.PIPELINE.TRANSCRIBE_NOTES
  TARGET_COMPLETION_INTERVAL = '1 MINUTE'   -- required for serverless triggered tasks
  WHEN SYSTEM$STREAM_HAS_DATA('VOICE_CAPTURE.PIPELINE.VOICE_STAGE_STREAM')
AS
INSERT INTO VOICE_CAPTURE.PIPELINE.VOICE_NOTES_RAW
  (file_path, associate_id, uploaded_at, audio_seconds, transcript, transcribe_raw)
SELECT
  relative_path,
  (REGEXP_SUBSTR(relative_path, '^([^_]+)_', 1, 1, 'e')),
  last_modified::TIMESTAMP_LTZ,
  t:audio_duration::FLOAT,
  t:text::STRING,
  t
FROM (
  SELECT relative_path, last_modified,
         PARSE_JSON(TO_VARCHAR(AI_TRANSCRIBE(TO_FILE('@VOICE_CAPTURE.PIPELINE.VOICE_STAGE', relative_path)))) AS t
  FROM VOICE_CAPTURE.PIPELINE.VOICE_STAGE_STREAM
  WHERE METADATA$ACTION = 'INSERT'
) s
WHERE NOT EXISTS (SELECT 1 FROM VOICE_CAPTURE.PIPELINE.VOICE_NOTES_RAW r WHERE r.file_path = s.relative_path);

ALTER TASK VOICE_CAPTURE.PIPELINE.TRANSCRIBE_NOTES RESUME;
