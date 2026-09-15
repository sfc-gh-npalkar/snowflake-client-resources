----------------------------------------------------------------------
-- 04_alerting.sql
-- Push notification on detected anomalies ("PagerDuty for order execution")
--
-- Two objects, deliberately separated:
--   TASK  -- scores the series every minute and records what it finds
--   ALERT -- notifies on anything recorded but not yet sent
--
-- Keeping detection and notification apart means an incident pages exactly
-- once, and the notification channel can be swapped without touching the
-- detection logic.
----------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;   -- required to create a notification integration
USE WAREHOUSE COMPUTE_WH;
USE SCHEMA TRADE_ANOMALY_DEMO.ANALYTICS;

----------------------------------------------------------------------
-- 1. Notification channel.
--
-- EMAIL is used here because it needs no external approval and works
-- immediately. Recipients must be verified email addresses of users in the
-- account. To route to Slack / PagerDuty / Opsgenie instead, create a
-- webhook-type integration and point the notification call at it -- the
-- detection logic below does not change.
----------------------------------------------------------------------
CREATE OR REPLACE NOTIFICATION INTEGRATION TRADE_ANOMALY_EMAIL_INT
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('you@example.com')   -- replace with a verified account email
    COMMENT = 'Email channel for order-execution anomaly alerts. Swap for a webhook integration to route to Slack/PagerDuty without changing the ALERT logic.';

----------------------------------------------------------------------
-- 2. Anomaly ledger. Also the table the Cortex Agent reads, so questions
--    like "what fired in the last hour" resolve without re-scoring.
----------------------------------------------------------------------
CREATE OR REPLACE TABLE ANOMALY_EVENTS (
    BUCKET_TS              TIMESTAMP_NTZ COMMENT '5-minute bucket that was flagged',
    ACTUAL_FAIL_RATE_PCT   FLOAT         COMMENT 'Observed fill-failure rate for the bucket',
    EXPECTED_FAIL_RATE_PCT FLOAT         COMMENT 'Rate the model forecast for this bucket',
    UPPER_BOUND_PCT        FLOAT         COMMENT 'Top of the model prediction interval',
    DISTANCE               FLOAT         COMMENT 'How far outside normal, in standard deviations',
    TOP_PAIR               VARCHAR       COMMENT 'Trading pair with the highest failure rate in the bucket',
    TOP_PAIR_FAIL_RATE_PCT FLOAT         COMMENT 'Failure rate of that pair',
    TOP_PAIR_FAILED_ORDERS NUMBER        COMMENT 'Failed order count for that pair',
    DETECTED_AT            TIMESTAMP_LTZ COMMENT 'When the scoring run flagged it',
    NOTIFIED               BOOLEAN       COMMENT 'TRUE once an alert notification has been sent',
    CONSTRAINT PK_ANOMALY_EVENTS PRIMARY KEY (BUCKET_TS)
)
COMMENT = 'One row per 5-minute bucket flagged as anomalous. Written by the scoring task, consumed by the alert and by the Cortex Agent.';

----------------------------------------------------------------------
-- 3. Scoring: flag buckets and enrich each with the worst-offending pair,
--    so the alert can say WHICH pair to look at, not just "rate is high".
--    NOT EXISTS keeps it idempotent -- a bucket is recorded once.
----------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_SCORE_FILL_RATE_ANOMALIES()
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Scores the recent fill-rate buckets with the anomaly detection model and records any newly flagged buckets in ANOMALY_EVENTS, enriched with the worst-offending trading pair.'
EXECUTE AS OWNER
AS
$$
DECLARE
    new_count INTEGER DEFAULT 0;
BEGIN
    CREATE OR REPLACE TEMPORARY TABLE TMP_SCORED AS
    SELECT
        TS::TIMESTAMP_NTZ AS BUCKET_TS,
        Y                 AS ACTUAL_FAIL_RATE_PCT,
        FORECAST          AS EXPECTED_FAIL_RATE_PCT,
        UPPER_BOUND       AS UPPER_BOUND_PCT,
        DISTANCE          AS DISTANCE
    FROM TABLE(TRADE_ANOMALY_DEMO.ANALYTICS.FILL_RATE_ANOMALY_MODEL!DETECT_ANOMALIES(
        INPUT_DATA        => TABLE(TRADE_ANOMALY_DEMO.ANALYTICS.V_FILL_RATE_RECENT),
        TIMESTAMP_COLNAME => 'BUCKET_TS',
        TARGET_COLNAME    => 'FAIL_RATE_PCT'
    ))
    WHERE IS_ANOMALY;

    INSERT INTO TRADE_ANOMALY_DEMO.ANALYTICS.ANOMALY_EVENTS
        (BUCKET_TS, ACTUAL_FAIL_RATE_PCT, EXPECTED_FAIL_RATE_PCT, UPPER_BOUND_PCT, DISTANCE,
         TOP_PAIR, TOP_PAIR_FAIL_RATE_PCT, TOP_PAIR_FAILED_ORDERS, DETECTED_AT, NOTIFIED)
    SELECT
        s.BUCKET_TS, s.ACTUAL_FAIL_RATE_PCT, s.EXPECTED_FAIL_RATE_PCT, s.UPPER_BOUND_PCT, s.DISTANCE,
        p.TRADING_PAIR, p.FAIL_RATE_PCT, p.FAILED_ORDERS,
        CURRENT_TIMESTAMP(), FALSE
    FROM TMP_SCORED s
    LEFT JOIN (
        SELECT
            BUCKET_TS, TRADING_PAIR, FAIL_RATE_PCT, FAILED_ORDERS,
            ROW_NUMBER() OVER (PARTITION BY BUCKET_TS ORDER BY FAIL_RATE_PCT DESC, FAILED_ORDERS DESC) AS rk
        FROM TRADE_ANOMALY_DEMO.ANALYTICS.ORDER_FILL_RATE_5MIN_BY_PAIR
    ) p
      ON p.BUCKET_TS = s.BUCKET_TS AND p.rk = 1
    WHERE NOT EXISTS (
        SELECT 1 FROM TRADE_ANOMALY_DEMO.ANALYTICS.ANOMALY_EVENTS e
        WHERE e.BUCKET_TS = s.BUCKET_TS
    );

    new_count := SQLROWCOUNT;
    RETURN 'Newly recorded anomalies: ' || :new_count;
END;
$$;

----------------------------------------------------------------------
-- 4. Notification. GOTCHA: the LISTAGG delimiter must be a literal
--    constant -- CHR(10)||CHR(10) fails to compile.
----------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_NOTIFY_ANOMALIES()
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Emails a summary of any anomaly events not yet notified, then marks them as notified so each incident pages once.'
EXECUTE AS OWNER
AS
$$
DECLARE
    msg  STRING;
    subj STRING;
    n    INTEGER DEFAULT 0;
BEGIN
    SELECT COUNT(*) INTO :n
    FROM TRADE_ANOMALY_DEMO.ANALYTICS.ANOMALY_EVENTS
    WHERE NOT NOTIFIED;

    IF (:n = 0) THEN
        RETURN 'No new anomalies to notify.';
    END IF;

    SELECT LISTAGG(
        'Bucket ' || TO_VARCHAR(BUCKET_TS, 'YYYY-MM-DD HH24:MI') ||
        '  |  fill-failure rate ' || TO_VARCHAR(ROUND(ACTUAL_FAIL_RATE_PCT, 2)) || '%' ||
        '  (expected ' || TO_VARCHAR(ROUND(EXPECTED_FAIL_RATE_PCT, 2)) || '%, ' ||
        TO_VARCHAR(ROUND(DISTANCE, 1)) || ' std devs outside normal)\n' ||
        '   worst pair: ' || COALESCE(TOP_PAIR, 'n/a') ||
        ' at ' || TO_VARCHAR(ROUND(COALESCE(TOP_PAIR_FAIL_RATE_PCT, 0), 2)) || '% (' ||
        TO_VARCHAR(COALESCE(TOP_PAIR_FAILED_ORDERS, 0)) || ' failed orders)',
        '\n\n'
    ) INTO :msg
    FROM TRADE_ANOMALY_DEMO.ANALYTICS.ANOMALY_EVENTS
    WHERE NOT NOTIFIED;

    subj := '[Order Execution] Abnormal fill-failure rate detected (' || :n || ')';

    CALL SYSTEM$SEND_EMAIL(
        'TRADE_ANOMALY_EMAIL_INT',
        'you@example.com',                      -- replace with a verified account email
        :subj,
        'Order execution anomaly detected.\n\n' || :msg ||
        '\n\nA fill-failure rate above the learned baseline usually points to a routing or venue issue rather than routine no-fills. Investigate the pair named above.'
    );

    UPDATE TRADE_ANOMALY_DEMO.ANALYTICS.ANOMALY_EVENTS
    SET NOTIFIED = TRUE
    WHERE NOT NOTIFIED;

    RETURN 'Notified anomalies: ' || :n;
END;
$$;

----------------------------------------------------------------------
-- 5. Schedule detection, and page on what it finds.
----------------------------------------------------------------------
CREATE OR REPLACE TASK T_SCORE_FILL_RATE_ANOMALIES
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = '1 MINUTE'
    COMMENT   = 'Scores the recent fill-rate buckets every minute and records newly flagged anomalies.'
AS
    CALL SP_SCORE_FILL_RATE_ANOMALIES();

CREATE OR REPLACE ALERT A_FILL_RATE_ANOMALY
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = '1 MINUTE'
    COMMENT   = 'Pages on any anomaly event not yet notified.'
    IF (EXISTS (
        SELECT 1 FROM ANOMALY_EVENTS WHERE NOT NOTIFIED
    ))
    THEN
        CALL SP_NOTIFY_ANOMALIES();

ALTER TASK  T_SCORE_FILL_RATE_ANOMALIES RESUME;
ALTER ALERT A_FILL_RATE_ANOMALY          RESUME;

----------------------------------------------------------------------
-- COST NOTE: the expensive part is not the polling itself, it is that a
-- schedule shorter than the warehouse AUTO_SUSPEND window stops the
-- warehouse from ever suspending. Measured on an X-Small: a 1-minute task
-- (~17s per run) plus a 1-minute alert = ~0.92 compute credits per hour,
-- i.e. effectively continuous uptime.
--
-- A warehouse at the common AUTO_SUSPEND = 600 stays hot for a 5-minute
-- schedule just as much as a 1-minute one, so lengthening the cadence alone
-- saves nothing. Change both:
--     ALTER TASK ... SET SCHEDULE = '5 MINUTE';
--     ALTER WAREHOUSE <WH> SET AUTO_SUSPEND = 60;
-- Per-resume billing has a 60-second minimum, so a 17-second run bills a
-- full minute regardless.
--
-- SUSPEND when finished, or these run indefinitely. Note the Dynamic Tables
-- in 02_anomaly_detection.sql keep polling separately and need their own
-- SUSPEND -- suspending the task and alert does not stop them.
----------------------------------------------------------------------
-- ALTER TASK  T_SCORE_FILL_RATE_ANOMALIES SUSPEND;
-- ALTER ALERT A_FILL_RATE_ANOMALY          SUSPEND;
-- ALTER DYNAMIC TABLE ORDER_FILL_RATE_5MIN         SUSPEND;
-- ALTER DYNAMIC TABLE ORDER_FILL_RATE_5MIN_BY_PAIR SUSPEND;
