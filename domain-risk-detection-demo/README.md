# Domain Risk Detection Demo

An end-to-end example of building a domain-abuse (bad actor) detection pipeline entirely on Snowflake — from synthetic data generation through feature engineering, model training, scoring, and a Streamlit UI for analysts.

## What's included

| Path | Description |
|---|---|
| `sql/01_create_schema_and_data.sql` | Creates the database/schema and generates ~10,000 synthetic domain registrations (legitimate, suspicious, edge cases) |
| `sql/02_feature_engineering.sql` | Builds a view computing 19 domain-risk features (brand keyword presence, leetspeak substitution, WHOIS privacy, bulk-registrant flags, high-risk country, etc.) |
| `python/setup_feature_store.py` | Registers an Entity + FeatureView in the Snowflake Feature Store (backed by a Dynamic Table) |
| `sql/03_feature_store.sql` | Verifies the Feature Store objects and builds the joined training dataset |
| `sql/04_train_model.sql` | Trains a no-code `SNOWFLAKE.ML.CLASSIFICATION` model and shows evaluation metrics / feature importance |
| `python/train_and_register.py` | Trains a `GradientBoostingClassifier` (sklearn) and registers it in the Snowflake Model Registry with metrics |
| `sql/05_scoring_pipeline.sql` | Creates a Dynamic Table that continuously scores registrations (1-hour target lag) and tiers them into HIGH/MEDIUM/LOW risk, plus optional `SNOWFLAKE.CORTEX.COMPLETE` narrative enrichment |
| `streamlit/app.py` | Streamlit-in-Snowflake app with 4 tabs: Flagged Domains, Domain Lookup (with live Cortex AI risk assessment), Live Scoring, and Model Performance |

## Setup

1. Update the database/schema/warehouse names in each script if you want something other than `DOMAIN_RISK_DEMO.BAD_DOMAIN_ML` / `COMPUTE_WH`.
2. Run the SQL scripts in order: `01` → `02` → (Python: `setup_feature_store.py`) → `03` → `04` → (Python: `train_and_register.py`) → `05`.
3. Deploy `streamlit/app.py` as a Streamlit-in-Snowflake app pointed at the same database/schema.

## Adapting to real data

Swap `RAW_REGISTRATIONS` (currently synthetic) for your actual domain registration table, keeping the same column names used by `02_feature_engineering.sql`, or adjust the feature SQL to match your schema. Everything downstream (feature store, training, scoring, app) will work unchanged.
