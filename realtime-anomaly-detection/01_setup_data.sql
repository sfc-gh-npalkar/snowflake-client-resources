----------------------------------------------------------------------
-- 01_setup_data.sql
-- Order-execution anomaly detection demo: environment + synthetic data
--
-- Creates a scratch database and a synthetic ORDERS table representing
-- order-execution events. The only failure signal is IS_FILLED
-- (filled vs. not filled) -- deliberately no failure reason codes, which
-- mirrors the common starting point where reason codes live in a
-- separate log/observability platform and have not been piped in yet.
----------------------------------------------------------------------

USE ROLE SYSADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE DATABASE IF NOT EXISTS TRADE_ANOMALY_DEMO;
CREATE SCHEMA   IF NOT EXISTS TRADE_ANOMALY_DEMO.ANALYTICS;

USE SCHEMA TRADE_ANOMALY_DEMO.ANALYTICS;

----------------------------------------------------------------------
-- Raw order events
----------------------------------------------------------------------
CREATE OR REPLACE TABLE ORDERS (
    ORDER_ID      NUMBER        COMMENT 'Unique order identifier',
    ORDER_TS      TIMESTAMP_NTZ COMMENT 'Timestamp the order was submitted',
    TRADING_PAIR  VARCHAR       COMMENT 'Instrument / trading pair the order was placed against',
    SIDE          VARCHAR       COMMENT 'BUY or SELL',
    ORDER_QTY     FLOAT         COMMENT 'Order quantity in base asset units',
    IS_FILLED     BOOLEAN       COMMENT 'TRUE when the order executed, FALSE when it failed to fill'
)
COMMENT = 'Raw order execution events. One row per submitted order. IS_FILLED is the only failure signal available at this stage - no reason codes yet.';

----------------------------------------------------------------------
-- 14 days of history at 20 orders/minute (403,200 rows).
--
-- Baseline fill-failure rates are set per trading pair so that some
-- pairs are naturally noisier than others (~3% to ~8%, ~5.5% overall).
-- A mild time-of-day effect (higher failures 13:00-15:00) gives the
-- anomaly detection model real seasonality to learn, which is what
-- lets it beat a naive fixed threshold.
----------------------------------------------------------------------
INSERT INTO ORDERS (ORDER_ID, ORDER_TS, TRADING_PAIR, SIDE, ORDER_QTY, IS_FILLED)
WITH base AS (
    SELECT
        SEQ8()             AS rn,
        FLOOR(SEQ8() / 20) AS minute_idx
    FROM TABLE(GENERATOR(ROWCOUNT => 403200))
),
enriched AS (
    SELECT
        rn,
        DATEADD('minute', minute_idx - 20160, DATE_TRUNC('minute', CURRENT_TIMESTAMP()))::TIMESTAMP_NTZ AS order_ts,
        CASE MOD(rn, 5)
            WHEN 0 THEN 'BTC-USD'
            WHEN 1 THEN 'ETH-USD'
            WHEN 2 THEN 'SOL-USD'
            WHEN 3 THEN 'XRP-USD'
            ELSE        'ADA-USD'
        END AS trading_pair,
        CASE MOD(rn, 5)
            WHEN 0 THEN 0.030
            WHEN 1 THEN 0.040
            WHEN 2 THEN 0.055
            WHEN 3 THEN 0.075
            ELSE        0.065
        END AS pair_base_fail_rate
    FROM base
)
SELECT
    rn + 1                                                AS ORDER_ID,
    order_ts                                              AS ORDER_TS,
    trading_pair                                          AS TRADING_PAIR,
    CASE WHEN MOD(rn, 2) = 0 THEN 'BUY' ELSE 'SELL' END   AS SIDE,
    ROUND(UNIFORM(1, 10000, RANDOM()) / 100.0, 4)         AS ORDER_QTY,
    (UNIFORM(0, 999999, RANDOM()) / 1000000.0)
        > (pair_base_fail_rate * CASE WHEN HOUR(order_ts) BETWEEN 13 AND 15 THEN 1.25 ELSE 1.0 END)
                                                          AS IS_FILLED
FROM enriched;

----------------------------------------------------------------------
-- Sanity check: expect ~5.5% overall, ~3% (cleanest pair) to ~8% (noisiest)
----------------------------------------------------------------------
SELECT
    TRADING_PAIR,
    COUNT(*)                                  AS orders,
    ROUND(100 * AVG(IFF(IS_FILLED, 0, 1)), 3) AS fail_rate_pct,
    MIN(ORDER_TS)                             AS first_ts,
    MAX(ORDER_TS)                             AS last_ts
FROM ORDERS
GROUP BY TRADING_PAIR
UNION ALL
SELECT
    'ALL PAIRS',
    COUNT(*),
    ROUND(100 * AVG(IFF(IS_FILLED, 0, 1)), 3),
    MIN(ORDER_TS),
    MAX(ORDER_TS)
FROM ORDERS
ORDER BY 1;
