-- Runs the IMF WEO dbt tests and shows what they leave behind for audit. Run
-- after build_layers.sql, block by block, or whole with:
--   snow sql -c <connection> -f test_and_audit.sql
--
-- 30 tests: generic ones in the model YAML (not_null, unique, relationships,
-- accepted_values) and five custom SQL tests in tests/. A test is a query
-- that returns failing rows; zero rows is a pass.
-- Severity: error fails the invocation, warn reports and carries on.

USE ROLE IMF_DBT_ROLE;
USE WAREHOUSE COMPUTE_WH;

-- 1. Run every test.
-- Expect 29 pass and 1 warn: warn_hyperinflation_since_2020 is meant to find
-- something, consumer prices up more than 100% in a year since 2020.
-- store_failures (dbt_project.yml) writes each test's failing rows to a table
-- in DEV_AUDIT named after the test. The on-run-end macro record_test_results
-- appends one row per test to DEV_AUDIT.TEST_RESULTS_HISTORY.
-- DEV_AUDIT: one table per test, plus TEST_RESULTS_HISTORY.
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'test';

SHOW TABLES IN SCHEMA IMF_DBT_DB.DEV_AUDIT;

-- 2. Failing rows of the warning: 20 country-years across Argentina, Lebanon,
-- Sudan, Venezuela and Zimbabwe.
SELECT *
FROM IMF_DBT_DB.DEV_AUDIT.WARN_HYPERINFLATION_SINCE_2020
ORDER BY inflation_pct DESC;

-- 3. Run history: one row per test per invocation, status and failure count.
SELECT run_started_at, target_name, test_name, severity, status, failures
FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY
ORDER BY run_started_at DESC, status DESC, test_name;

-- 4. Break a test on purpose.
-- Duplicate a row in DIM_ENTITY, so its unique test on country_code fails
-- with severity error. The invocation fails, the duplicate lands in that
-- test's audit table, and the history gains a fail.
INSERT INTO IMF_DBT_DB.DEV_SILVER.DIM_ENTITY
SELECT * FROM IMF_DBT_DB.DEV_SILVER.DIM_ENTITY WHERE country_code = 'GBR';

EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'test --select dim_entity';

SELECT run_started_at, test_name, status, failures, audit_relation
FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY
WHERE status <> 'pass'
ORDER BY run_started_at DESC;

-- 5. Repair and build.
-- build runs seeds, models, snapshots and tests in DAG order, so a model is
-- tested before anything downstream builds on it. Rebuilding DIM_ENTITY
-- removes the duplicate. This is also the first build of the snapshot.
-- DEV_SNAPSHOTS: SNAP_GDP_GROWTH_PROJECTIONS.
-- The audit table for the unique test is replaced on this run and comes back
-- empty; TEST_RESULTS_HISTORY keeps the failure from block 4.
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'build';

SELECT test_name, status, COUNT(*) AS runs
FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY
GROUP BY 1, 2
HAVING status <> 'pass'
ORDER BY 1, 2;
