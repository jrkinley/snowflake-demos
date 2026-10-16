# IMF WEO on dbt Projects on Snowflake

## Summary

A dbt project that turns the IMF World Economic Outlook (WEO) into governed, tested and documented economic metrics, running entirely inside Snowflake as a dbt project object. A stored procedure lands the full WEO release from the public IMF API: 145 indicators, about 200 countries and 13 IMF aggregates, 1980 to five years ahead. dbt Core 1.12.3 builds it into bronze, silver and gold, with no dbt installation anywhere.

What you get once dbt runs on Snowflake rather than beside it: no runtime to own, descriptions that land in Horizon, test results kept for audit and watched by Snowflake data quality monitoring, and a semantic view defined in dbt that a Snowflake CoWork agent answers questions from.

## How the project works

dbt builds warehouse tables from SQL files. Each `.sql` file is a **model**: a single `SELECT` describing what a table should contain. Models refer to each other with `ref('dim_entity')` rather than a table name, which is how dbt works out the run order, and why the same code builds into `DEV_` or `PROD_` without edits. YAML files alongside hold descriptions and tests. Here the whole project is uploaded to Snowflake as one object, `IMF_DBT_DB.DBT_PROJECTS.IMF_WEO`, and `EXECUTE DBT PROJECT` runs it.

dbt never calls the internet. The `LOAD_IMF_WEO` procedure fetches the WEO and writes three tables in `IMF_DBT_DB.RAW`: every published value, the indicator list and the country list. dbt only reads `RAW`, declared as **sources** in `dbt/models/staging/_imf__sources.yml`.

### Project structure

```
imf-dbt/
├── setup/            plain SQL, run once: role, database, API access, loader, agent, schedule, teardown
├── runbook.sql       the demo, a block at a time, alongside "Walk the demo" below
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
    │   ├── semantic/              the semantic view
    │   └── overview.md            the project page shown in Snowsight
    ├── snapshots/                 history tracking
    ├── tests/                     custom data checks
    └── macros/                    schema naming, and the test results history
```

### What each file creates in Snowflake

The file name becomes the object name and the folder decides the schema, prefixed `DEV_` or `PROD_` by the environment in `env.yml`. A dev build creates:

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

Bronze is tidied but untouched, silver is where the business rules live, and gold is ready for people and tools. Each layer reads only from the one before, so a bad number can be traced back a step at a time.

## Prerequisites

- ACCOUNTADMIN, for the account-level parts of `01_admin.sql` and `04_agent.sql`. Everything else runs as the demo's own role.
- An existing warehouse, set at the top of `01_admin.sql` (default `COMPUTE_WH`). The demo creates none; dbt uses the calling session's.
- Outbound access to `api.imf.org` for the data, and `hub.getdbt.com` and `codeload.github.com` for dbt packages. Both are set up as external access integrations.
- Snowflake CLI 3.16 or later. Tested on 3.27.0. No local dbt or Python needed.

## Setup

The `setup/` scripts are plain SQL, run once and idempotent.

| Script | Runs as | Creates |
|---|---|---|
| `01_admin.sql` | ACCOUNTADMIN, then `IMF_DBT_ROLE` | Role `IMF_DBT_ROLE`; database `IMF_DBT_DB` with `RAW` and `DBT_PROJECTS`; external access integrations `IMF_DBT_API_ACCESS` (IMF API) and `IMF_DBT_DEPS_ACCESS` (dbt packages) |
| `02_load_raw.sql` | `IMF_DBT_ROLE` | Three `RAW` tables and the loader `DBT_PROJECTS.LOAD_IMF_WEO()`, then calls it |
| `04_agent.sql` | ACCOUNTADMIN, then `IMF_DBT_ROLE` | The CoWork agent `PUBLIC.IMF_WEO_ANALYST`. Needs the semantic view, so run it after the first build |
| `03_schedule.sql` | `IMF_DBT_ROLE` | Optional: two suspended tasks that load then build prod |
| `99_teardown.sql` | ACCOUNTADMIN | Removes everything |

```bash
cd imf-dbt
snow sql -f setup/01_admin.sql
snow sql -f setup/02_load_raw.sql
```

The load takes about 30 seconds and reports:

```
Loaded WEO vintage 2026-10-13: 361511 observations, 145 indicators, 344 countries and aggregates
```

### Deploy the dbt project

Deploying uploads `dbt/` into the object `IMF_DBT_DB.DBT_PROJECTS.IMF_WEO` and runs `dbt deps`. It builds nothing. Pick one route and stick to it.

The CLI, which is also the route CI uses:

```bash
cd dbt
snow dbt deploy imf_weo --source . \
  --role IMF_DBT_ROLE --warehouse COMPUTE_WH \
  --database IMF_DBT_DB --schema DBT_PROJECTS \
  --default-target dev --dbt-version 1.12.3 \
  --external-access-integration IMF_DBT_DEPS_ACCESS
```

A Snowsight workspace: pull to the latest `main` first, because a deploy copies the workspace as it stands. Run Deps with `IMF_DBT_DEPS_ACCESS` (down arrow next to execute, Run with defaults), then Connect, Deploy dbt project, to `IMF_DBT_DB.DBT_PROJECTS` as `IMF_WEO`. Snowsight doesn't pin a dbt version, so the object takes the account's `DEFAULT_DBT_VERSION`. Set it after the first deploy:

```sql
ALTER DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO SET
  DBT_VERSION = '1.12.3',
  EXTERNAL_ACCESS_INTEGRATIONS = (IMF_DBT_DEPS_ACCESS);
```

That changes settings and copies no code. After any pull, redeploy (Connect, Redeploy dbt project) and check the files with `LIST 'snow://dbt/IMF_DBT_DB.DBT_PROJECTS.IMF_WEO/versions/live/'`.

SQL: `PUT` `dbt/` to a stage, then `CREATE DBT PROJECT IMF_DBT_DB.DBT_PROJECTS.IMF_WEO FROM '@<stage>' DBT_VERSION = '1.12.3' EXTERNAL_ACCESS_INTEGRATIONS = (IMF_DBT_DEPS_ACCESS)`. Redeploy with `ALTER DBT PROJECT ... DEPLOY FROM '@<stage>'`.

Whichever route, `require-dbt-version` in `dbt_project.yml` fails any run on a version other than 1.12, and `SHOW DBT PROJECTS IN SCHEMA IMF_DBT_DB.DBT_PROJECTS` shows the version in use.

## Walk the demo

`runbook.sql` has every statement, numbered to match the steps below. Run it a block at a time in a Snowsight worksheet or workspace, as `IMF_DBT_ROLE`. Step 3.4 fails on purpose, so don't run it whole.

Each `EXECUTE DBT PROJECT ... ARGS = '...'` is a dbt command run server-side. There's no dbt server: Snowflake starts a managed runtime for the call and discards it afterwards. `env.yml` resolves the role, warehouse and target schema from your session before dbt starts.

### Step 1: build layer by layer

Runbook 1.1 to 1.4. Seed and bronze, then the fact table with everything upstream of it (`--select +fct_indicator_observations`), then the rest. `DEV_BRONZE`, `DEV_SILVER` and `DEV_GOLD` appear in that order.

Two business rules in silver carry the demo. First, countries and IMF aggregates share one column: countries carry ISO3 codes, aggregates G-prefixed ones (G001 is World), and `dim_entity` separates them. Sum them together and world GDP comes out several times too large while every structural test passes. So `tests/assert_country_sum_matches_world.sql` checks a control total instead: the countries must add up to the IMF's own World figure. In the current vintage they agree to within $2m on $112tn.

Second, each IMF series says which year is its last actual. `is_projection` comes from that marker rather than a hard-coded year, so it stays right as each release moves the boundary.

1.4 reruns the incremental fact table. It merges the newest vintage onto itself on the full grain, so the row count holds while `dbt_updated_at` moves. Only a new IMF vintage adds rows. `--full-refresh` rebuilds from scratch, which a change to the model's logic needs.

The fact table keeps every vintage, and the snapshot (built in step 3) records how each projection changed. Call `LOAD_IMF_WEO()` after the IMF's next release and rebuild, and both gain a second vintage to compare.

### Step 2: descriptions and lineage in Horizon

Runbook 2.1. There's nothing to run for the docs: `persist_docs` is on, so the step 1 build already wrote every YAML description as a Snowflake table or column comment. The queries show `DIM_ENTITY`'s. In Snowsight:

- Catalog, Explorer, `IMF_DBT_DB`, `DEV_SILVER`, `DIM_ENTITY` shows the same descriptions, as anyone browsing Horizon sees them.
- Transformations, dbt Projects, `IMF_WEO` shows the DAG, each model's compiled SQL and run history, and the overview from `models/overview.md`.
- On the DAG, anchor on `GDP_GROWTH_BY_COUNTRY`, Show columns, and select `real_gdp_growth_pct` to trace it back to `RAW`.

### Step 3: tests and audit

Runbook 3.1 to 3.5. Thirty tests: generic ones in the YAML (no nulls, no duplicates, every country code in `dim_entity`) and five custom SQL tests in `tests/`.

dbt tests normally report pass or fail in the log and nothing else. Here `store_failures` keeps each test's failing rows in a `DEV_AUDIT` table named after it. Most are empty, which is the point. One is meant to find something: `tests/warn_hyperinflation_since_2020.sql` flags consumer prices up more than 100% in a year. It's a `warn`, so the run carries on, and in the October 2026 vintage it catches 20 country-years across Argentina, Lebanon, Sudan, Venezuela and Zimbabwe.

Those tables are replaced on every run, so they only know the latest failures. The `record_test_results` macro runs at the end of every invocation and appends one row per test to `TEST_RESULTS_HISTORY`, which builds the trend. It does nothing when no tests ran, which is why `DEV_AUDIT` only appears now.

3.4 breaks a test on purpose: a duplicate `GBR` in `DIM_ENTITY` fails its unique test at error severity. 3.5 repairs it with `build`, which runs seeds, models, snapshots and tests in DAG order, so a failing parent stops its children building on bad data. The history keeps the failure.

### Step 4: data quality monitoring

Runbook 4.1 to 4.3. The same macro creates a custom data metric function, `FAILING_TESTS_LATEST_RUN`, which counts the tests that didn't pass in the latest run, and binds it to the history table with the expectation `ALL_TESTS_PASS (value = 0)`. With the hyperinflation warning in every full run, it reports violated with a value of 1, a few minutes after each run. The Data Quality tab on `TEST_RESULTS_HISTORY` shows the trend.

Why the history table? `store_failures` recreates the per-test tables on every run, and a recreated table loses its data metric functions and its measurement history. The history table is only appended to, so the function is bound once, measurements accumulate, and `TRIGGER_ON_CHANGES` measures each run as it lands.

It's one number per run, not per test. Binding it `WITHIN GROUP (test_name)` is accepted, but Snowflake then suspends it as invalid without an error. Which test failed is a query on the history table.

### Step 5: ask the agent

`models/semantic/imf_weo_economy.sql` is a Snowflake semantic view written as a dbt model with the `dbt_semantic_view` package. The model body is the DDL itself, so it's versioned, reviewed and deployed with everything else, and `ref()` resolves it per environment. It defines synonyms, a GDP-weighted growth metric, instructions that stop Analyst summing percentages, and two verified queries, with a comment on each block.

`setup/04_agent.sql` puts a CoWork agent, IMF WEO Analyst, on top of it: Cortex Analyst for the numbers, `data_to_chart` for the visuals.

```bash
snow sql -f setup/04_agent.sql
```

Open IMF WEO Analyst in CoWork, or test it under AI & ML, Agents, and ask:

> Give me a briefing on the world's five largest economies. Show how their real GDP growth has moved since 2015 and where the IMF expects it to go by 2030, as a line chart that separates actuals from projections. Compare the GDP-weighted growth of the five with their simple average. Rank them by government debt to GDP in 2025 as a bar chart. Then plot inflation against unemployment for every country in 2025 as a scatter chart and call out the outliers.

That touches everything the model was built for: ranking by GDP, projections from each series' own marker, the weighted metric that exists because rates mustn't be summed, three chart types and a whole-world scatter. If it overruns the agent's 120-second budget, split it at "Then plot".

### Schedule it (optional)

`03_schedule.sql` creates two suspended tasks: `LOAD_IMF_WEO_TASK` lands the latest vintage on the 1st and 15th of each month, then `BUILD_IMF_WEO_TASK` runs `build --target prod`. Both use the same warehouse, so a run wakes one; dbt projects can't run on serverless tasks. To run it once, resume the child first, because a suspended child doesn't run even under `EXECUTE TASK`:

```sql
ALTER TASK IMF_DBT_DB.DBT_PROJECTS.BUILD_IMF_WEO_TASK RESUME;
EXECUTE TASK IMF_DBT_DB.DBT_PROJECTS.LOAD_IMF_WEO_TASK;
```

Every execution, scheduled or not, is in `SNOWFLAKE.ACCOUNT_USAGE.DBT_PROJECT_EXECUTION_HISTORY` and the project's run history in Snowsight.

## Teardown

```bash
snow sql -f setup/99_teardown.sql
```

Drops both external access integrations, `IMF_DBT_ROLE` and the `IMF_DBT_DB` database, which takes the tasks, project object, loader and agent with it. The warehouse is untouched.

## Status

Last verified: 2026-10-16 on dbt Core 1.12.3, against the IMF WEO vintage published 13 October 2026.

Known issues:

- The IMF SDMX API has two traps that fail without an error: `dimensionAtObservation=AllDimensions` returns zero rows for multi-series queries, and `startPeriod` and `endPeriod` are ignored. The loader avoids both by requesting SDMX-CSV for the whole vintage.
- Requesting all attributes repeats long descriptive text on every row. The loader asks for the four it needs, which keeps a full vintage to about 32 MB.
