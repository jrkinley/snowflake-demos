-- Removes everything the IMF WEO dbt demo created.
--
-- Run as ACCOUNTADMIN. The warehouse is left alone because the demo never owned
-- it: dropping IMF_DBT_ROLE removes the role's usage grant and nothing else.
--
-- Order matters. The tasks and dbt project object live in the database, so
-- dropping it removes them. The external access integrations are account-level
-- and reference network rules inside the database, so drop them first.

USE ROLE ACCOUNTADMIN;

ALTER TASK IF EXISTS IMF_DBT_DB.DBT_PROJECTS.LOAD_IMF_WEO_TASK SUSPEND;

DROP EXTERNAL ACCESS INTEGRATION IF EXISTS IMF_DBT_API_ACCESS;
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS IMF_DBT_DEPS_ACCESS;

DROP DATABASE IF EXISTS IMF_DBT_DB;

DROP ROLE IF EXISTS IMF_DBT_ROLE;
