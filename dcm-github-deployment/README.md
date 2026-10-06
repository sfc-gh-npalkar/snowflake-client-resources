# Deploy Snowflake Objects from GitHub with DCM Projects

Keep your Snowflake objects (tables, procedures, grants) as files in your repo, next to your app code. Snowflake reads those files and creates or updates the objects to match.

```
your laptop     ── snow dcm deploy ──────────►  DEV   (you test here)
pull request    ── CI: snow dcm plan ────────►  PROD  (preview only, nothing changes)
merge to main   ── CI: snow dcm deploy ──────►  PROD  (the real deploy)
```

GitHub logs in to Snowflake with a short-lived token, so no password or key is stored in GitHub.

## Two ways to follow this

- **Guided:** install the Cursor skill ([below](#guided-setup-with-cursor)) and ask the agent to set this up. It checks your environment first, runs one step at a time, and compares each result to what it should be.
- **Manual:** follow [Setup](#setup-once) below.

## Files

| File | What it is |
|---|---|
| [`manifest.yml`](manifest.yml) | DEV and PROD targets: same definitions, different database |
| [`sources/definitions/`](sources/definitions/) | The objects: a table and a Python procedure that loads it |
| [`setup.sql`](setup.sql) | One-time admin setup: project schema, PROD deploy role, CI logins |
| [`workflow.yml`](workflow.yml) | GitHub Actions: plan PROD on pull request, deploy PROD on merge |
| [`skill/dcm-github-setup/`](skill/dcm-github-setup/) | Cursor skill that walks you through all of this |

## Before you start

1. **Snowflake CLI 3.24 or later.**
   ```bash
   snow --version
   ```
   To install or upgrade: `brew install snowflake-cli` (macOS) or `pip install -U snowflake-cli`.

2. **A default CLI connection that uses role SYSADMIN.**
   ```bash
   snow connection add --default      # answer the prompts; use role SYSADMIN
   snow connection test
   ```
   You should see `Status | OK` and `Role | SYSADMIN`.

3. **Your account identifier.**
   ```bash
   snow sql -q "SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME()"
   ```
   You should see something like `MYORG-MYACCOUNT`. You'll paste this in step 2.

4. **Admin access, once.**
   - ACCOUNTADMIN runs `setup.sql`.
   - Python packages need the Anaconda terms accepted. If your account hasn't done this, an ORGADMIN goes to Snowsight » **Admin** » **Terms** » **Anaconda** » **Enable**.

5. **A GitHub repo** with Actions enabled.

## Setup (once)

Run everything from your repo's root folder unless a step says otherwise.

**1. Copy the files into your repo.**
```bash
git clone --depth 1 https://github.com/sfc-gh-npalkar/snowflake-client-resources.git /tmp/scr
mkdir -p snowflake/demo .github/workflows
cp -R /tmp/scr/dcm-github-deployment/{manifest.yml,setup.sql,.gitignore,sources} snowflake/demo/
cp /tmp/scr/dcm-github-deployment/workflow.yml .github/workflows/snowflake.yml
```
You should see `snowflake/demo/manifest.yml`, `snowflake/demo/setup.sql`, `snowflake/demo/sources/definitions/` (2 files), and `.github/workflows/snowflake.yml`.

**2. Fill in the placeholders.**

| Placeholder | Where | Replace with |
|---|---|---|
| `<ORG>-<ACCOUNT>` | `manifest.yml` (twice), `.github/workflows/snowflake.yml` (once) | Your account identifier |
| `<owner>/<repo>` | `setup.sql` (twice) | Your GitHub repo, from `git remote get-url origin` |
| `COMPUTE_WH` | `setup.sql` | Your warehouse, if it's different |

Check that none are left. This should print nothing:
```bash
grep -n "<ORG>\|<owner>" snowflake/demo/manifest.yml snowflake/demo/setup.sql .github/workflows/snowflake.yml
```

**3. Run the admin setup.** This creates the project schema, the PROD deploy role, and the two CI logins.
```bash
snow sql -f snowflake/demo/setup.sql
```
The last two results should each be one `OIDC` row, with your repo in the subject.

**4. Create the DEV project.** This is the Snowflake object that tracks what DCM deployed to DEV.
```bash
cd snowflake/demo
snow dcm create --target DEV
```
You should see `DCM Project 'DCM_ADMIN.PROJECTS.DEMO_DEV' successfully created.`

**5. Preview DEV.** A plan is a dry run, so nothing is created yet.
```bash
snow dcm plan --target DEV
```
You should see 4 CREATEs: database `DEMO_DEV`, schema `RAW`, table `CONTACTS`, procedure `LOAD_CONTACTS`.

**6. Deploy DEV and test it.**
```bash
snow dcm deploy --target DEV
snow sql -q "CALL DEMO_DEV.RAW.LOAD_CONTACTS()"
snow sql -q "SELECT CONTACT_ID, PHONE_RAW, PHONE_E164 FROM DEMO_DEV.RAW.CONTACTS ORDER BY 1"
```
You should see `loaded 4 contacts`, then 4 rows. Three phone numbers are cleaned up, like `+13345550142`, and contact 104 (`call me`) is empty.

**7. Push to GitHub.** CI creates the PROD project and deploys it.
```bash
cd ../..
git add snowflake/demo .github/workflows/snowflake.yml
git commit -m "Add Snowflake DCM project"
git push origin main
```
In GitHub, open **Actions** » **Snowflake**. The `deploy` job should go green, and its **Smoke test** step should print `loaded 4 contacts`.

Don't create or deploy the PROD project yourself. Whoever creates a project owns it, and only CI's role should own PROD.

## Making a change

1. Create a branch: `git checkout -b my-change`
2. Edit a file in `sources/definitions/`.
3. From `snowflake/demo`, preview the change against DEV: `snow dcm plan --target DEV`
4. Deploy to DEV with `snow dcm deploy --target DEV`, then run what you changed to test it.
5. Push the branch and open a pull request. The `plan` check shows exactly what will change in PROD.
6. Merge. The `deploy` job updates PROD and runs the smoke test.

## Troubleshooting

| You see | What it means | Fix |
|---|---|---|
| `manifest.yml was not found in directory` | You ran `snow dcm` from the wrong folder | `cd snowflake/demo`, or add `--from snowflake/demo` |
| A compile error in a file that looks fine in your editor | The saved file differs from what you see (unsaved, or a paste broke it) | Run `cat` on the file, fix it, and save |
| Plan and deploy succeed, but CALL fails with `ModuleNotFoundError` | A package the code imports is missing from `PACKAGES` | Add it with a pinned version, then plan, deploy, and CALL again |
| An error mentioning Anaconda terms | Third-party packages aren't enabled | An ORGADMIN accepts the terms (see [Before you start](#before-you-start), step 4) |
| `snow dcm` isn't recognized | Snowflake CLI is older than 3.24 | Upgrade the CLI |
| The CI job can't log in to Snowflake | GitHub's token doesn't match a CI login in `setup.sql` | Pull requests must use `...:pull_request`; pushes to `main` must use `...:ref:refs/heads/main`. Adding `environment:` to a job changes this |
| The CI job is blocked by IP | Your account has a network policy | Allow GitHub's runners, or run a self-hosted runner inside your network |

## Gotchas

- **Plan and deploy don't run your Python.** A missing package passes both and fails only when the procedure is called. Pin versions in `PACKAGES`, and run the procedure in DEV before opening a pull request.
- **Deleting a `DEFINE` drops that object** on the next deploy. Always read the plan.
- **Users and integrations aren't managed by DCM.** Keep them in admin scripts like `setup.sql`.
- **On GitHub Team or Enterprise**, you can use one CI login instead of two by logging in through a GitHub environment (subject `repo:<owner>/<repo>:environment:<name>`).

## Guided setup with Cursor

The skill checks your repo and account first, then walks you through the steps above one at a time. If something fails, it knows the errors in the Troubleshooting table and where to look them up in Snowflake's docs.

1. From your repo root, install it:
   ```bash
   git clone --depth 1 https://github.com/sfc-gh-npalkar/snowflake-client-resources.git /tmp/scr
   mkdir -p .cursor/skills
   cp -R /tmp/scr/dcm-github-deployment/skill/dcm-github-setup .cursor/skills/
   ```
2. Open a new Agent chat in Cursor and type `/dcm-github-setup`, or ask *"set up Snowflake deployments from this repo"*.

It also works in Claude Code. Copy the same folder to `.claude/skills/` instead.
