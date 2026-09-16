# Snowflake Cortex Workshop: From Call Transcript to Scored Lead

A hands-on walkthrough that takes unstructured mortgage call transcripts and
turns them into a governed, scored, agent-queryable lead pipeline — entirely
inside Snowflake.

The scenario is refinance retention for a mortgage lender: borrowers call in,
the calls are transcribed, and the business wants to know which of those callers
are the best refinance candidates and how likely each one is to convert.

All data is synthetic. There are no real borrowers, balances, rates, or PII.

---

## What gets built

| Layer | Objects | Purpose |
|---|---|---|
| Raw data | `HOMEOWNERS`, `PROPERTIES`, `LOANS`, `CALL_TRANSCRIPTS`, `HISTORICAL_REFI_OUTCOMES` | Synthetic loan book and 120 inbound call transcripts |
| AI extraction | `CALL_SIGNALS`, `CONSULTATION_SUMMARIES`, `AGENT_DAILY_THEMES` | Structured fields, intent, and summaries pulled from transcript text |
| Semantic layer | `BORROWER_PROFILE`, `BORROWER_SCORED`, `REFI_INTELLIGENCE` | Refinance economics, the segment definition, and the governed model |
| Scoring | `SCORE_REFI_PROPENSITY`, `GET_REFI_PROPENSITY`, `TRAIN_REFI_PROPENSITY_MODEL` | Snowpark model, trained and served in-database |
| Agent | `REFI_INTELLIGENCE_AGENT` | Natural language access across both |

Snowflake features covered: `AI_EXTRACT`, `AI_CLASSIFY`, `AI_COMPLETE`,
`AI_SUMMARIZE_AGG`, `AI_COUNT_TOKENS`, semantic views, verified queries, Snowpark
Python procedures and UDFs, and Cortex Agents with a custom tool.

---

## The flow

```
CALL_TRANSCRIPTS
      |
      |  AI_EXTRACT      -> name, city, rate, life event, urgency, competitor
      |  AI_CLASSIFY     -> call intent
      |  AI_COMPLETE     -> per-call summary, long-call chunk and stitch
      v
  CALL_SIGNALS ------------------+
                                |
  HOMEOWNERS / LOANS /          |  joined on homeowner
  PROPERTIES  ------------------+
                                v
                        BORROWER_PROFILE
                        (refinance economics,
                         top segment definition)
                                |
                                |  SCORE_REFI_PROPENSITY (Snowpark UDF)
                                v
                        BORROWER_SCORED
                                |
                                v
                    REFI_INTELLIGENCE (semantic view
                    + verified queries)
                                |
                    +-----------+-----------+
                    |                       |
          Cortex Analyst tool      GET_REFI_PROPENSITY
          (populations, lists,     (one named borrower,
           rankings, totals)        explained)
                    |                       |
                    +-----------+-----------+
                                v
                    REFI_INTELLIGENCE_AGENT
```

---

## Prerequisites

- A Snowflake account in a region with Cortex AI functions available
- `ACCOUNTADMIN`, or a role with `CREATE DATABASE`, `CREATE WAREHOUSE`, and
  `CREATE AGENT` on `SNOWFLAKE_INTELLIGENCE.AGENTS`
- Roughly 15 minutes of warehouse time on an XSMALL

Nothing else is needed to run this in your own account. There is no data to
load, no external dependency, and nothing tied to the account it was authored
in — `01_data.sql` generates the dataset deterministically, so you will see the
same figures quoted below.

`00_setup.sql` preflights the four things that can block a fresh account, so you
find out in the first minute rather than four files in:

| Check | If it fails |
|---|---|
| Cortex AI functions grant | `GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE <role>;` — needs ACCOUNTADMIN |
| Model reachable in your region | `ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';` — ACCOUNTADMIN, account level only |
| Anaconda Python packages | ORGADMIN accepts the terms once: Snowsight » Admin » Billing & Terms » Anaconda » Enable |
| `SNOWFLAKE_INTELLIGENCE.AGENTS` exists | Created by `00_setup.sql` itself |

**The one that most often bites:** Cortex AI functions are gated behind an
account-level grant. Without it, `AI_EXTRACT` fails with
`Unknown function AI_EXTRACT`, which reads like the function does not exist. It
does — the role just is not entitled.

```sql
GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE ACCOUNTADMIN;
```

---

## Running it

Run the files in order in a Snowsight worksheet. Every statement is
`CREATE OR REPLACE` or `IF NOT EXISTS`, so the whole set is safe to re-run.

| File | What it does | Time |
|---|---|---|
| `00_setup.sql` | AI functions grant, database, schema, warehouse, four preflight checks | < 1 min |
| `01_data.sql` | Synthetic loan book, 120 transcripts, 2,400 training records | < 1 min |
| `02_ai_functions.sql` | Extraction, classification, token sizing, summarisation, long-call chunking | 3–6 min |
| `03_semantic_view.sql` | Refinance economics, segment definition, semantic view | < 1 min |
| `04_scoring.sql` | Train the model, deploy the UDF, build the agent-facing procedure | 2–3 min |
| `05_agent.sql` | The agent and its two tools | < 1 min |
| `06_verified_query.sql` | Score into the semantic layer, verified queries | 1–2 min |

`02` and `04` are the slow steps. `02` runs three AI functions over 120
transcripts plus a chunked map-reduce pass; `04` trains a model and serialises it
to a stage.

Data generation is deterministic — values are derived from `ABS(HASH(...))` of
each row key rather than `RANDOM()` — so the figures below reproduce exactly on
every run and in every account.

---

## What you should see

After `02_ai_functions.sql`, all 120 calls classified across six intents with
100% rate capture:

| Call intent | Calls |
|---|---|
| `RATE_REFI` | 46 |
| `RELOCATION` | 24 |
| `PAYMENT_RELIEF` | 14 |
| `SERVICING_ONLY` | 12 |
| `TERM_SHORTEN` | 12 |
| `CASH_OUT` | 12 |

Token sizing for the corpus, from `AI_COUNT_TOKENS` before any inference runs:

| Pass | Input tokens | Per call |
|---|---|---|
| Summarisation (`ai_complete`) | 22,537 | ~188 |
| Classification (`ai_classify`) | 44,787 | ~373 |

Classification costs roughly double, because the label definitions travel with
every call. The label descriptions that fixed the intent split cost 494 tokens
per call against 362 for bare labels — 36% more, which is what bought the clean
six-way classification above.

Chunking is measured too, and the result cuts against the usual assumption:

| Approach | Calls | Input tokens |
|---|---|---|
| One pass | 5 | 6,213 |
| Chunked map-reduce | 25 | 7,376 (+18.7%) |

Chunking costs *more*, not less — each chunk re-pays the per-call overhead. You
chunk when the input will not fit, when you want to parallelise for latency, or
when you need per-section attribution. Not to reduce spend.

After `03_semantic_view.sql`, the segment funnel — each criterion doing real
work rather than one filter dominating:

```
400 borrowers
101  paying at least 1.0 point above market
 51  and LTV at or below 80%
 26  and GOOD or EXCELLENT credit
 25  and no late payment, balance at least $150k   <- top refinance segment
 23  of whom called in the last 7 days
```

After `04_scoring.sql`, holdout AUC around **0.86**, with `RATE_DELTA_PCT` the
largest positive coefficient and `SERVICING_ONLY` intent the largest negative.

After `06_verified_query.sql`, the segment and the model agreeing with each
other:

| Segment | Borrowers | Avg propensity | Total monthly saving |
|---|---|---|---|
| `TOP_REFI_SEGMENT` | 25 | 63.7% | $10,603 |
| `NOT_IN_SEGMENT` | 375 | 20.8% | -$61,581 |

Two things worth reading in that table. The three-fold gap in propensity is the
check that the segment definition is not arbitrary — if it were, propensity
inside it would look like propensity outside it. And the negative saving on
`NOT_IN_SEGMENT` is correct, not a bug: it is the below-market population, for
whom refinancing would increase the payment.

---

## Questions to ask the agent

**Population questions** route to the semantic view:

- Which homeowners from last week's calls match our top refinance segment?
- What is the total monthly savings available in the top refinance segment?
- How many inbound calls did we get last week, by call intent?
- Which borrowers mentioned a competing lender?
- Which borrowers in the top refinance segment have the highest propensity to refinance?

**Single-borrower questions** route to the Snowpark scoring procedure:

- What is the propensity score for Farrah Haddad?
- Why is her score that high?
- What is the score for Elena Whitfield?

**Reference answers**, so you can check the agent against the data:

- Highest propensity in the segment: **Elena Whitfield**, Bellevue WA, **90.7%**
- Largest monthly saving in the segment: **Elena Barrios**, Beaverton OR, **$822.11**
- Farrah Haddad, Cary NC: **87.0%**, $761.58/month, $251,320 lifetime

Ambiguity and misses are handled rather than thrown:

- `CALL GET_REFI_PROPENSITY('Elena');` returns the 11 candidates and asks you to narrow it
- `CALL GET_REFI_PROPENSITY('Jane Nonexistent');` returns a recoverable instruction

---

## Notes on design

**The segment definition lives in the semantic view, not in the prompt.**
`refi_segment` is a dimension whose comment states the full criteria. If the
criteria lived in the question text instead, every person asking would phrase
them slightly differently and get a slightly different population. Defining it
once means the segment means the same thing from Cortex Analyst, from a BI tool,
and from plain SQL.

**Classification labels carry descriptions.** With bare label names, 84 of 120
calls landed in `RATE_REFI` and `PAYMENT_RELIEF` was never returned — a borrower
saying "my partner went part time and the payment is the biggest problem in our
budget" is commercially different from one shopping a competitor quote, but the
label name `RATE_REFI` is broad enough to absorb both. Adding a one-line
description per label produced the clean six-way split above.

**Extraction output needs normalising.** Booleans come back with inconsistent
casing (`TRUE` / `True`), absent values come back as the string `'None'` rather
than SQL `NULL`, and numerics arrive as strings. Without handling, "how many
calls mentioned a life event" counts every call and `NONE` appears as a fourth
urgency level beside `HIGH`, `MEDIUM`, `LOW`.

**Borrower names are unique by construction.** Names are drawn from the ordered
cross product of first and last names rather than sampled per row. Sampling 400
names from 1,600 combinations produces around 50 duplicates, and a duplicated
name breaks any tool that resolves a borrower by name.

**Savings are computed honestly.** The payment comparison holds the remaining
term constant rather than resetting the borrower to a fresh 30-year term, which
would inflate the monthly saving considerably.

**Two tools, one clear boundary.** Ranking a group is a set operation and belongs
in the semantic layer. Explaining one borrower's score is a per-borrower
narrative and belongs in the procedure. Both read the same model, so the numbers
agree. The agent's orchestration instructions name the question shapes that
belong to each tool, because two tools that could both plausibly answer "tell me
about this borrower" will otherwise be confused with each other.

---

## Extending it

- **Retrain and watch it propagate.** `CALL TRAIN_REFI_PROPENSITY_MODEL();`
  overwrites the staged artifact. `BORROWER_SCORED` applies the UDF at query
  time, so every downstream answer moves with the new model — no rebuild step.
- **Move the market rate.** `MARKET_RATE` is a one-row view. Change 6.10 and the
  entire segment, every saving figure, and every propensity score shift with it.
- **Add Cortex Search over the transcripts** so the agent can quote what a
  borrower actually said, alongside the structured signals.
- **Make scoring a scheduled job.** If per-query inference ever gets expensive,
  `BORROWER_SCORED` becomes a table or a dynamic table. The semantic view above
  it does not change.

---

## Teardown

```sql
DROP AGENT IF EXISTS SNOWFLAKE_INTELLIGENCE.AGENTS.REFI_INTELLIGENCE_AGENT;
DROP DATABASE IF EXISTS CORTEX_REFI_DEMO;
DROP WAREHOUSE IF EXISTS CORTEX_DEMO_WH;
```

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Unknown function AI_EXTRACT` | Missing the AI functions grant. See `00_setup.sql` step 1. |
| `The model ... has been in legacy state` | Model alias retired. Substitute the current alias from the `AI_COMPLETE` docs. |
| `pandas is not installed` inside a procedure | `to_pandas()` needs the connector's pandas extra. Build the frame from `collect()` instead, as `04_scoring.sql` does. |
| `DATA_AGENT_RUN ... needs to be constant` | The payload must be a literal string. `PARSE_JSON()` and column references are rejected. |
| `AI_COUNT_TOKENS` returns NULL | Either the first argument is a model instead of a function name (it must be `'ai_complete'`, lowercase, `ai_` prefix), or the function is unsupported. Pass `return_error_details => TRUE` to see which. |
| Agent does not appear in the CoWork picker | It must live in `SNOWFLAKE_INTELLIGENCE.AGENTS` and have a `color` in its profile. |
| `Cannot create procedure ... packages not available` | Anaconda channel not enabled. ORGADMIN: Snowsight » Admin » Billing & Terms » Anaconda » Enable. |
| Model unavailable in your region | `ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';` (ACCOUNTADMIN, account level only). |
| Agent picks the wrong tool | Tighten `instructions.orchestration` — name the question shapes, do not just describe the tools. |
