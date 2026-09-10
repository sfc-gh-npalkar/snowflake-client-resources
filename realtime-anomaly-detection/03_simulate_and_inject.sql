----------------------------------------------------------------------
-- 03_simulate_and_inject.sql
-- Demo drivers: keep the series current, then inject a detectable anomaly
--
-- Run STEP 1 shortly before presenting, then STEP 2 live during the demo.
----------------------------------------------------------------------

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;
USE SCHEMA TRADE_ANOMALY_DEMO.ANALYTICS;

----------------------------------------------------------------------
-- STEP 1 -- Backfill normal traffic from the last order up to now.
--
-- The seed data ends whenever 01_setup_data.sql was run, so without this
-- there is a widening gap between the end of the series and "now", and the
-- injected spike would sit alone after a long silence. Idempotent and safe
-- to run repeatedly; it only fills the gap that currently exists
-- (up to ~33 hours per run).
----------------------------------------------------------------------
INSERT INTO ORDERS (ORDER_ID, ORDER_TS, TRADING_PAIR, SIDE, ORDER_QTY, IS_FILLED)
WITH bounds AS (
    SELECT
        MAX(ORDER_TS)                                            AS last_ts,
        MAX(ORDER_ID)                                            AS max_id,
        DATE_TRUNC('minute', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ AS now_ts
    FROM ORDERS
),
gen AS (
    SELECT SEQ8() AS rn FROM TABLE(GENERATOR(ROWCOUNT => 40000))
),
enriched AS (
    SELECT
        g.rn,
        b.max_id,
        DATEADD('minute', FLOOR(g.rn / 20) + 1, b.last_ts)::TIMESTAMP_NTZ AS order_ts,
        CASE MOD(g.rn, 5)
            WHEN 0 THEN 'BTC-USD'
            WHEN 1 THEN 'ETH-USD'
            WHEN 2 THEN 'SOL-USD'
            WHEN 3 THEN 'XRP-USD'
            ELSE        'ADA-USD'
        END AS trading_pair,
        CASE MOD(g.rn, 5)
            WHEN 0 THEN 0.030
            WHEN 1 THEN 0.040
            WHEN 2 THEN 0.055
            WHEN 3 THEN 0.075
            ELSE        0.065
        END AS pair_base_fail_rate
    FROM gen g
    CROSS JOIN bounds b
    WHERE FLOOR(g.rn / 20) < DATEDIFF('minute', b.last_ts, b.now_ts)
)
SELECT
    max_id + rn + 1                                       AS ORDER_ID,
    order_ts                                              AS ORDER_TS,
    trading_pair                                          AS TRADING_PAIR,
    CASE WHEN MOD(rn, 2) = 0 THEN 'BUY' ELSE 'SELL' END   AS SIDE,
    ROUND(UNIFORM(1, 10000, RANDOM()) / 100.0, 4)         AS ORDER_QTY,
    (UNIFORM(0, 999999, RANDOM()) / 1000000.0)
        > (pair_base_fail_rate * CASE WHEN HOUR(order_ts) BETWEEN 13 AND 15 THEN 1.25 ELSE 1.0 END)
                                                          AS IS_FILLED
FROM enriched;

----------------------------------------------------------------------
-- STEP 2 -- Inject the incident: a burst of failures on ONE pair,
-- simulating a routing/venue problem on the platform's own side rather
-- than benign "no counterparty" no-fills.
--
-- 300 extra orders at a ~65% failure rate. Combined with the ~100 normal
-- orders already in that bucket this lands the bucket near 50-55% against a
-- ~5% baseline -- far outside the model's prediction interval.
--
-- GOTCHA: this targets the last COMPLETE bucket, not the current one. The
-- scoring view excludes the newest bucket because it is still filling, so
-- injecting into "now" would produce an anomaly the model never scores.
----------------------------------------------------------------------
INSERT INTO ORDERS (ORDER_ID, ORDER_TS, TRADING_PAIR, SIDE, ORDER_QTY, IS_FILLED)
WITH bounds AS (
    SELECT
        MAX(ORDER_ID) AS max_id,
        DATEADD('minute', -5, TIME_SLICE(CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, 5, 'MINUTE')) AS target_bucket_start
    FROM ORDERS
),
gen AS (
    SELECT SEQ8() AS rn FROM TABLE(GENERATOR(ROWCOUNT => 300))
)
SELECT
    b.max_id + g.rn + 1                                          AS ORDER_ID,
    DATEADD('second', MOD(g.rn * 7, 300), b.target_bucket_start)  AS ORDER_TS,
    'SOL-USD'                                                    AS TRADING_PAIR,
    CASE WHEN MOD(g.rn, 2) = 0 THEN 'BUY' ELSE 'SELL' END        AS SIDE,
    ROUND(UNIFORM(1, 10000, RANDOM()) / 100.0, 4)                AS ORDER_QTY,
    (UNIFORM(0, 999999, RANDOM()) / 1000000.0) > 0.65            AS IS_FILLED
FROM gen g
CROSS JOIN bounds b;

----------------------------------------------------------------------
-- STEP 3 -- Watch the Dynamic Table pick it up (no manual refresh needed).
-- Takes up to TARGET_LAG (~1 minute); re-run until the spike appears.
----------------------------------------------------------------------
SELECT BUCKET_TS, TOTAL_ORDERS, FAILED_ORDERS, FAIL_RATE_PCT
FROM ORDER_FILL_RATE_5MIN
ORDER BY BUCKET_TS DESC
LIMIT 5;

-- Which pair is driving it?
SELECT BUCKET_TS, TRADING_PAIR, TOTAL_ORDERS, FAILED_ORDERS, FAIL_RATE_PCT
FROM ORDER_FILL_RATE_5MIN_BY_PAIR
ORDER BY BUCKET_TS DESC, FAIL_RATE_PCT DESC
LIMIT 10;

----------------------------------------------------------------------
-- STEP 4 -- Confirm the model flags it.
-- Expect IS_ANOMALY = TRUE on the injected bucket with a large DISTANCE,
-- and FALSE everywhere else.
----------------------------------------------------------------------
SELECT
    TS,
    Y                    AS actual_fail_rate_pct,
    ROUND(FORECAST, 3)   AS expected,
    ROUND(UPPER_BOUND, 3) AS upper_bound,
    IS_ANOMALY,
    ROUND(DISTANCE, 2)   AS std_devs_out
FROM TABLE(FILL_RATE_ANOMALY_MODEL!DETECT_ANOMALIES(
    INPUT_DATA        => TABLE(V_FILL_RATE_RECENT),
    TIMESTAMP_COLNAME => 'BUCKET_TS',
    TARGET_COLNAME    => 'FAIL_RATE_PCT'
))
ORDER BY TS DESC
LIMIT 8;

----------------------------------------------------------------------
-- RESET (optional) -- remove injected spikes, keeping the seeded history.
-- Any bucket with a SOL-USD order count far above the ~20/bucket norm is
-- an injection.
----------------------------------------------------------------------
-- DELETE FROM ORDERS
-- WHERE TRADING_PAIR = 'SOL-USD'
--   AND TIME_SLICE(ORDER_TS, 5, 'MINUTE') IN (
--       SELECT TIME_SLICE(ORDER_TS, 5, 'MINUTE')
--       FROM ORDERS
--       WHERE TRADING_PAIR = 'SOL-USD'
--       GROUP BY 1
--       HAVING COUNT(*) > 100
--   );
