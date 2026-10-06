---
name: dcm-github-setup
description: Guided setup for deploying Snowflake objects from a GitHub repo with DCM Projects (snow dcm) and GitHub Actions. Use when the user wants to set up Snowflake DCM, deploy Snowflake objects from Git or GitHub, add CI/CD for Snowflake, or debug snow dcm plan/deploy failures or GitHub Actions logins to Snowflake.
---

# Snowflake DCM + GitHub: guided setup

You are walking the user through deploying Snowflake objects from their repo:
DEV from their laptop, PROD only from GitHub Actions. The template files live in the
`dcm-github-deployment` folder of https://github.com/sfc-gh-npalkar/snowflake-client-resources,
and its README is the manual version of these steps.

## How to run this

- **One step at a time.** For each step: say in one line what it does, run the command in
  the terminal (the user approves it), and compare the output to **Expect**. Move on only
  when it matches. If it doesn't, stop and use Troubleshooting before going further.
- **Never touch PROD locally.** Don't run anything with `--target PROD`, and don't create
  the PROD project. CI creates it, so CI's role owns it. Ownership of a DCM project can only
  move before its first deploy.
- **Check what's on disk.** After writing a file, `cat` it. Editors can show content that
  was never saved.
- **Look it up instead of guessing.** If an error isn't in Troubleshooting, read the
  relevant page under Reference docs before proposing a fix.

## Step 0: Gather context (read-only)

Run these and summarize what you found in a few lines before Step 1:

1. Repo root and GitHub repo: `git rev-parse --show-toplevel` and `git remote get-url origin`.
   Derive `<owner>/<repo>`.
2. Existing Snowflake code. Search the repo for `manifest.yml` files containing
   `type: DCM_PROJECT`, `.sql` files with `CREATE PROCEDURE` or `DEFINE`, and existing
   `.github/workflows/*.yml`. If you find any, don't overwrite them. Ask how to integrate.
3. Snowflake CLI: `snow --version`. It must be 3.24 or later.
4. Connection: `snow connection test`. Note the account, user, role and warehouse. The role
   should be SYSADMIN, or another role that can create databases.
5. Account identifier:
   `snow sql -q "SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME()"`
6. Network policy: `snow sql -q "SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT"`. If a
   value is set, warn now that GitHub-hosted runners may be blocked (see Troubleshooting).
7. Ask the user for a short project name (default `DEMO`) and a folder for it (default
   `snowflake/demo`).

## Step 1: Copy the templates

```bash
git clone --depth 1 https://github.com/sfc-gh-npalkar/snowflake-client-resources.git /tmp/scr
mkdir -p <folder> .github/workflows
cp -R /tmp/scr/dcm-github-deployment/{manifest.yml,setup.sql,.gitignore,sources} <folder>/
cp /tmp/scr/dcm-github-deployment/workflow.yml .github/workflows/snowflake.yml
```

**Expect:** `<folder>/manifest.yml`, `<folder>/setup.sql`, two files in
`<folder>/sources/definitions/`, and `.github/workflows/snowflake.yml`.

## Step 2: Fill in values

Edit the copied files:

- `<ORG>-<ACCOUNT>` becomes the account identifier: twice in `manifest.yml`, once in the workflow.
- `<owner>/<repo>` becomes the GitHub repo: twice in `setup.sql`.
- `COMPUTE_WH` becomes the connection's warehouse, if different: in `setup.sql`.
- If the project name isn't `DEMO`:
  - Replace the `DEMO_` prefix everywhere in `manifest.yml`, `setup.sql`, and the workflow's
    smoke-test CALL.
  - If the folder isn't `snowflake/demo`, update the workflow's `paths` and
    `working-directory` to match.

**Expect:** this prints nothing:
`grep -n "<ORG>\|<owner>" <folder>/manifest.yml <folder>/setup.sql .github/workflows/snowflake.yml`

## Step 3: Admin setup

`snow sql -f <folder>/setup.sql`. It needs ACCOUNTADMIN. If the user's connection can't use
ACCOUNTADMIN, have them send the file to an admin to run in a Snowsight worksheet, then continue.

**Expect:** the last two results are each one `OIDC` row whose subject contains the repo.

## Step 4: Create the DEV project

`cd <folder> && snow dcm create --target DEV`

**Expect:** `DCM Project 'DCM_ADMIN.PROJECTS.<NAME>_DEV' successfully created.`

## Step 5: Plan DEV

First run the Python package check below. Then run `snow dcm plan --target DEV`.

**Expect:** 4 CREATEs: database, schema `RAW`, table `CONTACTS`, procedure `LOAD_CONTACTS`.
Explain that a plan is a dry run: nothing exists yet.

## Step 6: Deploy and test DEV

```bash
snow dcm deploy --target DEV
snow sql -q "CALL <NAME>_DEV.RAW.LOAD_CONTACTS()"
snow sql -q "SELECT CONTACT_ID, PHONE_RAW, PHONE_E164 FROM <NAME>_DEV.RAW.CONTACTS ORDER BY 1"
```

**Expect:** `loaded 4 contacts`, then 4 rows. Three are cleaned to `+1...` format, and 104 is NULL.

## Step 7: Push and watch CI

```bash
git add <folder> .github/workflows/snowflake.yml
git commit -m "Add Snowflake DCM project"
git push origin main
```

Follow the run in GitHub » Actions » Snowflake, or with `gh run list --limit 3`.
On failure, run `gh run view <id> --log-failed`.

**Expect:** the `deploy` job is green, and its Smoke test step prints `loaded 4 contacts`.
If the repo requires pull requests, push a branch and open a PR instead. The `plan` job runs
on the PR, and `deploy` runs after merge.

## Python package check (before any deploy that touches a Python procedure)

Plan and deploy don't run Python, so a missing package only shows up when the procedure is
called. Before deploying:

1. For each `LANGUAGE PYTHON` procedure, list every `import x` / `from x import` in the `$$` body.
2. Every module that isn't standard library, and isn't `snowflake`, must be in `PACKAGES`.
   Import names can differ from package names: `yaml` comes from `pyyaml`, and `sklearn`
   from `scikit-learn`.
3. Confirm the package is available and pick a version to pin. The view needs a database prefix:
   `snow sql -q "SELECT PACKAGE_NAME, VERSION, RUNTIME_VERSION FROM SNOWFLAKE.INFORMATION_SCHEMA.PACKAGES WHERE LANGUAGE = 'python' AND PACKAGE_NAME = '<pkg>'"`
4. Write it pinned, for example `PACKAGES = ('snowflake-snowpark-python', 'phonenumbers==9.0.36')`.

## The everyday loop (coach this after setup)

1. Create a branch.
2. Edit a definition.
3. `snow dcm plan --target DEV` and read it.
4. `snow dcm deploy --target DEV`, then run what changed.
5. Open a PR; the `plan` check shows the PROD changes.
6. Merge to deploy PROD.

Removing a `DEFINE` drops that object on the next deploy, so always read the plan.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `manifest.yml was not found in directory` | Wrong working directory | `cd <folder>`, or pass `--from <folder>` |
| Compile error such as `Unknown function language: PYTH` in a file that looks fine | Saved file differs from the editor (unsaved, or a paste broke it) | `cat` the file; rewrite it with a file tool |
| Plan and deploy pass, then CALL fails with `ModuleNotFoundError` | Package missing from `PACKAGES` | Run the Python package check, add a pinned version, then plan, deploy and CALL again |
| Error mentioning Anaconda terms | Third-party packages not enabled | ORGADMIN: Snowsight » Admin » Terms » Anaconda » Enable |
| `snow dcm` not recognized | CLI older than 3.24 | `brew upgrade snowflake-cli` or `pip install -U snowflake-cli` |
| Insufficient privileges on a stage or DCM project in CI | A grant from `setup.sql` is missing | Re-run `setup.sql`; it is safe to run again |
| CI can't log in to Snowflake | Token subject doesn't match a CI login | PR jobs: `repo:<owner>/<repo>:pull_request`. Pushes to main: `repo:<owner>/<repo>:ref:refs/heads/main`. Adding `environment:` to a job changes the subject. Compare with `SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER <user>` |
| CI blocked by IP | Account network policy | Allow GitHub runner IPs, or use a self-hosted runner inside the network (`runs-on: self-hosted`) |
| PROD project owned by a person | Someone ran `snow dcm create --target PROD` locally | If it was never deployed, transfer ownership to the deploy role; otherwise involve an admin |

## Reference docs

- DCM Projects, deploy and manage: https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-use
- DCM Projects, supported objects: https://docs.snowflake.com/en/user-guide/dcm-projects/dcm-projects-supported-entities
- Snowflake CLI GitHub Action: https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/github-action
- Workload identity federation (CI logins): https://docs.snowflake.com/en/user-guide/workload-identity-federation
- Python procedures and Anaconda packages: https://docs.snowflake.com/en/developer-guide/stored-procedure/python/procedure-python-overview
