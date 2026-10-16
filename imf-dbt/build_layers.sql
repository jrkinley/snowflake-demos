-- Builds the IMF WEO dbt project layer by layer. Run after deploy, block by
-- block, or whole with: snow sql -c <connection> -f build_layers.sql
--
-- ARGS takes standard dbt commands and flags. Run order comes from source()
-- and ref(); each ref() resolves to the target's schema, so the same code
-- builds DEV_ or PROD_. Folder sets the schema (dbt_project.yml).
-- --select: +model adds parents, model+ adds children.

USE ROLE IMF_DBT_ROLE;
USE WAREHOUSE COMPUTE_WH;

-- 1. Seed and bronze.
-- DEV_BRONZE: table IMF_UNIT_DICTIONARY (seed, 12 rows); views
-- STG_IMF__OBSERVATIONS, STG_IMF__INDICATORS, STG_IMF__COUNTRIES,
-- STG_IMF__UNITS (rename and cast only).
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'seed';
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'run --select staging';

-- 2. Fact table and its parents.
-- DEV_SILVER: FCT_INDICATOR_OBSERVATIONS, incremental, one row per country,
-- indicator, year and vintage, with is_projection per series.
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'run --select +fct_indicator_observations';

SELECT COUNT(*) FROM IMF_DBT_DB.DEV_SILVER.FCT_INDICATOR_OBSERVATIONS;

-- 3. Remaining models.
-- DEV_SILVER: DIM_ENTITY (COUNTRY or AGGREGATE), DIM_INDICATOR, view
-- INT_OBSERVATIONS_LATEST_VINTAGE (newest vintage per series).
-- DEV_GOLD: GDP_GROWTH_BY_COUNTRY, COUNTRY_ECONOMIC_INDICATORS, semantic view
-- IMF_WEO_ECONOMY.
-- DEV_AUDIT and DEV_SNAPSHOTS come later, with tests and build.
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'run';

SHOW SCHEMAS IN DATABASE IMF_DBT_DB;

-- 4. Incremental rerun, then full refresh.
-- Rerun merges the newest vintage onto itself on the full grain: count
-- unchanged, MAX(dbt_updated_at) advances. Only a new vintage adds rows.
-- --full-refresh rebuilds; needed after a logic change, because incremental
-- runs don't rewrite existing rows.
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'run --select fct_indicator_observations';

SELECT COUNT(*), MAX(dbt_updated_at) FROM IMF_DBT_DB.DEV_SILVER.FCT_INDICATOR_OBSERVATIONS;

EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'run --select fct_indicator_observations --full-refresh';
