-- Schedules the pipeline as a two-step task graph:
--
--   LOAD_IMF_WEO_TASK  calls the loader, which lands the latest WEO vintage
--   BUILD_IMF_WEO_TASK runs dbt build once the load has finished
--
-- The IMF publishes in April and October, so the root runs on the 1st and 15th
-- of each month. Reloading an unchanged vintage replaces it with identical rows
-- and the incremental fact merges them in place, so extra runs are harmless.
--
-- Both tasks use the same warehouse you granted in 01_admin.sql. dbt picks it up
-- from the task session through env.yml, so one run wakes one warehouse.
-- Serverless tasks cannot execute dbt project objects, so a warehouse is needed.
--
-- Created suspended. Resume the root to start the schedule:
--   ALTER TASK IMF_DBT_DB.DBT_PROJECTS.BUILD_IMF_WEO_TASK RESUME;
--   ALTER TASK IMF_DBT_DB.DBT_PROJECTS.LOAD_IMF_WEO_TASK RESUME;
-- Or run it once now:
--   EXECUTE TASK IMF_DBT_DB.DBT_PROJECTS.LOAD_IMF_WEO_TASK;

USE ROLE IMF_DBT_ROLE;

SET demo_wh = 'COMPUTE_WH';

CREATE OR ALTER TASK IMF_DBT_DB.DBT_PROJECTS.LOAD_IMF_WEO_TASK
  WAREHOUSE = $demo_wh
  SCHEDULE = 'USING CRON 0 6 1,15 * * UTC'
  COMMENT = 'Loads the latest IMF WEO vintage into RAW'
AS
  CALL IMF_DBT_DB.DBT_PROJECTS.LOAD_IMF_WEO();

CREATE OR ALTER TASK IMF_DBT_DB.DBT_PROJECTS.BUILD_IMF_WEO_TASK
  WAREHOUSE = $demo_wh
  COMMENT = 'Builds and tests the IMF WEO dbt project in the prod environment'
  AFTER IMF_DBT_DB.DBT_PROJECTS.LOAD_IMF_WEO_TASK
AS
  EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO
    ARGS = 'build --target prod'
    ENVIRONMENT = 'prod';
