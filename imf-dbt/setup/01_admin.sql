-- One-off admin setup for the IMF WEO dbt demo.
--
-- Run as ACCOUNTADMIN. This is the only step that needs it: creating an
-- external access integration is account-level, and so is granting a new role
-- to your user. Everything after this runs as IMF_DBT_ROLE.
--
-- The demo deliberately creates no warehouse. Set demo_wh to whichever
-- warehouse you normally use (your user's DEFAULT_WAREHOUSE is a good choice).
-- dbt picks it up from the calling session through env.yml, so nothing in the
-- project names it.

USE ROLE ACCOUNTADMIN;

SET demo_wh   = 'COMPUTE_WH';
SET demo_user = CURRENT_USER();

-- Role
CREATE ROLE IF NOT EXISTS IMF_DBT_ROLE
  COMMENT = 'IMF WEO dbt demo: owns its database and runs the dbt project';
GRANT ROLE IMF_DBT_ROLE TO USER IDENTIFIER($demo_user);
GRANT USAGE ON WAREHOUSE IDENTIFIER($demo_wh) TO ROLE IMF_DBT_ROLE;

-- Database. The role owns it, so it can create the DEV_ and PROD_ schemas
-- that dbt builds into without further grants.
CREATE DATABASE IF NOT EXISTS IMF_DBT_DB
  COMMENT = 'IMF WEO dbt demo';
GRANT OWNERSHIP ON DATABASE IMF_DBT_DB TO ROLE IMF_DBT_ROLE COPY CURRENT GRANTS;

USE ROLE IMF_DBT_ROLE;
CREATE SCHEMA IF NOT EXISTS IMF_DBT_DB.RAW
  COMMENT = 'Landed IMF data. Shared across environments; dbt only reads it';
CREATE SCHEMA IF NOT EXISTS IMF_DBT_DB.DBT_PROJECTS
  COMMENT = 'dbt project object, loader procedure and schedule';

-- Network access to the public IMF SDMX API, used only by the loader procedure.
CREATE NETWORK RULE IF NOT EXISTS IMF_DBT_DB.RAW.IMF_API_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.imf.org');

USE ROLE ACCOUNTADMIN;
CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS IMF_DBT_API_ACCESS
  ALLOWED_NETWORK_RULES = (IMF_DBT_DB.RAW.IMF_API_NETWORK_RULE)
  ENABLED = TRUE
  COMMENT = 'IMF WEO dbt demo: egress to api.imf.org';
GRANT USAGE ON INTEGRATION IMF_DBT_API_ACCESS TO ROLE IMF_DBT_ROLE;

-- Network access for dbt deps. The project uses the dbt_semantic_view package,
-- and Snowflake runs dbt deps during deployment when the project object has an
-- external access integration. These two hosts are the minimum dbt needs.
USE ROLE IMF_DBT_ROLE;
CREATE NETWORK RULE IF NOT EXISTS IMF_DBT_DB.DBT_PROJECTS.DBT_DEPS_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('hub.getdbt.com', 'codeload.github.com');

USE ROLE ACCOUNTADMIN;
CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS IMF_DBT_DEPS_ACCESS
  ALLOWED_NETWORK_RULES = (IMF_DBT_DB.DBT_PROJECTS.DBT_DEPS_NETWORK_RULE)
  ENABLED = TRUE
  COMMENT = 'IMF WEO dbt demo: egress for dbt deps';
GRANT USAGE ON INTEGRATION IMF_DBT_DEPS_ACCESS TO ROLE IMF_DBT_ROLE;

-- Lets the role schedule the pipeline with a task.
GRANT EXECUTE TASK ON ACCOUNT TO ROLE IMF_DBT_ROLE;

-- Lets the role attach Snowflake data metric functions to the dbt test audit
-- tables, and use the built-in ones such as ROW_COUNT.
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE IMF_DBT_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.DATA_METRIC_USER TO ROLE IMF_DBT_ROLE;
