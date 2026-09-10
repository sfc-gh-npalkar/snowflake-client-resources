----------------------------------------------------------------------
-- 05_semantic_view_agent.sql
-- Natural-language access to the anomaly data
--
-- This layer is NOT a dashboard. It is what lets someone ask, in plain
-- English, "which pair caused the spike an hour ago" after an alert lands,
-- without writing SQL. The alert tells you something broke; this tells you
-- what and where.
----------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE SCHEMA TRADE_ANOMALY_DEMO.ANALYTICS;

----------------------------------------------------------------------
-- 0. Grants. Cortex Analyst / the agent resolve the semantic view under the
--    querying role, so that role needs to reach the underlying objects.
--    PUBLIC is used here for demo convenience -- scope this properly in
--    any real deployment.
----------------------------------------------------------------------
GRANT USAGE  ON DATABASE TRADE_ANOMALY_DEMO                      TO ROLE PUBLIC;
GRANT USAGE  ON SCHEMA   TRADE_ANOMALY_DEMO.ANALYTICS            TO ROLE PUBLIC;
GRANT SELECT ON ALL TABLES         IN SCHEMA TRADE_ANOMALY_DEMO.ANALYTICS TO ROLE PUBLIC;
GRANT SELECT ON ALL VIEWS          IN SCHEMA TRADE_ANOMALY_DEMO.ANALYTICS TO ROLE PUBLIC;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA TRADE_ANOMALY_DEMO.ANALYTICS TO ROLE PUBLIC;

----------------------------------------------------------------------
-- 1. Semantic view.
--
-- Synonyms matter more than they look: they are how "which instrument",
-- "what symbol", and "which market" all resolve to TRADING_PAIR. Without
-- them the agent answers confidently and wrongly on phrasing it has not seen.
----------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW ORDER_EXECUTION_ANALYTICS
TABLES (
    FILL_RATE AS TRADE_ANOMALY_DEMO.ANALYTICS.ORDER_FILL_RATE_5MIN
        PRIMARY KEY (BUCKET_TS)
        WITH SYNONYMS ('fill rate', 'execution rate', 'order health', 'failure rate over time')
        COMMENT = 'Order fill-failure rate in 5-minute buckets across all trading pairs',
    FILL_RATE_BY_PAIR AS TRADE_ANOMALY_DEMO.ANALYTICS.ORDER_FILL_RATE_5MIN_BY_PAIR
        PRIMARY KEY (BUCKET_TS, TRADING_PAIR)
        WITH SYNONYMS ('fill rate by pair', 'failure rate by instrument', 'per pair execution')
        COMMENT = 'Order fill-failure rate in 5-minute buckets broken out by trading pair',
    ANOMALIES AS TRADE_ANOMALY_DEMO.ANALYTICS.ANOMALY_EVENTS
        PRIMARY KEY (BUCKET_TS)
        WITH SYNONYMS ('anomalies', 'incidents', 'alerts', 'flagged buckets', 'detections')
        COMMENT = 'Buckets flagged as anomalous by the anomaly detection model, with the worst-offending trading pair'
)
RELATIONSHIPS (
    PAIR_TO_OVERALL    AS FILL_RATE_BY_PAIR (BUCKET_TS) REFERENCES FILL_RATE,
    ANOMALY_TO_OVERALL AS ANOMALIES         (BUCKET_TS) REFERENCES FILL_RATE
)
FACTS (
    FILL_RATE.TOTAL_ORDERS          AS TOTAL_ORDERS   COMMENT = 'Orders submitted in the bucket',
    FILL_RATE.FAILED_ORDERS         AS FAILED_ORDERS  COMMENT = 'Orders that did not fill in the bucket',
    FILL_RATE.FILLED_ORDERS         AS FILLED_ORDERS  COMMENT = 'Orders that executed in the bucket',
    FILL_RATE.BUCKET_FAIL_RATE_PCT  AS FAIL_RATE_PCT  COMMENT = 'Percent of orders that failed to fill in the bucket',
    FILL_RATE_BY_PAIR.TOTAL_ORDERS        AS TOTAL_ORDERS  COMMENT = 'Orders submitted for this pair in the bucket',
    FILL_RATE_BY_PAIR.FAILED_ORDERS       AS FAILED_ORDERS COMMENT = 'Orders for this pair that did not fill',
    FILL_RATE_BY_PAIR.FILLED_ORDERS       AS FILLED_ORDERS COMMENT = 'Orders for this pair that executed',
    FILL_RATE_BY_PAIR.PAIR_FAIL_RATE_PCT  AS FAIL_RATE_PCT COMMENT = 'Percent of this pair''s orders that failed to fill',
    ANOMALIES.ACTUAL_FAIL_RATE_PCT   AS ACTUAL_FAIL_RATE_PCT   COMMENT = 'Observed failure rate in the flagged bucket',
    ANOMALIES.EXPECTED_FAIL_RATE_PCT AS EXPECTED_FAIL_RATE_PCT COMMENT = 'Failure rate the model expected for that bucket',
    ANOMALIES.UPPER_BOUND_PCT        AS UPPER_BOUND_PCT        COMMENT = 'Upper edge of the normal range the model predicted',
    ANOMALIES.DISTANCE               AS DISTANCE               COMMENT = 'How far outside normal the bucket was, in standard deviations',
    ANOMALIES.TOP_PAIR_FAIL_RATE_PCT AS TOP_PAIR_FAIL_RATE_PCT COMMENT = 'Failure rate of the worst pair in the flagged bucket',
    ANOMALIES.TOP_PAIR_FAILED_ORDERS AS TOP_PAIR_FAILED_ORDERS COMMENT = 'Failed order count for the worst pair'
)
DIMENSIONS (
    FILL_RATE.BUCKET_TS AS BUCKET_TS
        WITH SYNONYMS ('time', 'bucket', 'interval', 'when', 'timestamp')
        COMMENT = 'Start of the 5-minute measurement window',
    FILL_RATE_BY_PAIR.TRADING_PAIR AS TRADING_PAIR
        WITH SYNONYMS ('pair', 'instrument', 'symbol', 'market', 'ticker')
        COMMENT = 'Trading pair the orders were placed against',
    FILL_RATE_BY_PAIR.PAIR_BUCKET_TS AS BUCKET_TS
        WITH SYNONYMS ('time', 'bucket')
        COMMENT = 'Start of the 5-minute measurement window for this pair',
    ANOMALIES.ANOMALY_BUCKET_TS AS BUCKET_TS
        WITH SYNONYMS ('anomaly time', 'when it fired', 'incident time')
        COMMENT = 'Bucket that was flagged as anomalous',
    ANOMALIES.TOP_PAIR AS TOP_PAIR
        WITH SYNONYMS ('worst pair', 'driving pair', 'culprit', 'offending instrument')
        COMMENT = 'Trading pair with the highest failure rate in the flagged bucket',
    ANOMALIES.NOTIFIED AS NOTIFIED
        WITH SYNONYMS ('alerted', 'paged', 'notification sent')
        COMMENT = 'Whether an alert notification has already been sent for this anomaly',
    ANOMALIES.DETECTED_AT AS DETECTED_AT
        WITH SYNONYMS ('detection time', 'caught at')
        COMMENT = 'When the scoring run flagged the bucket'
)
METRICS (
    FILL_RATE.ORDERS   AS SUM(FILL_RATE.TOTAL_ORDERS)  COMMENT = 'Total orders submitted',
    FILL_RATE.FAILURES AS SUM(FILL_RATE.FAILED_ORDERS) COMMENT = 'Total orders that failed to fill',
    FILL_RATE.OVERALL_FAIL_RATE_PCT
        AS 100.0 * SUM(FILL_RATE.FAILED_ORDERS) / NULLIF(SUM(FILL_RATE.TOTAL_ORDERS), 0)
        COMMENT = 'Percent of all orders that failed to fill across the selected period',
    FILL_RATE.WORST_BUCKET_FAIL_RATE_PCT AS MAX(FILL_RATE.BUCKET_FAIL_RATE_PCT)
        COMMENT = 'Highest single-bucket failure rate in the period',
    FILL_RATE_BY_PAIR.PAIR_ORDERS   AS SUM(FILL_RATE_BY_PAIR.TOTAL_ORDERS)  COMMENT = 'Orders submitted for the pair',
    FILL_RATE_BY_PAIR.PAIR_FAILURES AS SUM(FILL_RATE_BY_PAIR.FAILED_ORDERS) COMMENT = 'Orders that failed to fill for the pair',
    FILL_RATE_BY_PAIR.PAIR_OVERALL_FAIL_RATE_PCT
        AS 100.0 * SUM(FILL_RATE_BY_PAIR.FAILED_ORDERS) / NULLIF(SUM(FILL_RATE_BY_PAIR.TOTAL_ORDERS), 0)
        COMMENT = 'Percent of the pair''s orders that failed to fill',
    ANOMALIES.ANOMALY_COUNT AS COUNT(ANOMALIES.ANOMALY_BUCKET_TS)
        COMMENT = 'Number of buckets flagged as anomalous',
    ANOMALIES.WORST_ANOMALY_FAIL_RATE_PCT AS MAX(ANOMALIES.ACTUAL_FAIL_RATE_PCT)
        COMMENT = 'Highest failure rate among flagged buckets',
    ANOMALIES.MAX_SEVERITY AS MAX(ANOMALIES.DISTANCE)
        COMMENT = 'Largest deviation from normal, in standard deviations'
)
COMMENT = 'Order execution health: fill vs no-fill rates over time and by trading pair, plus buckets the anomaly detection model flagged as abnormal.';

----------------------------------------------------------------------
-- 2. Smoke-test the semantic view before pointing an agent at it. If these
--    return nothing sensible, the agent will not either.
----------------------------------------------------------------------
SELECT * FROM SEMANTIC_VIEW(
    ORDER_EXECUTION_ANALYTICS
    METRICS ANOMALIES.ANOMALY_COUNT, ANOMALIES.WORST_ANOMALY_FAIL_RATE_PCT, ANOMALIES.MAX_SEVERITY
    DIMENSIONS ANOMALIES.TOP_PAIR
);

SELECT * FROM SEMANTIC_VIEW(
    ORDER_EXECUTION_ANALYTICS
    METRICS FILL_RATE_BY_PAIR.PAIR_ORDERS, FILL_RATE_BY_PAIR.PAIR_OVERALL_FAIL_RATE_PCT
    DIMENSIONS FILL_RATE_BY_PAIR.TRADING_PAIR
)
ORDER BY PAIR_OVERALL_FAIL_RATE_PCT DESC;

----------------------------------------------------------------------
-- 3. Agent. The instructions carry the domain nuance that makes answers
--    useful: a ~5% failure baseline is normal and benign, so the agent
--    should not treat routine no-fills as problems, and every anomaly
--    answer should name the pair and the severity.
--
-- GOTCHA: tool_resources needs an execution_environment with a warehouse.
-- Without it the agent is created successfully but every question returns
-- an empty response, with no error explaining why.
--
-- GOTCHA: CREATE OR REPLACE AGENT drops existing grants -- re-run the
-- GRANT below after any replace.
----------------------------------------------------------------------
CREATE OR REPLACE AGENT ORDER_EXECUTION_AGENT
WITH PROFILE = '{"display_name": "Order Execution Analyst"}'
COMMENT = 'Answers natural-language questions about order execution health and detected fill-failure anomalies.'
FROM SPECIFICATION $$
models:
  orchestration: auto
instructions:
  response: |
    You help trading operations and engineering staff investigate order execution problems.
    Be concise and lead with the number that answers the question.
    Failure rates are percentages of submitted orders that did not fill.
    A small baseline of failed orders is normal and expected - roughly 5 percent - and is
    usually benign, for example no counterparty being available. What matters is the failure
    rate rising above its learned baseline, which is what the anomaly detection model flags.
    When you report an anomaly, always name the trading pair driving it and how far outside
    normal it was in standard deviations, since that is what tells an engineer where to look.
  orchestration: |
    Use the order_execution_analytics tool for all questions about orders, fill rates,
    failure rates, trading pairs, anomalies, and incidents.
    Prefer the anomaly tables when the user asks what fired, what was flagged, or what
    happened recently. Prefer the per-pair data when the user asks which pair or instrument
    is responsible.
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: order_execution_analytics
      description: |
        Order execution health data: order counts and fill-failure rates in 5-minute buckets,
        overall and broken out by trading pair, plus buckets flagged as anomalous by the
        anomaly detection model with the worst-offending pair and severity.
tool_resources:
  order_execution_analytics:
    execution_environment:
      type: warehouse
      warehouse: COMPUTE_WH
    semantic_view: TRADE_ANOMALY_DEMO.ANALYTICS.ORDER_EXECUTION_ANALYTICS
$$;

GRANT USAGE ON AGENT ORDER_EXECUTION_AGENT TO ROLE PUBLIC;

----------------------------------------------------------------------
-- Questions worth asking the agent in CoWork:
--   "How many anomalies were detected and which pair was driving them?"
--   "What was the fill failure rate by trading pair?"
--   "Which trading pair has the worst execution quality?"
--   "How far outside normal was the worst incident?"
--   "What was the highest failure rate we saw in any 5 minute window?"
----------------------------------------------------------------------
