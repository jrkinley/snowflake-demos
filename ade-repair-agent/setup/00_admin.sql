-- One-off admin setup for the ADE repair agent demo.
--
-- Run as ACCOUNTADMIN. It recreates the environment from the Data engineering
-- with CoCo guide (scripts/setup.sql in Snowflake-Labs/sfguide-data-engineering-with-coco)
-- with one deliberate change, and adds what the pipeline needs to run in Snowflake.
--
-- Change from the guide: DEMO_ROLE is NOT granted to SYSADMIN. This demo exists to
-- show that an agent's reach is set by its role, its restricted session scope and its
-- profile. If the demo objects rolled up into SYSADMIN, a broad admin role would hold
-- everything anyway and blur the boundary we're demonstrating. Every guide step still
-- runs as DEMO_ROLE, so nothing else in the guide changes.

USE ROLE ACCOUNTADMIN;

SET demo_user = CURRENT_USER();

-- Sample data. Newer accounts already have it; this is a no-op if so. The share
-- name is region-specific: find yours with SHOW SHARES LIKE 'SAMPLE_DATA'.
-- CREATE DATABASE IF NOT EXISTS SNOWFLAKE_SAMPLE_DATA FROM SHARE <provider_account>.SAMPLE_DATA;

-- Role (guide), granted to you only
CREATE ROLE IF NOT EXISTS DEMO_ROLE
  COMMENT = 'Data engineering with CoCo guide: builds and runs the dbt pipeline';
GRANT ROLE DEMO_ROLE TO USER IDENTIFIER($demo_user);
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE_SAMPLE_DATA TO ROLE DEMO_ROLE;

-- Warehouse (guide)
CREATE WAREHOUSE IF NOT EXISTS DEMO_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 300 AUTO_RESUME = TRUE;
GRANT OWNERSHIP ON WAREHOUSE DEMO_WH TO ROLE DEMO_ROLE COPY CURRENT GRANTS;

-- Database and schema (guide)
CREATE DATABASE IF NOT EXISTS DEMO_DB;
GRANT OWNERSHIP ON DATABASE DEMO_DB TO ROLE DEMO_ROLE COPY CURRENT GRANTS;
USE ROLE DEMO_ROLE;
CREATE SCHEMA IF NOT EXISTS DEMO_DB.TPCH_TRANSFORMED;

-- Added for this demo: read the pipeline code from GitHub and schedule it.
-- The repo is public, so the API integration needs no secret.
USE ROLE ACCOUNTADMIN;
CREATE API INTEGRATION IF NOT EXISTS ADE_DEMO_GITHUB
  API_PROVIDER = GIT_HTTPS_API
  API_ALLOWED_PREFIXES = ('https://github.com/')
  ENABLED = TRUE
  COMMENT = 'ADE repair agent demo: read public GitHub repos';
GRANT USAGE ON INTEGRATION ADE_DEMO_GITHUB TO ROLE DEMO_ROLE;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE DEMO_ROLE;

-- Added for this demo: dbt deps, for the dbt_semantic_view package that builds the
-- semantic view at the end of the pipeline. These two hosts are the minimum dbt needs.
USE ROLE DEMO_ROLE;
CREATE NETWORK RULE IF NOT EXISTS DEMO_DB.TPCH_TRANSFORMED.DBT_DEPS_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('hub.getdbt.com', 'codeload.github.com');
USE ROLE ACCOUNTADMIN;
CREATE EXTERNAL ACCESS INTEGRATION IF NOT EXISTS ADE_DEMO_DEPS_ACCESS
  ALLOWED_NETWORK_RULES = (DEMO_DB.TPCH_TRANSFORMED.DBT_DEPS_NETWORK_RULE)
  ENABLED = TRUE
  COMMENT = 'ADE repair agent demo: egress for dbt deps';
GRANT USAGE ON INTEGRATION ADE_DEMO_DEPS_ACCESS TO ROLE DEMO_ROLE;
GRANT CREATE SEMANTIC VIEW ON SCHEMA DEMO_DB.TPCH_TRANSFORMED TO ROLE DEMO_ROLE;
