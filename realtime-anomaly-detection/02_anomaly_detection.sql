----------------------------------------------------------------------
-- 02_anomaly_detection.sql
-- Rolling fill-failure rate (Dynamic Tables) + native ML anomaly detection
--
-- Design note: buckets are 5 minutes, not 1 minute. At ~20 orders/minute a
-- per-minute failure rate has a standard deviation roughly as large as its
-- own mean, so anomaly detection on it is meaningless. 5-minute buckets give
-- ~100 orders per point (std dev ~2.3% against a ~5.5% mean) while still
-- meeting a "detect within a few minutes" requirement.
----------------------------------------------------------------------

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE SCHEMA TRADE_ANOMALY_DEMO.ANALYTICS;

----------------------------------------------------------------------
-- 1. Rolling fail rate, all pairs. This is the series the model scores.
--    TARGET_LAG = 1 minute so newly landed orders show up almost immediately
--    with no scheduler or batch job to maintain.
----------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ORDER_FILL_RATE_5MIN
    TARGET_LAG = '1 minute'
    WAREHOUSE  = COMPUTE_WH
    COMMENT    = 'Fill-failure rate aggregated into 5-minute buckets across all trading pairs. This is the time series fed to the anomaly detection model.'
AS
SELECT
    TIME_SLICE(ORDER_TS, 5, 'MINUTE')                      AS BUCKET_TS,
    COUNT(*)                                               AS TOTAL_ORDERS,
    SUM(IFF(IS_FILLED, 0, 1))                              AS FAILED_ORDERS,
    SUM(IFF(IS_FILLED, 1, 0))                              AS FILLED_ORDERS,
    ROUND(100.0 * SUM(IFF(IS_FILLED, 0, 1)) / COUNT(*), 4) AS FAIL_RATE_PCT
FROM ORDERS
GROUP BY TIME_SLICE(ORDER_TS, 5, 'MINUTE');

----------------------------------------------------------------------
-- 2. Same metric per trading pair, for drill-down once an alert fires
--    ("which pair is driving this?"). Also the input you would use for
--    multi-series detection via SERIES_COLNAME.
----------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE ORDER_FILL_RATE_5MIN_BY_PAIR
    TARGET_LAG = '1 minute'
    WAREHOUSE  = COMPUTE_WH
    COMMENT    = 'Fill-failure rate in 5-minute buckets broken out per trading pair. Used for drill-down after an anomaly fires, and supports multi-series anomaly detection.'
AS
SELECT
    TIME_SLICE(ORDER_TS, 5, 'MINUTE')                      AS BUCKET_TS,
    TRADING_PAIR,
    COUNT(*)                                               AS TOTAL_ORDERS,
    SUM(IFF(IS_FILLED, 0, 1))                              AS FAILED_ORDERS,
    SUM(IFF(IS_FILLED, 1, 0))                              AS FILLED_ORDERS,
    ROUND(100.0 * SUM(IFF(IS_FILLED, 0, 1)) / COUNT(*), 4) AS FAIL_RATE_PCT
FROM ORDERS
GROUP BY TIME_SLICE(ORDER_TS, 5, 'MINUTE'), TRADING_PAIR;

----------------------------------------------------------------------
-- 3. Training / scoring split.
--
-- GOTCHA: DETECT_ANOMALIES rejects any evaluation timestamp that is not
-- strictly after the last timestamp in the training data. Training on the
-- full history therefore leaves nothing scoreable and errors with
-- "All evaluation timestamps must be after the last timestamp in fitting
-- data." Hold back a scoring window.
----------------------------------------------------------------------
CREATE OR REPLACE VIEW V_FILL_RATE_TRAINING
    COMMENT = 'Complete 5-minute buckets used to train the anomaly detection model. Holds back the most recent hour so there is a scoring window.'
AS
SELECT BUCKET_TS, FAIL_RATE_PCT
FROM ORDER_FILL_RATE_5MIN
WHERE BUCKET_TS < DATEADD('hour', -1, (SELECT MAX(BUCKET_TS) FROM ORDER_FILL_RATE_5MIN));

CREATE OR REPLACE VIEW V_FILL_RATE_RECENT
    COMMENT = 'Buckets scored by the anomaly detection model: everything after the training cutoff, excluding the still-filling current bucket.'
AS
SELECT BUCKET_TS, FAIL_RATE_PCT
FROM ORDER_FILL_RATE_5MIN
WHERE BUCKET_TS >= DATEADD('hour', -1, (SELECT MAX(BUCKET_TS) FROM ORDER_FILL_RATE_5MIN))
  AND BUCKET_TS <  (SELECT MAX(BUCKET_TS) FROM ORDER_FILL_RATE_5MIN);

----------------------------------------------------------------------
-- 4. Train the model.
--
-- No labelled data required -- LABEL_COLNAME is empty. The model learns the
-- normal shape of the series (level, trend, time-of-day seasonality) by
-- forecasting each point and comparing the actual value to that forecast.
-- That is what makes it stronger than a fixed "alert above 5%" rule: a
-- routine end-of-day bump is expected and stays quiet, while the same
-- absolute value at an unexpected time is flagged.
--
-- Training wants a warehouse without concurrent workloads.
----------------------------------------------------------------------
CREATE OR REPLACE SNOWFLAKE.ML.ANOMALY_DETECTION FILL_RATE_ANOMALY_MODEL(
    INPUT_DATA        => TABLE(V_FILL_RATE_TRAINING),
    TIMESTAMP_COLNAME => 'BUCKET_TS',
    TARGET_COLNAME    => 'FAIL_RATE_PCT',
    LABEL_COLNAME     => ''
);

----------------------------------------------------------------------
-- 5. Score. Expect IS_ANOMALY = FALSE across the board on normal traffic --
--    verify this before injecting a synthetic spike, otherwise the demo is
--    showing false positives rather than detection.
--
-- Output columns: Y (actual), FORECAST (expected), LOWER_BOUND/UPPER_BOUND
-- (prediction interval), IS_ANOMALY, PERCENTILE, DISTANCE (how far out).
----------------------------------------------------------------------
CALL FILL_RATE_ANOMALY_MODEL!DETECT_ANOMALIES(
    INPUT_DATA        => TABLE(V_FILL_RATE_RECENT),
    TIMESTAMP_COLNAME => 'BUCKET_TS',
    TARGET_COLNAME    => 'FAIL_RATE_PCT'
);
