-- Runs the guide's dbt project inside Snowflake, so a failure is recorded where
-- a cloud agent can see it. Run as DEMO_ROLE after 00_admin.sql.
--
-- The pipeline runs from a long-lived branch, ade-repair-agent-pipeline. The
-- planted break and the agent's fix pull requests go there, so main stays clean.
-- Replace <owner> with the GitHub account that holds your copy of this repo.

USE ROLE DEMO_ROLE;
USE WAREHOUSE DEMO_WH;

CREATE GIT REPOSITORY IF NOT EXISTS DEMO_DB.TPCH_TRANSFORMED.ADE_DEMO_REPO
  API_INTEGRATION = ADE_DEMO_GITHUB
  ORIGIN = 'https://github.com/<owner>/snowflake-demos.git'
  COMMENT = 'ADE repair agent demo: source of the dbt pipeline';

ALTER GIT REPOSITORY DEMO_DB.TPCH_TRANSFORMED.ADE_DEMO_REPO FETCH;

-- dbt deps runs at deploy time for the dbt_semantic_view package, through
-- ADE_DEMO_DEPS_ACCESS.
CREATE DBT PROJECT IF NOT EXISTS DEMO_DB.TPCH_TRANSFORMED.COCO_DE_GUIDE
  FROM '@DEMO_DB.TPCH_TRANSFORMED.ADE_DEMO_REPO/branches/ade-repair-agent-pipeline/ade-repair-agent/dbt'
  DBT_VERSION = '1.12.3'
  EXTERNAL_ACCESS_INTEGRATIONS = (ADE_DEMO_DEPS_ACCESS)
  COMMENT = 'Data engineering with CoCo guide pipeline, run in Snowflake';

-- Fetches the latest commit on the pipeline branch, redeploys and builds, so a
-- commit pushed to the branch reaches the next run. Serverless tasks can't
-- execute dbt project objects, so it uses DEMO_WH. Created suspended.
CREATE OR ALTER TASK DEMO_DB.TPCH_TRANSFORMED.RUN_COCO_DE_GUIDE
  WAREHOUSE = DEMO_WH
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
  COMMENT = 'Fetches, redeploys and builds the guide dbt project'
AS
  BEGIN
    ALTER GIT REPOSITORY DEMO_DB.TPCH_TRANSFORMED.ADE_DEMO_REPO FETCH;
    ALTER DBT PROJECT DEMO_DB.TPCH_TRANSFORMED.COCO_DE_GUIDE
      DEPLOY FROM '@DEMO_DB.TPCH_TRANSFORMED.ADE_DEMO_REPO/branches/ade-repair-agent-pipeline/ade-repair-agent/dbt';
    EXECUTE DBT PROJECT DEMO_DB.TPCH_TRANSFORMED.COCO_DE_GUIDE ARGS = 'build';
  END;

-- Run once now:
--   EXECUTE TASK DEMO_DB.TPCH_TRANSFORMED.RUN_COCO_DE_GUIDE;
-- Start the daily schedule:
--   ALTER TASK DEMO_DB.TPCH_TRANSFORMED.RUN_COCO_DE_GUIDE RESUME;
