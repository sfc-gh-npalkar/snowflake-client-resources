-- Step 3: structured extraction. Run one statement at a time.
-- Why AI_COMPLETE + a JSON schema rather than AI_EXTRACT: we tested both on sample dictations. AI_EXTRACT
-- returned the string "None" for missing fields, invented objections, and can't constrain a field to a
-- picklist. A schema with no required fields lets the model omit anything that wasn't said (absent = null).
-- ADAPT: the interest_category enum to your category picklist, and the prompt's business wording.

CREATE OR REPLACE FUNCTION VOICE_CAPTURE.PIPELINE.EXTRACT_CRM_FIELDS(note_date DATE, transcript STRING)
RETURNS VARIANT
AS
$$
  AI_COMPLETE(
    model => 'claude-sonnet-4-6',
    prompt => 'You extract CRM fields from a furniture showroom associate''s dictated note. Rules: include a field ONLY if the associate explicitly stated it; omit any field that was not stated; never infer or guess; if the associate corrects themselves, use the final value; resolve relative dates against the recording date (e.g. "Friday" = the next Friday after the recording date); omit dates for vague timing like "next week". The transcript may misspell names (speech-to-text). Respond in JSON.\n\nRecording date: '
              || TO_CHAR(note_date, 'YYYY-MM-DD') || ' (' || DAYNAME(note_date) || ')\nNote: ' || transcript,
    model_parameters => {'temperature': 0},
    response_format => {'type':'json','schema':{'type':'object','properties':{
       'prospect_name':{'type':'string','description':'Customer full name as spoken; for couples include both'},
       'phone':{'type':'string','description':'Digits only'},
       'email':{'type':'string','description':'Normalized address like a.b@example.com'},
       'interest_category':{'type':'string','enum':['sofa','sectional','bedroom','dining','mattress'],'description':'Current main category; the NEW one if they switched'},
       'other_categories':{'type':'array','items':{'type':'string','enum':['sofa','sectional','bedroom','dining','mattress']}},
       'products':{'type':'array','items':{'type':'string'},'description':'Specific products/configurations, final choices only'},
       'budget_usd':{'type':'integer','description':'Only if an amount was stated'},
       'budget_unchanged':{'type':'boolean','description':'Include as true only if associate said the budget is the same/unchanged'},
       'move_in_date':{'type':'string','description':'YYYY-MM-DD'},
       'decision_makers':{'type':'array','items':{'type':'string'},'description':'People OTHER than the customer who must approve'},
       'objections':{'type':'array','items':{'type':'string'}},
       'next_step':{'type':'string'},
       'next_followup_date':{'type':'string','description':'YYYY-MM-DD'}},
     'required':[]}}
  )
$$;

CREATE TABLE IF NOT EXISTS VOICE_CAPTURE.PIPELINE.VOICE_NOTE_EXTRACT (
  file_path          STRING PRIMARY KEY,
  associate_id       STRING,
  note_date          DATE,
  prospect_name      STRING,
  phone              STRING,
  email              STRING,
  interest_category  STRING,
  other_categories   ARRAY,
  products           ARRAY,
  budget_usd         NUMBER,
  budget_unchanged   BOOLEAN,
  move_in_date       DATE,
  decision_makers    ARRAY,
  objections         ARRAY,
  next_step          STRING,
  next_followup_date DATE,
  extracted          VARIANT,
  extracted_at       TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE STREAM IF NOT EXISTS VOICE_CAPTURE.PIPELINE.VOICE_NOTES_RAW_STREAM
  ON TABLE VOICE_CAPTURE.PIPELINE.VOICE_NOTES_RAW
  SHOW_INITIAL_ROWS = TRUE;   -- also picks up the notes already transcribed

CREATE TASK IF NOT EXISTS VOICE_CAPTURE.PIPELINE.EXTRACT_NOTES
  TARGET_COMPLETION_INTERVAL = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('VOICE_CAPTURE.PIPELINE.VOICE_NOTES_RAW_STREAM')
AS
INSERT INTO VOICE_CAPTURE.PIPELINE.VOICE_NOTE_EXTRACT
  (file_path, associate_id, note_date, prospect_name, phone, email, interest_category, other_categories,
   products, budget_usd, budget_unchanged, move_in_date, decision_makers, objections, next_step,
   next_followup_date, extracted)
SELECT file_path, associate_id, note_date,
  x:prospect_name::STRING, x:phone::STRING, x:email::STRING, x:interest_category::STRING,
  x:other_categories::ARRAY, x:products::ARRAY, x:budget_usd::NUMBER, x:budget_unchanged::BOOLEAN,
  TRY_TO_DATE(x:move_in_date::STRING), x:decision_makers::ARRAY, x:objections::ARRAY,
  x:next_step::STRING, TRY_TO_DATE(x:next_followup_date::STRING), x
FROM (
  SELECT file_path, associate_id, uploaded_at::DATE AS note_date,
         VOICE_CAPTURE.PIPELINE.EXTRACT_CRM_FIELDS(uploaded_at::DATE, transcript) AS x
  FROM VOICE_CAPTURE.PIPELINE.VOICE_NOTES_RAW_STREAM
  WHERE METADATA$ACTION = 'INSERT'
) s
WHERE NOT EXISTS (SELECT 1 FROM VOICE_CAPTURE.PIPELINE.VOICE_NOTE_EXTRACT e WHERE e.file_path = s.file_path);

ALTER TASK VOICE_CAPTURE.PIPELINE.EXTRACT_NOTES RESUME;

-- Check:
-- SELECT file_path, prospect_name, interest_category, budget_usd, move_in_date, next_followup_date, objections
-- FROM VOICE_CAPTURE.PIPELINE.VOICE_NOTE_EXTRACT ORDER BY 1;
