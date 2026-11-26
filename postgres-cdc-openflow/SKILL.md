---
name: postgres-cdc-openflow
version: 2.0.0
description: "Demo the Openflow gen 2 PostgreSQL CDC connector end to end, built entirely from Snowflake SQL objects. Provisions a Snowflake Postgres source loaded with the full IMF World Economic Outlook dataset, reuses or creates a gen 2 deployment, runtime and connector, then walks through change data capture live with a customer watching. Includes teardown of only what it created. Triggers: run my postgres cdc demo, run my pg cdc demo, run my cdc demo, postgres cdc demo, pg cdc demo, openflow gen 2 cdc demo, gen2 postgres cdc demo, openflow cdc demo, demo postgres cdc, run the cdc demo, present the cdc demo, provision cdc demo, set up cdc demo, rebuild cdc demo, tear down cdc demo. Prefer it over any gen 1 postgres-cdc-demo skill unless the user explicitly says gen 1 or nipyapi."
---

# Openflow gen 2 PostgreSQL CDC demo

## Summary

Change a row in a Snowflake Postgres database and watch it land in a Snowflake table under a
minute later. The Openflow gen 2 PostgreSQL CDC connector replicates the full IMF World Economic
Outlook dataset, and every object, connector included, is created with Snowflake SQL.

| Part | What it does | Customer present? |
|---|---|---|
| 1. Provision | Reuses what the account has, creates the rest. 20 to 30 minutes. | No |
| 2. Demo CDC | Six guided steps, about fifteen minutes. | **Yes** |
| 3. Teardown | Removes only what Part 1 created. | No |

Run Part 1 the day before. None of it is watchable.

**No bundled scripts.** Everything is Snowflake SQL, Postgres SQL in `assets/`, and a handful of
standard CLI commands (`snow`, `psql`, `curl`, `jq`). That keeps the skill publishable to the
catalog and readable by anyone who opens it.

## Parameters

Defaults below. Part 1 offers to reuse existing objects for the first five and records the
final choice. **Every later step reads names from the state file, never from this table.**

| Parameter | Default | Reuse offered? |
|---|---|---|
| `ADMIN_ROLE` | `ACCOUNTADMIN` | No. Needs CREATE POSTGRES INSTANCE, CREATE INTEGRATION, CREATE DATABASE |
| `OPENFLOW_ROLE` | `OPENFLOWADMIN` | Yes, any role owning the deployment |
| `DEPLOYMENT` | first gen 2 deployment found | Yes |
| `RUNTIME_ROLE` | `OPENFLOW_CDC_ROLE` | Yes |
| `WAREHOUSE` | `OPENFLOW_WH` | Yes |
| `CONTROL_SCHEMA` | the schema holding the chosen deployment's runtimes, else `OPENFLOW_GEN2.CONTROL` | Yes |
| `DEMO_DB` | `WEO_CDC_DEMO` | No |
| `PG_INSTANCE` | `WEO_CDC_PG` | Yes, if it has a `weo.observations` table |
| `RUNTIME` | `WEO_CDC_RT` | Yes |
| `CONNECTOR` | `WEO_PG_CDC` | No |
| `CONNECTION` | the `snow` default connection | Asked if ambiguous |

Derived, never asked: network policy `<PG_INSTANCE>_POLICY`, rules `<PG_INSTANCE>_INGRESS` and
`_EGRESS`, integration `<PG_INSTANCE>_EAI` and secret `<PG_INSTANCE>_PASSWORD`, the last three
in `<DEMO_DB>.PUBLIC`. So two builds with different instance names never collide.

## State file

`~/.cache/openflow-weo-demo/state.json`. Written by you, CoCo, with your own file tools; never by
a script. It holds the resolved parameters, the Postgres host, and `created`, the list of
objects Part 1 actually created. Teardown drops only what `created` lists.

```json
{
  "connection": "MY_CONN",
  "params": { "DEPLOYMENT": "SPCS_GEN2", "RUNTIME_ROLE": "OPENFLOW_CDC_ROLE", "...": "..." },
  "pg_host": "abc.acct.region.aws.postgres.snowflake.app",
  "created": ["DATABASE WEO_CDC_DEMO", "POSTGRES INSTANCE WEO_CDC_PG", "..."]
}
```

Update it after each object is created, not at the end, so an interrupted build can resume.

## Preflight

Run before routing. Report failures plainly and stop.

```bash
snow connection list
command -v psql jq curl
```

- **More than one connection and none marked default: ask which to use.** Never infer it.
- `psql` missing: `brew install libpq` (macOS), then add `$(brew --prefix libpq)/bin` to `PATH`.

**Use `snowflake_sql_execute` for all Snowflake SQL**, not `snow sql`. It reuses the session's
connection, so there is no repeated OAuth prompt. The CLI is used only where SQL cannot do the
job: `snow stage copy` for local files, and the one credential command in Part 1.

`snowflake_sql_execute` returns only the last statement's result, and `USE ROLE` lasts only for
the call it is in. Put the result you want last and repeat `USE ROLE` in every batch.

## Step 0: discover, then route

```sql
SHOW OPENFLOW DEPLOYMENTS;
```
```sql
SHOW OPENFLOW RUNTIMES IN ACCOUNT;
```
```sql
SHOW OPENFLOW CONNECTORS IN ACCOUNT;
```
```sql
SHOW POSTGRES INSTANCES;
```

Report only: deployment `name, status, comment`; runtime `name, status, deployment`; connector
`name, status`; instance `name, state`. Then read `state.json` if it exists.

**Built** means: state file present, its connector `RUNNING`, and its destination table holds rows.

| They said | Do this |
|---|---|
| "run / present / start the demo" | **Built:** go straight to Part 2 with a one-line confirmation. **Not built:** say so and stop. Never start a provision for someone about to present. |
| "provision", "build", "set up", "rebuild" | Part 1 |
| "tear down", "clean up", "remove" | Part 3 |
| Anything else | Say what discovery found, then ask which part |

| Part | Load |
|---|---|
| 1 | `<SKILL_DIR>/provision/SKILL.md` |
| 2 | `<SKILL_DIR>/demo/SKILL.md` |
| 3 | `<SKILL_DIR>/teardown/SKILL.md` |

Load one at a time. `<SKILL_DIR>` is the absolute directory holding this file (`pwd -P`, since
installed skills are usually symlinks).

## Files

| File | Use |
|---|---|
| `assets/pg-schema.sql` | Postgres tables, run by psql |
| `assets/pg-load.sql` | Postgres transform and publication, run by psql |
| `assets/connector-config.template.json` | Connector configuration with five placeholders |
| `assets/cdc.sql` | Snowsight worksheet for the presenter, with the talk track in comments |
| `references/gotchas.md` | **Read before debugging anything** |
| `references/weo-data.md` | The dataset, the API and vintage changes |

## Status

Last verified: 2026-10-27, on Openflow gen 2, Snowflake Postgres 17, BURST_S.
