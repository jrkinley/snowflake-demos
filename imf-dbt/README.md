# IMF WEO on dbt Projects on Snowflake

## Summary

A dbt project that turns the IMF World Economic Outlook (WEO) into governed, tested and documented economic metrics, running entirely inside Snowflake as a dbt project object. A stored procedure lands the full WEO release from the public IMF API: 145 indicators, about 200 countries and 13 IMF aggregates, 1980 to five years ahead. dbt builds it into bronze, silver and gold layers on dbt Core 1.12.3, with no dbt installation anywhere. The story is what a team gets once dbt runs on Snowflake rather than beside it: no runtime to own, a task graph for scheduling, documentation that shows up in Horizon, and a semantic view defined in dbt that Cortex Analyst can answer questions from.

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

**Build it.** One statement runs the whole project server-side: 1 seed, 11 models, 1 snapshot and 29 tests, in about 20 seconds.

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
