# Loss Run Document Review

Extract loss runs with Snowflake Cortex AI, flag what needs a human, and review it side by side with the source page. Everything runs inside Snowflake.

## What it does

1. **Parse** each PDF with `AI_PARSE_DOCUMENT` (LAYOUT mode, page split) into one row per page.
2. **Classify** every page with `AI_CLASSIFY`, because one PDF is often several documents merged together.
3. **Extract** with `AI_EXTRACT`:
   - Header fields (insured, carrier, policy, valuation date, claim count, totals) as entities with `scores => TRUE`, which gives one 0–1 confidence score per field.
   - Claim lines as a table from the file, which keeps the layout. Table extraction returns one aggregate score for the whole table.
4. **Check** each claim line with deterministic rules (merged amount cells, missing claim number or loss date, printed incurred not equal to paid + reserve + expense) and map it to the page where its claim number appears.
5. **Gate** each document: low table score, low-confidence header fields, flagged lines, or line totals that don't tie to printed totals send it to review.
6. **Review** in a Streamlit-in-Snowflake app: rendered source page on the left, extracted values on the right, corrections and approve/reject written back to tables.
7. **Ask** a Cortex Agent questions over the corrected data. Answers cite document and page.

## Files

| File | Purpose |
| --- | --- |
| `sql/01_foundation.sql` | Database, schema, warehouse, encrypted stage |
| `sql/02_parse.sql` | `AI_PARSE_DOCUMENT` into `PARSED_DOCUMENTS` and `DOCUMENT_PAGES` |
| `sql/03_classify.sql` | Per-page `AI_CLASSIFY` and document type |
| `sql/04_extract.sql` | Header and claim-line `AI_EXTRACT` with scores, page mapping |
| `sql/05_checks.sql` | Corrections tables, row flags, document gate |
| `sql/06_semantic_view.sql` | Semantic view for Cortex Analyst |
| `sql/07_agent.sql` | Cortex Agent in `SNOWFLAKE_INTELLIGENCE.AGENTS` |
| `app/` | Streamlit-in-Snowflake review app |

## Setup

1. Run `sql/01_foundation.sql`.
2. Upload your PDFs and refresh the stage:
   ```sql
   PUT file:///path/to/loss_runs/*.pdf @LOSS_RUN_DEMO.PIPELINE.DOCS AUTO_COMPRESS=FALSE;
   ALTER STAGE LOSS_RUN_DEMO.PIPELINE.DOCS REFRESH;
   ```
3. Run `sql/02` through `sql/07` in order.
4. Deploy the app: `cd app && snow streamlit deploy --replace`. It runs on the container runtime, so attach the PyPI mirror once to install `pypdfium2` for page rendering:
   ```sql
   ALTER STREAMLIT LOSS_RUN_DEMO.PIPELINE.LOSS_RUN_REVIEW
     SET ARTIFACT_REPOSITORIES = (snowflake.snowpark.pypi_shared_repository);
   ```
5. If your account has a Snowflake CoWork object, add the agent to it so it shows in the picker:
   ```sql
   ALTER SNOWFLAKE INTELLIGENCE <your_object> ADD AGENT SNOWFLAKE_INTELLIGENCE.AGENTS.LOSS_RUN_ANALYST;
   ```

Requires the `SNOWFLAKE.CORTEX_USER` database role. Cross-region inference raises the `AI_EXTRACT` page limit from 125 to 1,000.

## Notes from testing

- **Scores are useful.** In testing, the lowest-scoring header fields were the ones that were actually wrong (for example a policy period that merged two policies, and a total incurred that the model computed rather than read).
- **Extract tables from the file, not parsed text.** Text-mode table extraction scrambled columns on a multi-claim page; file mode was correct.
- **The table score alone is not enough.** A text-mode table scored 0.78 with every amount missing. The row checks catch what the aggregate score misses.
- **Bounding boxes:** `AI_PARSE_DOCUMENT` returns coordinates for embedded images only, not text. This demo links each value to its page instead.
- **Long tables:** table extraction output is capped at 4,096 tokens. Very long loss runs can truncate; the claim-count check flags that.
- **Carrier status text varies** ("CLSD", "CWP", "CLOSED 04/18/22"), so the view adds a normalized `STATUS_GROUP`.

## Thresholds

Header fields below 0.7 and tables below 0.6 go to review. Change them in `sql/05_checks.sql`.
