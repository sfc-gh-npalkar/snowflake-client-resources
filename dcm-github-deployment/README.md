# Deploy Snowflake Objects from GitHub with DCM Projects

Keep your Snowflake objects as files in your repo. You test changes in DEV from your laptop, pull requests show the PROD plan, and merges deploy PROD. GitHub logs in with a short-lived token, so no password or key is stored in GitHub.

## Files

| File | What it is |
|---|---|
| [`manifest.yml`](manifest.yml) | DEV and PROD targets: same definitions, different database |
| [`sources/definitions/`](sources/definitions/) | The objects: a table and a Python procedure that loads it |
| [`setup.sql`](setup.sql) | One-time admin setup: project schema, PROD deploy role, CI users |
| [`workflow.yml`](workflow.yml) | GitHub Actions: plan PROD on pull request, deploy PROD on merge |

## Prerequisites

- **Snowflake CLI 3.24 or later.** Check with `snow --version`. Install with `brew install snowflake-cli` or `pip install snowflake-cli`.
- **A CLI connection that uses role SYSADMIN**, set as your default with `snow connection set-default <name>`. Confirm with `snow connection test`. (Or add `-c <name>` to every command below.)
- **ACCOUNTADMIN** for the one-time setup.
- **A GitHub repo** with Actions enabled.
- **Your account identifier.** Get it with `SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME();`

## Setup (once)

1. Copy this folder into your repo as `snowflake/demo/`, and copy `workflow.yml` to `.github/workflows/snowflake.yml`.
2. Fill in the placeholders:
   - `<ORG>-<ACCOUNT>` in `manifest.yml` and the workflow
   - `<owner>/<repo>` in `setup.sql`
   - `COMPUTE_WH` in `setup.sql`, if you use a different warehouse
3. Run the admin setup:
   ```bash
   snow sql -f snowflake/demo/setup.sql
   ```
4. Create and test DEV:
   ```bash
   cd snowflake/demo
   snow dcm create --target DEV
   snow dcm plan --target DEV                         # expect 4 CREATEs
   snow dcm deploy --target DEV
   snow sql -q "CALL DEMO_DEV.RAW.LOAD_CONTACTS()"    # expect: loaded 4 contacts
   ```
5. Commit and push to `main`. The first workflow run creates the PROD project and deploys it.

Don't create the PROD project yourself. Whoever creates a project owns it, and CI's role should own PROD.

## Making a change

1. Edit a file in `sources/definitions/`.
2. Run `snow dcm plan --target DEV` to see exactly what will change.
3. Run `snow dcm deploy --target DEV`, then run what you changed to test it.
4. Push a branch and open a pull request. CI runs the PROD plan; read it in the check's log.
5. Merge. CI deploys PROD and runs the procedure once as a smoke test.

## Gotchas

- **Plan and deploy don't run your Python.** A missing package passes both and fails only when the procedure is called. Pin versions in `PACKAGES`, and run the procedure in DEV before opening a pull request.
- **Deleting a `DEFINE` drops that object** on the next deploy. Always read the plan.
- **Users and integrations aren't managed by DCM.** Keep them in admin scripts like `setup.sql`.
- **Network policies:** if your account only allows certain IPs, GitHub's hosted runners are blocked. Allow them, or use a self-hosted runner inside your network.
- **On GitHub Team or Enterprise**, you can use one CI user instead of two by logging in through a GitHub environment (subject `repo:<owner>/<repo>:environment:<name>`).
