-- Puts the IMF WEO dbt test results under Snowflake data quality monitoring.
-- Run after test_and_audit.sql, block by block, or whole with:
--   snow sql -c <connection> -f data_quality.sql
--
-- A data metric function (DMF) is a function Snowflake runs against a table on
-- a schedule, recording one number per measurement. An expectation is a rule
-- on that number; a measurement that breaks it is flagged as a violation.
-- Nothing here is created by hand: the record_test_results on-run-end macro
-- creates the DMF and binds it, once, on the first run that has tests.

USE ROLE IMF_DBT_ROLE;
USE WAREHOUSE COMPUTE_WH;

-- 1. The DMF and its binding.
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

-- 2. Measurements against the expectation.
-- Results land a few minutes after each run. With the hyperinflation warning in
-- every full test run, expect value 1 and expectation_violated TRUE. The
-- broken run in test_and_audit.sql block 4 also measures 1, but only
-- dim_entity's tests ran, so here the 1 is the failing unique test.
SELECT measurement_time, value, expectation_name, expectation_violated
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS
WHERE table_database = 'IMF_DBT_DB' AND table_name = 'TEST_RESULTS_HISTORY'
ORDER BY measurement_time DESC;

-- 3. Which tests the number counts.
-- The DMF gives one number per run; the history table says which tests.
SELECT test_name, severity, status, failures, audit_relation
FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY
WHERE run_started_at = (SELECT MAX(run_started_at) FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY)
  AND status <> 'pass';
