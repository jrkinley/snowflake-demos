# IMF WEO on dbt Projects on Snowflake

## Summary

A dbt project that turns the IMF World Economic Outlook (WEO) into governed, tested and documented economic metrics, running entirely inside Snowflake as a dbt project object. A stored procedure lands the full WEO release from the public IMF API: 145 indicators, about 200 countries and 13 IMF aggregates, 1980 to five years ahead. dbt builds it into bronze, silver and gold layers on dbt Core 1.12.3, with no dbt installation anywhere. The story is what a team gets once dbt runs on Snowflake rather than beside it: no runtime to own, a task graph for scheduling, documentation that shows up in Horizon, and a semantic view defined in dbt that Cortex Analyst can answer questions from.

## How the project works

### dbt in one paragraph

dbt builds warehouse tables from SQL files. Each `.sql` file is a **model**: a single `SELECT` describing what a table should contain. dbt works out which models depend on which, runs them in order and creates each one as a table or view, so you never write `CREATE TABLE` yourself. YAML files alongside the SQL hold descriptions and tests. Normally dbt is installed on a laptop or server. Here the whole project is uploaded to Snowflake as one object, `IMF_DBT_DB.DBT_PROJECTS.IMF_WEO`, and `EXECUTE DBT PROJECT` runs it.

### Where the data starts

dbt never calls the internet. The `LOAD_IMF_WEO` stored procedure fetches the WEO from the IMF API and writes three tables in `IMF_DBT_DB.RAW`: every published value, the IMF's indicator list and its country list. dbt only reads `RAW`. In dbt terms these are **sources**, declared in `dbt/models/staging/_imf__sources.yml`.

### Project structure

```
imf-dbt/
├── setup/            plain SQL, run once: role, database, API access, loader, schedule, teardown
└── dbt/              the dbt project
    ├── dbt_project.yml            settings, including which folder builds into which schema
    ├── dbt_projects_profiles.yml  how dbt connects (read by Snowflake only)
    ├── env.yml                    picks role, warehouse and DEV or PROD at run time (Snowflake only)
    ├── packages.yml               one add-on package, for semantic views
    ├── seeds/                     small CSVs loaded as tables
    ├── models/
    │   ├── staging/               bronze: tidy the raw tables
    │   ├── intermediate/          silver helper: latest release only
    │   ├── marts/                 silver dimensions and fact, gold reporting tables
    │   ├── semantic/              the semantic view for Cortex Analyst
    │   └── overview.md            the project page shown in Snowsight
    ├── snapshots/                 history tracking
    ├── tests/                     custom data checks
    └── macros/                    one helper that controls schema naming
```

### What each file creates in Snowflake

The file name becomes the object name and the folder decides the schema. Schemas are prefixed `DEV_` or `PROD_` by the environment chosen in `env.yml`. A dev build creates:

| dbt file | Snowflake object | Type | What it holds |
|---|---|---|---|
| `seeds/imf_unit_dictionary.csv` | `DEV_BRONZE.IMF_UNIT_DICTIONARY` | table | 12 rows turning unit codes like `PT` into "Percent" |
| `staging/stg_imf__observations.sql` | `DEV_BRONZE.STG_IMF__OBSERVATIONS` | view | Raw values renamed and retyped, nothing more |
| `staging/stg_imf__indicators.sql` | `DEV_BRONZE.STG_IMF__INDICATORS` | view | The same for the indicator list |
| `staging/stg_imf__countries.sql` | `DEV_BRONZE.STG_IMF__COUNTRIES` | view | The same for the country list |
| `staging/stg_imf__units.sql` | `DEV_BRONZE.STG_IMF__UNITS` | view | The same for the unit seed |
| `marts/dim_entity.sql` | `DEV_SILVER.DIM_ENTITY` | table | One row per country or IMF group, labelled COUNTRY or AGGREGATE |
| `marts/dim_indicator.sql` | `DEV_SILVER.DIM_INDICATOR` | table | One row per indicator: name, definition, unit and whether it can be summed |
| `marts/fct_indicator_observations.sql` | `DEV_SILVER.FCT_INDICATOR_OBSERVATIONS` | incremental table | The core table: country, indicator, year and release. About 360,000 rows per release |
| `intermediate/int_observations_latest_vintage.sql` | `DEV_SILVER.INT_OBSERVATIONS_LATEST_VINTAGE` | view | The fact table filtered to the newest release |
| `marts/gdp_growth_by_country.sql` | `DEV_GOLD.GDP_GROWTH_BY_COUNTRY` | table | Real GDP growth per country and year, with a five-year average |
| `marts/country_economic_indicators.sql` | `DEV_GOLD.COUNTRY_ECONOMIC_INDICATORS` | table | One row per country and year, nine headline indicators side by side |
| `semantic/imf_weo_economy.sql` | `DEV_GOLD.IMF_WEO_ECONOMY` | semantic view | Business definitions Cortex Analyst answers questions from |
| `snapshots/snap_gdp_growth_projections.sql` | `DEV_SNAPSHOTS.SNAP_GDP_GROWTH_PROJECTIONS` | table | Dated history of how each forecast changed |
| every test | `DEV_AUDIT.<TEST_NAME>` | table | The rows that test failed on its latest run, usually none |
| `macros/record_test_results.sql` | `DEV_AUDIT.TEST_RESULTS_HISTORY` | table | One row per test per run: status and failure count |

Bronze is tidied but untouched, silver is where the business rules live, and gold is ready for people and tools to query. Each layer reads only from the one before, so a bad number can be traced back a step at a time.

### What dbt adds on top of plain SQL

Models refer to each other with `ref('dim_entity')` rather than a table name. That's how dbt knows `dim_entity` must exist before `gdp_growth_by_country`, and why the same code builds into `DEV_` or `PROD_` without edits. The fact table is incremental, so a run adds only releases it hasn't seen rather than rebuilding everything.

Every build also runs 30 tests and fails if any error-level test does. Most are simple: no nulls, no duplicates, every country code present in `dim_entity`. The five in `tests/` are custom SQL. The important one checks that the countries' GDP adds up to the IMF's own World total, which catches an IMF group such as the G7 being counted as a country. Every simple check would pass that mistake. Each test also stores the rows it failed, covered under "Audit the tests" below.

The descriptions in the YAML files are written to Snowflake as table and column comments, so anyone browsing in Snowsight or Horizon sees them without opening the code.

## Prerequisites

- A Snowflake account with ACCOUNTADMIN for the one-off setup in `01_admin.sql`. External access integrations and granting a new role to your user are account-level, so they need it. Everything else runs as the demo's own role.
- An existing warehouse. The demo creates none. It uses whichever one you set at the top of `01_admin.sql` and `03_schedule.sql` (default `COMPUTE_WH`), and dbt picks it up from the calling session.
- Outbound access to `api.imf.org` (the IMF data), and `hub.getdbt.com` and `codeload.github.com` (dbt packages). Both are set up as external access integrations.
- Snowflake CLI 3.16 or later, for `snow dbt deploy`. Tested on 3.27.0. No local dbt or Python needed.

## Setup

Run the setup scripts in order. Each is plain SQL and idempotent.

```bash
cd imf-dbt
snow sql -f setup/01_admin.sql       # role, database, network access (ACCOUNTADMIN)
snow sql -f setup/02_load_raw.sql    # raw tables, loader procedure, first load
```

`01_admin.sql` creates `IMF_DBT_ROLE`, the `IMF_DBT_DB` database with `RAW` and `DBT_PROJECTS` schemas, and two external access integrations. `02_load_raw.sql` creates the loader procedure `DBT_PROJECTS.LOAD_IMF_WEO()` and calls it. The first load takes about 30 seconds and reports what it landed:

```
Loaded WEO vintage 2026-10-13: 361511 observations, 145 indicators, 344 countries and aggregates
```

Then deploy the dbt project as a Snowflake object, pinned to dbt 1.12.3, with the integration that lets Snowflake run `dbt deps` during deployment:

```bash
cd dbt
snow dbt deploy imf_weo --source . \
  --role IMF_DBT_ROLE --warehouse COMPUTE_WH \
  --database IMF_DBT_DB --schema DBT_PROJECTS \
  --default-target dev --dbt-version 1.12.3 \
  --external-access-integration IMF_DBT_DEPS_ACCESS
```

If you'd rather not use the CLI, the same thing works in SQL: `PUT` the contents of `dbt/` to a stage, then `CREATE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO FROM '@<stage>' DBT_VERSION = '1.12.3' EXTERNAL_ACCESS_INTEGRATIONS = (IMF_DBT_DEPS_ACCESS)`. Redeploying is `ALTER DBT PROJECT ... DEPLOY FROM '@<stage>'`.

Finally, create the schedule, which stays suspended until you resume it:

```bash
cd ..
snow sql -f setup/03_schedule.sql
```

## Run the demo

Everything from here runs as `IMF_DBT_ROLE`, in a worksheet or with `snow sql`.

**Build it.** One statement runs the whole project server-side: 1 seed, 11 models, 1 snapshot and 30 tests, in about 20 seconds, ending with one expected warning.

```sql
USE ROLE IMF_DBT_ROLE;
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'build';
```

`ARGS` is the command you'd have typed at a dbt CLI. There's no dbt server in the account: Snowflake starts a managed runtime for the execution and it's gone afterwards. `env.yml` resolves the role, warehouse and target schema from the calling session before dbt starts, which standard dbt can't do, so the same project runs as `DEV_*` or `PROD_*` depending on the environment you pick.

**Walk the layers.** `DEV_BRONZE` holds staging views that only rename and cast. `DEV_SILVER` holds the conformed dimensions and `FCT_INDICATOR_OBSERVATIONS`, one row per country, indicator, year and vintage. `DEV_GOLD` holds the analyst-facing marts. Two business rules in silver carry the demo:

- Countries and IMF aggregates share one column. Countries carry ISO3 codes and aggregates carry G-prefixed codes (G001 is World), and `dim_entity` separates them. Sum them together and world GDP comes out at several times its real size while every structural test passes, so `tests/assert_country_sum_matches_world.sql` checks a control total instead: the countries must add up to the IMF's own World figure. In the current vintage they agree to within $2m on $112tn.
- Each IMF series says which year is its last actual. `is_projection` comes from that marker rather than a hard-coded year, so the flag stays right as each release moves the boundary.

**See the history.** The fact table keeps every vintage, and the snapshot records how each projection changed as this pipeline saw it. Call `LOAD_IMF_WEO()` again after the IMF's next release and rebuild, and both fill with a second vintage you can compare.

**Open the docs in Horizon.** Run `docs generate`, then open the `IMF_WEO` project in Snowsight (Catalog, then `IMF_DBT_DB.DBT_PROJECTS`). The overview from `models/overview.md` renders on the project page. Because `persist_docs` is on, every model and column description is also a Snowflake comment, so anyone browsing the tables in Horizon sees them without opening the repo.

```sql
EXECUTE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO ARGS = 'docs generate';
```

**Ask Cortex Analyst.** `models/semantic/imf_weo_economy.sql` is a Snowflake semantic view written as a dbt model with the `dbt_semantic_view` package. The model body is the semantic view DDL, so it's versioned, reviewed and deployed with everything else, and `ref()` resolves it per environment. It defines synonyms, a GDP-weighted growth metric, instructions that stop Analyst summing percentages, and two verified queries. Point Cortex Analyst at `IMF_DBT_DB.DEV_GOLD.IMF_WEO_ECONOMY` and ask "What is the IMF forecast for UK real GDP growth?", or query it directly:

```sql
SELECT * FROM SEMANTIC_VIEW(
    IMF_DBT_DB.DEV_GOLD.IMF_WEO_ECONOMY
    DIMENSIONS countries.country_name, economy.year
    METRICS economy.total_gdp_usd_bn, economy.avg_real_gdp_growth_pct
    WHERE economy.year = 2025
) ORDER BY total_gdp_usd_bn DESC LIMIT 10;
```

**Schedule it.** `03_schedule.sql` creates a two-task graph: `LOAD_IMF_WEO_TASK` lands the latest vintage on the 1st and 15th of each month, then `BUILD_IMF_WEO_TASK` runs `dbt build --target prod`. Both use the same warehouse, so a run wakes one warehouse rather than two. To run it once, resume the child (a suspended child doesn't run, even under `EXECUTE TASK`) and execute the root:

```sql
ALTER TASK IMF_DBT_DB.DBT_PROJECTS.BUILD_IMF_WEO_TASK RESUME;
EXECUTE TASK IMF_DBT_DB.DBT_PROJECTS.LOAD_IMF_WEO_TASK;
```

Run history for every execution, scheduled or not, is in `SNOWFLAKE.ACCOUNT_USAGE.DBT_PROJECT_EXECUTION_HISTORY` and the project's run history in Snowsight.

**Audit the tests.** dbt tests normally report pass or fail in the log and nothing else. Here every test also keeps the rows it failed, because `dbt_project.yml` turns on `store_failures` for all tests and sends them to an `<ENV>_AUDIT` schema, one table per test. Most of those tables are empty, which is the point. One test is meant to find something: `tests/warn_hyperinflation_since_2020.sql` flags consumer prices rising more than 100% in a year since 2020. It's set to `warn`, so the build still succeeds, and in the October 2026 vintage it catches 20 country-years across Argentina, Lebanon, Sudan, Venezuela and Zimbabwe.

```sql
SELECT * FROM IMF_DBT_DB.DEV_AUDIT.WARN_HYPERINFLATION_SINCE_2020
ORDER BY inflation_pct DESC;
```

`store_failures` replaces each table on every run, so on its own it only knows about the latest failures. The `record_test_results` macro runs at the end of every invocation and adds the history, one row per test per run, appended to `TEST_RESULTS_HISTORY`:

```sql
SELECT run_started_at, target_name, test_name, status, failures
FROM IMF_DBT_DB.DEV_AUDIT.TEST_RESULTS_HISTORY
WHERE status <> 'pass'
ORDER BY run_started_at DESC;
```

The same macro puts that history under Snowflake data quality monitoring. It creates a small custom data metric function, `FAILING_TESTS_LATEST_RUN`, which counts tests that didn't pass in the latest run, and binds it to the history table with an expectation of zero. With the hyperinflation warning in every run, the expectation `ALL_TESTS_PASS` reports violated with a value of 1, a few minutes after each run writes its results:

```sql
SELECT measurement_time, value, expectation_name, expectation_violated
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_EXPECTATION_STATUS
WHERE table_database = 'IMF_DBT_DB' AND table_name = 'TEST_RESULTS_HISTORY'
ORDER BY measurement_time DESC;
```

Why the history table rather than the per-test tables? `store_failures` recreates those on every run, and a recreated table loses its data metric functions and starts a new measurement history. The history table is only ever appended to, so the function is bound once and its results build up run after run. Because every run inserts after the binding exists, it can use `TRIGGER_ON_CHANGES` rather than a timed schedule. The function gives one number for the whole run rather than one per test: binding it `WITHIN GROUP (test_name)` is accepted, but Snowflake then suspends it as invalid without an error. Which test failed is a query on the history table away.

## Teardown

```bash
snow sql -f setup/99_teardown.sql
```

Drops both external access integrations, the `IMF_DBT_DB` database (which takes the tasks, the dbt project object and the loader procedure with it) and `IMF_DBT_ROLE`. The warehouse is untouched.

## Status

Last verified: 2026-10-15 on dbt Core 1.12.3, against the IMF WEO vintage published 13 October 2026.

Known issues:

- The IMF SDMX API has two traps that fail without an error. `dimensionAtObservation=AllDimensions` returns zero rows for multi-series queries, and `startPeriod` and `endPeriod` are ignored. The loader avoids both by requesting SDMX-CSV for the whole vintage.
- Asking the API for all attributes repeats long descriptive text on every row. The loader requests only the four it needs, which keeps a full vintage to about 32 MB.
