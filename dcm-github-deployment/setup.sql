-- One-time setup, run by an admin.
-- Replace <owner>/<repo> with your GitHub repo, and COMPUTE_WH if you use a different warehouse.

-- Where DCM project objects live. SYSADMIN owns it, and also owns the DEV project.
USE ROLE SYSADMIN;
CREATE DATABASE IF NOT EXISTS DCM_ADMIN;
CREATE SCHEMA IF NOT EXISTS DCM_ADMIN.PROJECTS;

USE ROLE ACCOUNTADMIN;

-- The only role that can deploy PROD. Grant it to the CI users, not to people.
CREATE ROLE IF NOT EXISTS DEMO_PROD_DEPLOYER;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE DEMO_PROD_DEPLOYER;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE DEMO_PROD_DEPLOYER;
GRANT USAGE ON DATABASE DCM_ADMIN TO ROLE DEMO_PROD_DEPLOYER;
GRANT USAGE ON SCHEMA DCM_ADMIN.PROJECTS TO ROLE DEMO_PROD_DEPLOYER;
GRANT CREATE DCM PROJECT ON SCHEMA DCM_ADMIN.PROJECTS TO ROLE DEMO_PROD_DEPLOYER;
GRANT CREATE STAGE ON SCHEMA DCM_ADMIN.PROJECTS TO ROLE DEMO_PROD_DEPLOYER; -- the CLI uploads files through a temporary stage

-- CI logins. GitHub proves who it is with a short-lived token, so no key or password is stored in GitHub.
-- Pull requests log in as DEMO_CI_PLAN; pushes to main log in as DEMO_CI_DEPLOY.
CREATE USER IF NOT EXISTS DEMO_CI_PLAN
  TYPE = SERVICE
  DEFAULT_ROLE = DEMO_PROD_DEPLOYER
  DEFAULT_WAREHOUSE = COMPUTE_WH
  WORKLOAD_IDENTITY = (
    TYPE = OIDC
    ISSUER = 'https://token.actions.githubusercontent.com'
    SUBJECT = 'repo:<owner>/<repo>:pull_request'
  );

CREATE USER IF NOT EXISTS DEMO_CI_DEPLOY
  TYPE = SERVICE
  DEFAULT_ROLE = DEMO_PROD_DEPLOYER
  DEFAULT_WAREHOUSE = COMPUTE_WH
  WORKLOAD_IDENTITY = (
    TYPE = OIDC
    ISSUER = 'https://token.actions.githubusercontent.com'
    SUBJECT = 'repo:<owner>/<repo>:ref:refs/heads/main'
  );

GRANT ROLE DEMO_PROD_DEPLOYER TO USER DEMO_CI_PLAN;
GRANT ROLE DEMO_PROD_DEPLOYER TO USER DEMO_CI_DEPLOY;
