---
name: postgres-cdc-openflow
description: "Demo the Openflow gen 2 PostgreSQL CDC connector end to end, built entirely from Snowflake SQL objects. Provisions a Snowflake Postgres source loaded with the full IMF World Economic Outlook dataset, reuses or creates a gen 2 deployment, runtime and connector, then walks through change data capture live with a customer watching. Includes teardown of only what it created. Triggers: run my postgres cdc demo, run my pg cdc demo, run my cdc demo, postgres cdc demo, pg cdc demo, openflow gen 2 cdc demo, gen2 postgres cdc demo, openflow cdc demo, demo postgres cdc, run the cdc demo, present the cdc demo, provision cdc demo, set up cdc demo, rebuild cdc demo, tear down cdc demo."
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
standard CLI commands (`snow`, `psql`, `curl`, `jq`). The agent writes the one multi-line shell
step to a file at run time. That keeps the skill publishable to the
catalog and readable by anyone who opens it.

## Prerequisites

- **A role that can administer Openflow**, `OPENFLOWADMIN` by default, set up as the Openflow
  documentation describes. It owns the deployment, runtime and connector.
- **Snowflake Postgres and Openflow gen 2 (Snowflake deployment)** available in the account's
  region. Neither can be enabled from this skill.
- **`ACCOUNTADMIN`, or a role with CREATE POSTGRES INSTANCE** (the source), **CREATE INTEGRATION**
  (the external access integration the runtime uses to reach Postgres) and **CREATE DATABASE**
  (the demo database holding the rules, secret and destination tables).
- **Local `psql`, `curl`, `snow` and `jq`.** `psql` loads and changes the source, `curl` fetches
  the dataset and JDBC driver, and `snow` and `jq` make the one credential call.
- **Outbound HTTPS** to `api.imf.org` and `jdbc.postgresql.org`.
- **A macOS or Linux shell.**

## Parameters

Part 1 step 1 resolves these and records the result. **Every later step reads names from the
state file, never from this table.**

| Parameter | Default | Reuse offered |
|---|---|---|
| `ADMIN_ROLE` | `ACCOUNTADMIN` | No |
| `OPENFLOW_ROLE` | owner of the chosen deployment, else `OPENFLOWADMIN` | Derived |
| `DEPLOYMENT` | `WEO_CDC_DEPLOYMENT` | Yes, `ACTIVE` gen 2 deployments |
| `RUNTIME_ROLE` | `OPENFLOW_CDC_ROLE` | Yes, an existing runtime's `execute_as_role` |
| `WAREHOUSE` | `OPENFLOW_WH` | Yes |
| `CONTROL_SCHEMA` | the schema holding the chosen deployment's runtimes, else `OPENFLOW_GEN2.CONTROL` | Derived |
| `RUNTIME` | `WEO_CDC_RT` | Yes, `ACTIVE` runtimes on the deployment |
| `PG_INSTANCE` | `WEO_CDC_PG` | No. If it exists: drop and recreate, or stop |
| `DEMO_DB` | `WEO_CDC_DEMO` | No. If it exists, pick another name |
| `CONNECTOR` | `WEO_PG_CDC` | No |
| `CONNECTION` | the `snow` default connection | Asked if ambiguous |

Derived, never asked: network policy `<PG_INSTANCE>_POLICY`, rules `<PG_INSTANCE>_INGRESS` and
`_EGRESS`, integration `<PG_INSTANCE>_EAI` and secret `<PG_INSTANCE>_PASSWORD`, the last three
in `<DEMO_DB>.PUBLIC`. So two builds with different instance names never collide.

## State file

`~/.cache/openflow-weo-demo/state.json`. Written by you, CoCo, with your own file tools; never by
a script. It holds the resolved parameters, the Postgres host, `created` (objects this run
created) and `done` (completed provision step numbers). Teardown drops only what `created` lists.

```json
{
  "connection": "MY_CONN",
  "params": { "DEPLOYMENT": "SPCS_GEN2", "RUNTIME_ROLE": "OPENFLOW_CDC_ROLE", "...": "..." },
  "pg_host": "abc.acct.region.aws.postgres.snowflake.app",
  "created": ["DATABASE WEO_CDC_DEMO", "POSTGRES INSTANCE WEO_CDC_PG", "..."],
  "done": [1, 2]
}
```

Update it after each step, not at the end, so an interrupted build can resume. Part 1 merges into
an existing `state.json`; it never overwrites it.

## Preflight

Run before routing. Report failures plainly and stop.

```bash
snow connection list
command -v psql curl snow jq
```

```sql
USE ROLE <OPENFLOW_ROLE>;
SHOW ROLES LIKE '<OPENFLOW_ROLE>';
```

Before Part 1 has run, `<OPENFLOW_ROLE>` is `OPENFLOWADMIN`.

- **More than one connection and none marked default: ask which to use.** Never infer it.
- `psql` missing: `brew install libpq` (macOS) and add `$(brew --prefix libpq)/bin` to `PATH`,
  or install your distribution's PostgreSQL client package (Linux).
- No `OPENFLOWADMIN`: ask which role administers Openflow in this account and use it as
  `<OPENFLOW_ROLE>`. Stop only if there is none.

**Use the Snowflake SQL tool (`sql_execute` in Cortex Code Desktop) for all Snowflake SQL**, not
`snow sql`. It reuses the session's connection, so there is no repeated OAuth prompt. `snow` is
used once, for the credential call in Part 1.

The SQL tool returns only the last statement's result, and a `USE ROLE` stays in force for later
calls in the session. Start every batch with the `USE ROLE` it needs, so no call inherits the role
from the previous one. Run dependent calls one after another, never in the same parallel batch.

**Write multi-line shell and SQL to a file, then run it** (`bash <file>`, `snow sql -f <file>`).
Heredocs hang the Cortex Code Desktop terminal.

## Step 0: discover, then route

Run these four as parallel calls, each starting `USE ROLE <OPENFLOW_ROLE>;`, because a role
needs a privilege on a deployment even to see it listed:

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
`name, status`; instance `name, state`. Then read `state.json` if it exists. Pass these results
to Part 1 so it does not run them again.

| They said | State | Do this |
|---|---|---|
| "run / present / start the demo" | **Built**: state file present, its connector `RUNNING`, its destination table holds rows | Part 2, with a one-line confirmation |
| "run / present / start the demo" | Not built | Say so and stop. Never start a provision for someone about to present |
| "provision", "build", "set up", "rebuild" | Any | Part 1 |
| "tear down", "clean up", "remove" | Any | Part 3 |
| Anything else | Any | Say what discovery found, then ask which part |

| Part | Load |
|---|---|
| 1 | `<SKILL_DIR>/provision/SKILL.md` |
| 2 | `<SKILL_DIR>/demo/SKILL.md` |
| 3 | `<SKILL_DIR>/teardown/SKILL.md` |

Load one at a time. `<SKILL_DIR>` is the path the loader printed as "Base directory for this
skill" when it loaded this router file.

## Workflow

1. **Part 1, provision**: reuse or create every object, load the data, start the connector.
2. **Part 2, demo**: six steps with the customer watching.
3. **Part 3, teardown**: drop only what Part 1 created.

## Stopping Points

- ⚠️ Part 1, every step that creates, alters or costs money: `Run it` / `Skip, already done` / `Stop here`.
- ⚠️ Part 1 step 1: the reuse questions, and the existing instance or database question.
- ⚠️ Part 2, the end of every step, including the psql gates in steps 4 and 5.
- ⚠️ Part 3: one teardown confirmation, plus an extra gate before dropping a created deployment.

## Output

Part 1 ends with real row counts, the `created` list and a filled-in presenter worksheet. Part 2
ends with the customer having seen a change arrive and revert. Part 3 ends with what was dropped
and what was kept.

## Files

| File | Use |
|---|---|
| `assets/pg-schema.sql` | Postgres tables, run by psql |
| `assets/pg-load.sql` | Postgres transform and publication, run by psql |
| `assets/connector-config.template.json` | Connector configuration with five placeholders |
| `assets/cdc.sql` | Snowsight worksheet for the presenter, with the talk track in comments |
| `references/gotchas.md` | **Read before debugging anything** |
| `references/customer-qa.md` | Background for customer questions about gen 2 |
| `references/weo-data.md` | The dataset, the API and vintage changes |
| `evals/evals.md` | Routing, static and collision checks to run after any change |

## Status

Last verified: 2026-11-27, end to end on Openflow gen 2 (Snowflake deployment), Snowflake
Postgres 17, BURST_S: provision with existing role, warehouse and deployment reused; snapshot of
361,508 rows; change and revert each under 15 seconds; teardown dropped only what it created.
Resume after an interrupted build has not been exercised.
