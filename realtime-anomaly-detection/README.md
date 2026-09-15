# Real-Time Anomaly Detection on Snowflake

Detect when a failure rate goes abnormal and page someone about it — in near real time, entirely inside Snowflake, with no external tooling.

The worked example is order-execution monitoring: orders either fill or they don't, and you want to know within minutes when failures spike beyond what's normal. The pattern generalises to any high-volume event stream with a success/failure signal — payment authorisations, API error rates, delivery exceptions, job completions, sensor readings.

## The problem this solves

The naive version of this is a threshold rule: *alert when the failure rate goes above 5%.* That breaks in both directions.

- **It cries wolf.** A routine, well-understood bump — end of day, market open, a nightly batch — crosses the line and pages someone at 3am for nothing. People mute the channel within a week.
- **It misses real problems.** A rate that quietly doubles from 2% to 4% never trips a 5% threshold, even though something clearly broke.

The distinction that matters is not *high or low* but **expected or unexpected**. A 12% failure rate can be perfectly normal at one time of day and a serious incident at another. That is what anomaly detection gives you: a model that learns the shape of your normal — level, trend, time-of-day seasonality — and flags deviation from it.

Equally important: **a baseline of failures is usually normal and not actionable.** In order execution, most no-fills are benign (no counterparty available). Alerting per failed event would be pure noise. The signal is the *rate* breaking from its own baseline, which is what indicates a systemic problem on your side — a routing bug, a bad deploy, a degraded venue.

## Architecture

```
   Raw events                Aggregation              Detection            Response
 ┌─────────────┐         ┌──────────────────┐     ┌───────────────┐    ┌──────────────┐
 │   ORDERS    │  ────►  │  Dynamic Table   │ ──► │  ANOMALY_     │──► │    TASK      │
 │             │         │  fail rate per   │     │  DETECTION    │    │  every 1 min │
 │ order_id    │         │  5-min bucket    │     │               │    │  scores +    │
 │ order_ts    │         │                  │     │  forecast vs  │    │  records     │
 │ pair        │         │  TARGET_LAG=1min │     │  actual       │    └──────┬───────┘
 │ is_filled   │         │  auto-refreshes  │     │               │           │
 └─────────────┘         └──────────────────┘     └───────────────┘           ▼
                                  │                                    ┌──────────────┐
                                  │                                    │ANOMALY_EVENTS│
                                  │                                    └──────┬───────┘
                                  │                                           │
                                  ▼                                           ▼
                         ┌──────────────────┐                          ┌──────────────┐
                         │  Semantic View   │                          │    ALERT     │
                         │       +          │  ◄───────────────────    │  notifies    │
                         │  Cortex Agent    │   "which pair caused     │  once per    │
                         │  ask in English  │    the 2pm spike?"       │  incident    │
                         └──────────────────┘                          └──────┬───────┘
                                                                              ▼
                                                                     email / Slack /
                                                                        PagerDuty
```

Why each piece is there:

| Component | Role | Why not something else |
|---|---|---|
| **Dynamic Table** | Turns raw events into a rolling rate, refreshing as data lands | No scheduler, no batch job, no orchestration to maintain. Set `TARGET_LAG` and it keeps itself current |
| **`SNOWFLAKE.ML.ANOMALY_DETECTION`** | Learns normal, flags deviation | Needs **no labelled training data** — critical when you've never catalogued past incidents. A fixed threshold can't learn seasonality |
| **Task** | Scores on a schedule, records findings | Separating detection from notification means each incident pages exactly once |
| **Alert** | Pushes the notification | This is the deliverable. A dashboard tells you what happened; an alert tells you *now* |
| **Semantic View + Cortex Agent** | Natural-language follow-up | After the page lands, "which instrument drove it?" is answerable without SQL, by people who don't write SQL |

## What the detection actually does

The model does **not** compare against a fixed number. It forecasts what the value should have been for each specific timestamp, then compares the actual value to that forecast and its prediction interval.

Concretely, from a real run in this demo:

| Bucket | Actual | Model expected | Normal upper bound | Flagged? | Deviation |
|---|---|---|---|---|---|
| 23:55 | 7.0% | 5.5% | 12.7% | no | 0.5σ |
| 00:00 | 6.0% | 5.3% | 12.5% | no | 0.3σ |
| **00:05** | **54.25%** | **4.7%** | **11.9%** | **yes** | **17.7σ** |

Note the upper bound moves between buckets — it's derived per timestamp from learned patterns, not a constant. That's the whole point.

Two properties worth knowing:

- **Multi-series** — pass a `SERIES_COLNAME` and one model tracks each series independently (per trading pair, per region, per endpoint), each with its own baseline.
- **Optional labels** — if you *do* have a history of known past incidents, supply a `LABEL_COLNAME` to improve accuracy. It works without one.

## Files

Run in order.

| File | What it does |
|---|---|
| [`01_setup_data.sql`](01_setup_data.sql) | Scratch database, warehouse, and 14 days of synthetic order events (~403k rows) with realistic per-pair failure baselines and a time-of-day pattern |
| [`02_anomaly_detection.sql`](02_anomaly_detection.sql) | Dynamic Tables for the rolling rate, training/scoring split, and the anomaly detection model |
| [`03_simulate_and_inject.sql`](03_simulate_and_inject.sql) | Demo drivers: backfill to keep the series current, then inject a detectable incident |
| [`04_alerting.sql`](04_alerting.sql) | Notification integration, anomaly ledger, scoring task, and the alert |
| [`05_semantic_view_agent.sql`](05_semantic_view_agent.sql) | Semantic view and Cortex Agent for natural-language questions |

## Quickstart

```sql
-- 1. Environment and data (~1 min)
--    Run 01_setup_data.sql
--    Sanity check: overall failure rate should land near 5.5%

-- 2. Aggregation and model (~2 min; model training is the slow part)
--    Run 02_anomaly_detection.sql
--    IMPORTANT: the final scoring call should return IS_ANOMALY = FALSE for
--    every row. If anything is flagged on normal traffic, stop and fix that
--    before continuing -- you have false positives, not a working detector.

-- 3. Alerting
--    Edit 04_alerting.sql: replace you@example.com with a verified account email
--    Run 04_alerting.sql

-- 4. Natural language layer
--    Run 05_semantic_view_agent.sql
--    Smoke-test the SEMANTIC_VIEW() queries before trusting the agent

-- 5. Trigger an incident
--    Run STEP 1 then STEP 2 of 03_simulate_and_inject.sql
--    Within ~2-3 minutes: Dynamic Table refreshes -> task scores -> alert fires
```

Then ask the agent something like:

- *How many anomalies were detected, and which trading pair was driving them?*
- *Which trading pair has the worst execution quality?*
- *How far outside normal was the worst incident?*

## Design decisions and gotchas

Things that cost time to work out, collected here so they don't have to be rediscovered.

**Bucket width is a statistical decision, not a latency one.** The instinct is per-minute buckets for "real time". At ~20 events/minute a per-minute failure rate has a standard deviation roughly as large as its own mean — the metric is almost pure noise and anomaly detection on it is meaningless. 5-minute buckets give ~100 events per point and a stable signal, while still detecting within minutes. **Pick the narrowest bucket that still contains enough events to make the rate stable** (a few hundred is comfortable), rather than the narrowest bucket you can technically build.

**`DETECT_ANOMALIES` requires evaluation timestamps strictly after the training window.** Training on the full history leaves nothing scoreable and fails with `All evaluation timestamps must be after the last timestamp in fitting data`. Hold back a scoring window — here, training stops one hour before the latest bucket.

**Don't score the current, still-filling bucket.** It contains a partial count and will look anomalous for no reason. Both the training and scoring views exclude the newest bucket. The corollary: when injecting a synthetic incident for a demo, target the last *complete* bucket, or you'll create an anomaly the model never scores.

**Separate detection from notification.** The task records findings; the alert notifies on unnotified rows and marks them sent. Collapsing these into one object means either re-paging every cycle while the condition persists, or writing dedupe logic by hand.

**`tool_resources` needs an `execution_environment`.** Without it, the agent is created successfully and every question returns an empty response with no error explaining why:

```yaml
tool_resources:
  <tool_name>:
    execution_environment:
      type: warehouse
      warehouse: <WAREHOUSE>
    semantic_view: <DATABASE>.<SCHEMA>.<SEMANTIC_VIEW>
```

**`CREATE OR REPLACE AGENT` drops existing grants.** Re-run your `GRANT USAGE ON AGENT` after every replace.

**Cortex Analyst resolves the semantic view as the querying role.** That role needs `USAGE` on the database and schema plus `SELECT` on the underlying tables, views, *and* dynamic tables — dynamic tables are a separate `GRANT ... ON ALL DYNAMIC TABLES` and are easy to miss.

**Synonyms are load-bearing.** They're how "which instrument", "what symbol", and "which market" all reach `TRADING_PAIR`. Without them the agent answers confidently and wrongly on phrasing it hasn't seen.

**`LISTAGG` needs a literal delimiter.** `CHR(10) || CHR(10)` fails to compile with `argument 1 to function LISTAGG needs to be constant`. Use `'\n\n'`.

**Model training wants a quiet warehouse.** Snowflake recommends a dedicated warehouse with no concurrent workload for training. Inference is cheap and roughly warehouse-size-independent (~1 second per 100 rows).

## Cost

Measured on an X-Small, this pattern splits into two very different cost profiles.

**Dynamic Table polling is nearly free when nothing changes.** At `TARGET_LAG = '1 minute'` the table checks for source changes and, finding none, logs a `NO_DATA` refresh — a metadata-only operation that never touches the warehouse. Measured over an idle period: `0.0000` compute credits per hour, roughly `0.015` cloud-services credits per hour. Cost scales with actual data change, not with how often you poll.

**The task and alert are the expensive part, and the reason is `AUTO_SUSPEND` — not the cadence itself.** Measured with a 1-minute task (each run ~17s) plus a 1-minute alert: **0.92 compute credits in a single hour**, i.e. effectively 100% warehouse uptime.

This is the trap: **if your recurring schedule is shorter than the warehouse `AUTO_SUSPEND` window, the warehouse never suspends and you pay for continuous uptime no matter how trivial each run is.** A warehouse left at the common `AUTO_SUSPEND = 600` (10 minutes) will stay hot for a 1-minute *or* a 5-minute schedule alike — the cadence change saves nothing on its own.

To actually reduce cost you must change both together:

```sql
-- Longer gap between runs AND a suspend window short enough to fit inside it
ALTER TASK T_SCORE_FILL_RATE_ANOMALIES SET SCHEDULE = '5 MINUTE';
ALTER WAREHOUSE <WAREHOUSE> SET AUTO_SUSPEND = 60;
```

Note that per-resume billing has a 60-second minimum, so a 17-second scoring run bills a full minute. At a 5-minute cadence with `AUTO_SUSPEND = 60` you pay roughly 12 minutes per hour instead of 60 — a genuine ~5x reduction, but only because the warehouse now actually sleeps.

**Suspend everything when you're done:**

```sql
ALTER TASK  T_SCORE_FILL_RATE_ANOMALIES SUSPEND;
ALTER ALERT A_FILL_RATE_ANOMALY          SUSPEND;
-- Dynamic Tables keep polling until explicitly suspended:
ALTER DYNAMIC TABLE ORDER_FILL_RATE_5MIN         SUSPEND;
ALTER DYNAMIC TABLE ORDER_FILL_RATE_5MIN_BY_PAIR SUSPEND;
```

Sizing the decision: continuous X-Small uptime is ~24 credits/day. Match the cadence to how fast the team genuinely needs to know, and make it an explicit trade against the cost of an undetected incident rather than defaulting to the fastest possible schedule.

## Routing alerts somewhere other than email

Email is used here because it needs no external approval and works immediately. The notification target is the only thing that changes — detection logic is untouched:

1. Create a webhook-type `NOTIFICATION INTEGRATION` pointing at Slack / PagerDuty / Opsgenie.
2. Point the notification call in `SP_NOTIFY_ANOMALIES` at that integration.

Note that enterprise-managed Slack workspaces frequently disable both app installs and legacy incoming webhooks, so this may require an IT request. Email is a reasonable stand-in until then.

## Extending this

- **Explain *why*, not just *that*.** This detects that a rate went abnormal. Explaining the cause needs failure reason codes, which often live in a logging or observability platform rather than the warehouse. Once piped in, a classification model can label each failure by likely cause, and `AI_COMPLETE` can generate readable explanations where no clean code exists.
- **Per-series detection.** Add `SERIES_COLNAME` to track each pair, region, or endpoint against its own baseline — catches a single degraded series that the blended rate hides.
- **Retraining.** The model here is trained once. In production, retrain periodically (an hourly or daily task) so the baseline follows genuine changes in traffic.
- **Suppression windows.** If known maintenance reliably produces spikes, either label those periods during training or suppress alerts across those windows.
