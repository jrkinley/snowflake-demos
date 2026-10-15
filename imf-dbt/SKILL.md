---
name: imf-dbt
description: "Run the IMF WEO dbt Projects on Snowflake demo end to end: set up the role, database and IMF API access, load the full World Economic Outlook vintage, deploy and build the dbt project on dbt 1.12.3, show Horizon docs and the dbt-defined semantic view in Cortex Analyst, schedule it, and tear it down. Triggers: imf dbt demo, run the imf dbt demo, dbt projects on snowflake demo, tear down imf dbt demo."
---

# IMF WEO dbt demo

Drives the demo described in `README.md` in this folder. Read it first: it is the source of truth for what each step shows. Resolve every path below relative to this skill's own directory, never the working directory.

## Before anything runs

1. Check the active connection and tell the operator which account it points at. Run nothing until they confirm it's the account they intend.
2. Ask which existing warehouse to use (default `COMPUTE_WH`). Set it in `setup/01_admin.sql` and `setup/03_schedule.sql` as `demo_wh`. The demo never creates a warehouse.
3. Confirm the operator can use ACCOUNTADMIN for `setup/01_admin.sql` and `setup/99_teardown.sql`.

## Setup

1. Run `setup/01_admin.sql`.
2. Run `setup/02_load_raw.sql` and report the loader's return message. It should name the vintage and about 360,000 observations. If it errors on network access, check the `IMF_DBT_API_ACCESS` integration.
3. Deploy `dbt/` as described in the README's Setup section, pinned to dbt 1.12.3 with `--external-access-integration IMF_DBT_DEPS_ACCESS`. If `snow` can't authenticate, use the SQL route the README describes (`PUT` to a stage, then `CREATE DBT PROJECT` or `ALTER DBT PROJECT ... DEPLOY FROM`).
4. Run `setup/03_schedule.sql`. Leave the tasks suspended.

## Walkthrough

Follow the README's "Run the demo" section in order, as `IMF_DBT_ROLE`:

1. `EXECUTE DBT PROJECT ... ARGS = 'build'`. Expect every node to pass. Point out that dbt is not installed anywhere.
2. Show the layers and the two silver business rules: country versus aggregate, and the IMF's per-series projection marker.
3. Run `docs generate` and send the operator to the project page in Snowsight. Show a persisted column comment with `DESCRIBE TABLE`.
4. Query the semantic view, then ask Cortex Analyst both verified questions and one of the operator's own.
5. Run the task graph once (resume the child, execute the root), show the run in task history, then suspend the child again.

## Teardown

Confirm with the operator first, then run `setup/99_teardown.sql` and check that `SHOW DATABASES LIKE 'IMF_DBT_DB'`, `SHOW ROLES LIKE 'IMF_DBT_ROLE'` and `SHOW INTEGRATIONS LIKE 'IMF_DBT%'` all return nothing.
