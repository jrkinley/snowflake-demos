-- IMF WEO on dbt Projects on Snowflake: demo runbook.
--
-- Run after setup/01_admin.sql, setup/02_load_raw.sql and the deploy (see
-- README, Setup). Work through it a block at a time in a Snowsight worksheet
-- or workspace; the README explains each step alongside. Step 3.4 fails on
-- purpose, so don't run the file whole.
--
-- ARGS takes standard dbt commands and flags. Run order comes from source()
-- and ref(); each ref() resolves to the target's schema, so the same code
-- builds DEV_ or PROD_. Folder sets the schema (dbt_project.yml).
-- --select: +model adds parents, model+ adds children.

USE ROLE IMF_DBT_ROLE;
USE WAREHOUSE COMPUTE_WH;


-- =============================================================================
-- STEP 1: build layer by layer
-- =============================================================================

-- 1.1 Seed and bronze.
-- DEV_BRONZE: table IMF_UNIT_DICTIONARY (seed, 12 rows); views
-- STG_IMF__OBSERVATIONS, STG_IMF__INDICATORS, STG_IMF__COUNTRIES,
-- STG_IMF__UNITS (rename and cast only).
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'seed';
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'run --select staging';

-- 1.2 Fact table and its parents.
-- DEV_SILVER: FCT_INDICATOR_OBSERVATIONS, incremental, one row per country,
-- indicator, year and vintage, with is_projection per series.
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'run --select +fct_indicator_observations';

SELECT COUNT(*) FROM IMF_DBT_DB.DEV_SILVER.FCT_INDICATOR_OBSERVATIONS;

-- 1.3 Remaining models.
-- DEV_SILVER: DIM_ENTITY (COUNTRY or AGGREGATE), DIM_INDICATOR, view
-- INT_OBSERVATIONS_LATEST_VINTAGE (newest vintage per series).
-- DEV_GOLD: GDP_GROWTH_BY_COUNTRY, COUNTRY_ECONOMIC_INDICATORS, semantic view
-- IMF_WEO_ECONOMY.
-- DEV_AUDIT and DEV_SNAPSHOTS come later, with tests and build.
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'run';

SHOW SCHEMAS IN DATABASE IMF_DBT_DB;

-- 1.4 Incremental rerun, then full refresh.
-- Rerun merges the newest vintage onto itself on the full grain: count
-- unchanged, MAX(dbt_updated_at) advances. Only a new vintage adds rows.
-- --full-refresh rebuilds; needed after a logic change, because incremental
-- runs don't rewrite existing rows.
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'run --select fct_indicator_observations';

SELECT COUNT(*), MAX(dbt_updated_at) FROM IMF_DBT_DB.DEV_SILVER.FCT_INDICATOR_OBSERVATIONS;

EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'run --select fct_indicator_observations --full-refresh';


-- =============================================================================
-- STEP 2: descriptions and lineage in Horizon
-- =============================================================================

-- 2.1 Table and column comments.
-- persist_docs (dbt_project.yml) writes each description in the model YAML as
-- a Snowflake comment on every build, so Horizon and Snowsight show them with
-- no separate step. DIM_ENTITY's come from models/marts/_marts__models.yml.
-- Same view in Snowsight: Catalog, Explorer, IMF_DBT_DB, DEV_SILVER, DIM_ENTITY.
-- Lineage: Transformations, dbt Projects, IMF_WEO, then Show columns on a node.
SELECT table_name, comment
FROM IMF_DBT_DB.INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'DEV_SILVER' AND table_name = 'DIM_ENTITY';

SELECT column_name, data_type, comment
FROM IMF_DBT_DB.INFORMATION_SCHEMA.COLUMNS
WHERE table_schema = 'DEV_SILVER' AND table_name = 'DIM_ENTITY'
ORDER BY ordinal_position;


-- =============================================================================
-- STEP 3: tests and audit
-- =============================================================================
-- 30 tests: generic ones in the model YAML (not_null, unique, relationships,
-- accepted_values) and five custom SQL tests in tests/. A test is a query
-- that returns failing rows; zero rows is a pass.
-- Severity: error fails the invocation, warn reports and carries on.

-- 3.1 Run every test.
-- Expect 29 pass and 1 warn: warn_hyperinflation_since_2020 is meant to find
-- something, consumer prices up more than 100% in a year since 2020.
-- store_failures (dbt_project.yml) writes each test's failing rows to a table
-- in DEV_AUDIT named after the test. The on-run-end macro record_test_results
-- appends one row per test to DEV_AUDIT.TEST_RESULTS_HISTORY.
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'test';

SHOW TABLES IN SCHEMA IMF_DBT_DB.DEV_AUDIT;

-- 3.2 Failing rows of the warning: 20 country-years across Argentina,
-- Lebanon, Sudan, Venezuela and Zimbabwe.
SELECT *
FROM IMF_DBT_DB.DEV_AUDIT.WARN_HYPERINFLATION_SINCE_2020
ORDER BY inflation_pct DESC;

-- 3.3 Run history: one row per test per invocation, status and failure count.
SELECT run_started_at, target_name, test_name, severity, status, failures
FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY
ORDER BY run_started_at DESC, status DESC, test_name;

-- 3.4 Break a test on purpose. The EXECUTE fails; that's the point.
-- Duplicate a row in DIM_ENTITY, so its unique test on country_code fails
-- with severity error. The duplicate lands in that test's audit table, and
-- the history gains a fail.
INSERT INTO IMF_DBT_DB.DEV_SILVER.DIM_ENTITY
SELECT * FROM IMF_DBT_DB.DEV_SILVER.DIM_ENTITY WHERE country_code = 'GBR';

EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'test --select dim_entity';

SELECT run_started_at, test_name, status, failures, audit_relation
FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY
WHERE status <> 'pass'
ORDER BY run_started_at DESC;

-- 3.5 Repair and build.
-- build runs seeds, models, snapshots and tests in DAG order, so a model is
-- tested before anything downstream builds on it. Rebuilding DIM_ENTITY
-- removes the duplicate. This is also the first build of the snapshot.
-- DEV_SNAPSHOTS: SNAP_GDP_GROWTH_PROJECTIONS.
-- The audit table for the unique test is replaced on this run and comes back
-- empty; TEST_RESULTS_HISTORY keeps the failure from 3.4.
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'build';

SELECT test_name, status, COUNT(*) AS runs
FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY
GROUP BY 1, 2
HAVING status <> 'pass'
ORDER BY 1, 2;


-- =============================================================================
-- STEP 4: data quality monitoring
-- =============================================================================
-- A data metric function (DMF) is a function Snowflake runs against a table on
-- a schedule, recording one number per measurement. An expectation is a rule
-- on that number; a measurement that breaks it is flagged as a violation.
-- Nothing here is created by hand: the record_test_results on-run-end macro
-- creates the DMF and binds it, once, on the first run that has tests.

-- 4.1 The DMF and its binding.
-- DEV_AUDIT.FAILING_TESTS_LATEST_RUN counts tests with status warn, fail or
-- error in the latest run recorded in TEST_RESULTS_HISTORY. It's bound to the
-- history table with expectation ALL_TESTS_PASS (value = 0), and scheduled
-- TRIGGER_ON_CHANGES, so every run's insert is measured straight away.
-- It sits on the history table, not the per-test audit tables, because
-- store_failures recreates those on every run, which drops any DMF bound to
-- them and restarts their measurement history.
SHOW DATA METRIC FUNCTIONS IN SCHEMA IMF_DBT_DB.DEV_AUDIT;

SELECT metric_name, ref_arguments, schedule, schedule_status
FROM TABLE(IMF_DBT_DB.INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
    ref_entity_name => 'IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY',
    ref_entity_domain => 'TABLE'));

-- 4.2 Measurements against the expectation.
-- Results land a few minutes after each run. With the hyperinflation warning in
-- every full test run, expect value 1 and expectation_violated TRUE. The
-- broken run in 3.4 also measures 1, but only dim_entity's tests ran, so there
-- the 1 is the failing unique test.
-- Same view in Snowsight: TEST_RESULTS_HISTORY, Data Quality tab.
SELECT measurement_time, value, expectation_name, expectation_violated
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS
WHERE table_database = 'IMF_DBT_DB' AND table_name = 'TEST_RESULTS_HISTORY'
ORDER BY measurement_time DESC;

-- 4.3 Which tests the number counts.
-- The DMF gives one number per run; the history table says which tests.
SELECT test_name, severity, status, failures, audit_relation
FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY
WHERE run_started_at = (SELECT MAX(run_started_at) FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY)
  AND status <> 'pass';


-- =============================================================================
-- STEP 5: ask the agent
-- =============================================================================
-- Create it once:  snow sql -c <connection> -f setup/04_agent.sql
-- Then open IMF WEO Analyst in Snowflake CoWork, or test it in AI & ML, Agents.
-- The prompt to run is in the README, step 5.
SHOW AGENTS IN SCHEMA IMF_DBT_DB.PUBLIC;
