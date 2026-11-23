# Serving Snowflake Data from Snowflake Postgres, and Mirroring It Back

Your app needs millisecond reads, so it reads from Postgres, not from analytical tables. That
leaves two sync jobs: Snowflake results out to Postgres, and app data (logs, events, operational
rows) back into Snowflake. This guide sets both up on **Snowflake Postgres**, so there's one
platform, one bill, and no external sync service to maintain.

```
Snowflake marts ── stream ──► SYNC_TO_POSTGRES (task, every 15 min, only changed rows) ──► Postgres "serving" schema ──► your app
                                                                                                  │
Snowflake  ◄── managed mirror (~30s via $live, new tables picked up automatically) ◄── Postgres "app" schema ◄── your app writes
```

## What this solves

| Problem | How |
|---|---|
| App reads are slow or burn warehouse credits | The app reads Postgres directly. Snowflake isn't in the request path, so there's no query compile step and no warehouse running for page loads. |
| Getting app data into Snowflake means a connector you reconfigure for every new table | A schema-level mirror copies every table in the `app` schema, including tables created later. Column changes flow through too. |
| Pushing Snowflake results out means diff queries to find what changed | A stream records exactly which rows changed since the last run. Only those rows move, and the task doesn't run when nothing changed. |
| Two vendors, two bills | The Postgres instance and both sync paths are billed through your Snowflake account. |

**Coming:** Snowflake-to-Postgres mirroring (the reverse of step 2) is in private preview. When
it's available to you, it can replace step 3. Ask your account team about early access.

**Tested end to end** on AWS: a 5,000-row initial load, then 100 updates and 1 delete moved as
exactly 100 upserts and 1 delete, with row counts and column totals matching on both sides. A
table created later in the `app` schema was mirrored, with its rows, about a minute later.

## Files

| File | Run where | What it does |
|---|---|---|
| [`sql/01_instance.sql`](sql/01_instance.sql) | Snowsight, as ACCOUNTADMIN | Network policy and the Postgres instance (skip if you have one) |
| [`sql/00_postgres_setup.sql`](sql/00_postgres_setup.sql) | Your Postgres database | `serving` and `app` schemas, an example table in each, a least-privilege `sync_writer` login |
| [`sql/02_mirror_postgres_to_snowflake.sql`](sql/02_mirror_postgres_to_snowflake.sql) | Snowsight, as ACCOUNTADMIN | Mirror of the `app` schema into Snowflake |
| [`sql/03_sync_snowflake_to_postgres.sql`](sql/03_sync_snowflake_to_postgres.sql) | Snowsight, as ACCOUNTADMIN | Stream, sync procedure and task that push Snowflake changes into `serving` |

## Before you start

- **Cloud and region.** Mirroring runs on AWS and Azure. The mirror must be in the same account,
  region and cloud as the Postgres instance
  ([docs](https://docs.snowflake.com/en/user-guide/snowflake-postgres/postgres-data-mirroring)).
- **Instance tier.** STANDARD or HIGH MEMORY. Mirroring doesn't support BURSTABLE.
- **Python packages.** The Anaconda terms must be accepted (Snowsight » Admin » Terms) for step 3.

Replace these placeholders in every file:

| Placeholder | Where to find it |
|---|---|
| `<PG_INSTANCE>` | The name you give the instance, or `SHOW POSTGRES INSTANCES;` → `name` |
| `<PG_HOST>` | `SHOW POSTGRES INSTANCES;` → `host` |

This should print nothing when you're done:
```bash
grep -rn "<PG_" sql/
```

## Setup

**1. Instance.** Run `sql/01_instance.sql`. Save the passwords from the `CREATE` output; they
can't be retrieved later. Wait for `state = READY`.

**2. Postgres schemas.** Connect with psql as `snowflake_admin` and run `sql/00_postgres_setup.sql`.
Choose the `sync_writer` password there.

**3. Mirror Postgres into Snowflake.** Run `sql/02_mirror_postgres_to_snowflake.sql`. When
`LIST_MIRRORED_TABLES` shows `REPLICATING`, insert a row in Postgres and read it from
`APP_MIRROR.APP.REQUEST_LOG$live` about 30 seconds later. Then create a new table in the `app`
schema and watch it appear without changing the mirror.

**4. Sync Snowflake into Postgres.** Run `sql/03_sync_snowflake_to_postgres.sql` one statement at
a time. Paste the `sync_writer` password into the `CREATE SECRET`, run it, then clear it from the
worksheet. Add the CIDRs that step 2 of the file prints to `PG_INGRESS_RULE`. The first
`CALL SYNC_TO_POSTGRES()` loads the full table, and the next one moves only what you changed.

**5. Add your own tables.** For each Snowflake table to serve:
1. Create the matching table in the Postgres `serving` schema, with the same column names and a primary key.
2. `CREATE STREAM <name> ON TABLE <your table> SHOW_INITIAL_ROWS = TRUE;`
3. Add a row to `SYNC_TABLES`, and add the stream to the task's `WHEN` clause.

## Check the speed

From your app's network, in psql:
```sql
\timing on
SELECT * FROM serving.site_daily_kpis WHERE site_id = 'S001' AND kpi_date = CURRENT_DATE;
```
Primary-key lookups run in well under a millisecond on the server. In testing on a STANDARD_M
instance, `EXPLAIN ANALYZE` showed 0.055 ms execution, and the full round trip from a laptop
over the internet was about 42 ms, almost all of it network. Index the
columns your app filters on, as you would on any Postgres database. For app connections, use the
built-in PgBouncer pooler on port **5431** rather than opening a new connection per request.
`00_postgres_setup.sql` installs the `snowflake_pooler` extension it needs. Connect through it as
`application` or another non-superuser role; `snowflake_admin` can't use the pooler
([docs](https://docs.snowflake.com/en/user-guide/snowflake-postgres/postgres-connection-pooling)).

## Design choices

- **Streams, not diff queries.** A stream records inserts, updates and deletes since it was last
  read. The procedure copies them into `SYNC_BATCH` (which moves the stream forward), pushes them
  to Postgres in one transaction, and only then deletes them from `SYNC_BATCH`. A failed push is
  retried on the next run.
- **Upserts are idempotent** (`INSERT ... ON CONFLICT DO UPDATE` on the primary key), so a retried
  batch never creates duplicates.
- **Schema-level mirror on `app`, nothing else.** New tables in that schema are mirrored
  automatically. Keep tables you don't want in Snowflake in a different schema.
- **TLS verifies the instance's CA certificate** (equivalent to `sslmode=verify-ca`).

## What it costs

| Driver | How it's billed |
|---|---|
| Postgres instance | Compute by instance size, plus allocated storage |
| Mirror | Serverless apply task on each refresh interval, plus storage of the mirrored tables. A longer `refresh_interval` costs less; `$live` keeps reads fresh either way. |
| Sync task | Serverless task time, only when a stream has changes |

Both queries at the end of steps 02 and 03 show actual credits per task.

## Known gaps

- **A new instance's hostname can take several minutes to resolve on your machine**, even after
  `state = READY`, because your resolver caches the earlier "not found". If psql says it can't
  translate the host name, check with `dig +short @8.8.8.8 <PG_HOST>` and either wait or connect
  with `hostaddr=<that IP>` added to the connection string (the connection is still encrypted).
- **Tables rebuilt with `CREATE OR REPLACE` break their stream.** dbt `table` models do this on
  every run. Point the stream at an `incremental` model, or recreate the stream after each rebuild
  (it will then resend the whole table).
- **Snowflake's egress IP ranges expire.** Automate refreshing `PG_INGRESS_RULE`
  ([docs](https://docs.snowflake.com/en/user-guide/egress-ip/network-egress)).
- **Laptops behind a corporate proxy (e.g. Zscaler)** may not reach port 5432 with psql. The sync
  and mirror don't need laptop access; Snowflake connects directly.

## Clean up

```sql
ALTER TASK PG_SYNC.PIPELINE.SYNC_TO_POSTGRES_TASK SUSPEND;
CALL SNOWFLAKE.POSTGRES.DROP_MIRROR(mirror_name => 'APP_MIRROR', drop_target_database => TRUE);
DROP DATABASE PG_SYNC;
DROP INTEGRATION PG_SYNC_EAI;
DROP POSTGRES INSTANCE <PG_INSTANCE>;   -- only if you created it for this guide
```
