---
name: postgres-cdc-openflow
version: 1.0.0
description: "Demo the Openflow gen 2 PostgreSQL CDC connector end to end, built entirely from Snowflake SQL objects. Provisions a Snowflake Postgres source loaded with the full IMF World Economic Outlook dataset, a gen 2 deployment, runtime and connector, then walks through change data capture live with a customer watching. Includes teardown. Triggers: run my postgres cdc demo, run my pg cdc demo, run my cdc demo, my postgres cdc demo, postgres cdc demo, pg cdc demo, openflow gen 2 cdc demo, gen2 postgres cdc demo, openflow cdc demo, demo postgres cdc, run the cdc demo, present the cdc demo, provision cdc demo, rebuild cdc demo, tear down cdc demo. This is the gen 2 SQL-object demo and is the one to use; prefer it over any gen 1 postgres-cdc-demo skill unless the user explicitly says gen 1 or nipyapi."
---

# Openflow gen 2 PostgreSQL CDC demo

## Summary

Change a row in a Snowflake Postgres database and watch it land in a Snowflake table about half a minute later. The Openflow gen 2 PostgreSQL CDC connector replicates a source loaded with the full IMF World Economic Outlook dataset, and every object, connector included, is created from Snowflake SQL. The story: real-time replication from an operational Postgres into Snowflake with no pipeline code to maintain.

Three parts. **Discover what exists first, then ask which part to run.** Never assume.

| Part | What it does | Customer present? |
|---|---|---|
| 1. Provision | Builds everything. 25 to 35 minutes. | No |
| 2. Demo CDC | Five guided steps, about fifteen minutes. | **Yes** |
| 3. Teardown | Removes everything this skill created. | No |

Run Part 1 the day before. Provisioning involves a two-minute Postgres create, a snapshot
of roughly 360,000 rows and a known transient failure. None of that is watchable.

## Setup

**Resolve `<SKILL_DIR>` once**, to the absolute path of the directory holding this file. The
skill is usually installed as a symlink outside the working directory, so relative paths like
`scripts/load-weo-data.py` resolve against the wrong place:

```bash
# Resolve from the directory holding this SKILL.md, for example:
SKILL_DIR=$(cd "$(dirname "<path to this SKILL.md>")" && pwd -P)
# When installed as a Cortex Code skill this is typically
# ~/.snowflake/cortex/skills/postgres-cdc-openflow
```

**Establish the `snow` connection before anything else.** Most work runs through the
`snowflake_sql_execute` tool, which uses the session's existing connection and needs no token of
its own. The CLI is still needed for `snow stage copy` and the two scripts in `scripts/`, and
those take `-c <name>`.

```bash
snow connection list
```

**If more than one connection is listed and none is marked default, stop and ask which to
use.** Do not infer it from the account name or pick the first. Provisioning a Postgres
instance into the wrong account is slow to notice and annoying to unpick.

Note that `default_connection_name` in `~/.snowflake/config.toml` can name a connection that
does not exist, in which case there is no usable default however it looks.

**Prefer `snowflake_sql_execute` over `snow sql` throughout.** Each `snow sql` call is a
separate process that authenticates on its own, so on an OAuth connection it triggers a browser
prompt. Across a full provision that is dozens of interruptions for no benefit.

Detail lives in `references/`, loaded on demand rather than up front:

| File | Read it when |
|---|---|
| [provision.md](references/provision.md) | Before running Part 1 |
| [teardown.md](references/teardown.md) | Before running Part 3 |
| [weo-data.md](references/weo-data.md) | The dataset is missing or a new vintage lands |
| [gotchas.md](references/gotchas.md) | **Before debugging anything** |

## Step 0: discover, then route

Run these before asking the user anything:

```sql
SHOW OPENFLOW DEPLOYMENTS;
SHOW OPENFLOW RUNTIMES IN ACCOUNT;
SHOW OPENFLOW CONNECTORS IN ACCOUNT;
SHOW POSTGRES INSTANCES;
```

Each returns a dozen or more columns. **Report only these**, so every run reports the same
shape:

| Object | Columns | Also worth saying |
|---|---|---|
| Deployment | `name`, `status`, `comment` | The comment often records whether it is permanent. Carry that into teardown. |
| Runtime | `name`, `status`, `deployment` | |
| Connector | `name`, `status` | |
| Postgres instance | `name`, `state` | |

Then, if `WEO_CDC_DEMO.WEO.OBSERVATIONS` exists:

```sql
SELECT COUNT(*) FROM WEO_CDC_DEMO.WEO.OBSERVATIONS;
```

**If a connector exists, is `RUNNING`, and that count is above zero**, the demo is already
built. Do not reprovision without being asked.

## Routing

**Read the user's wording before asking anything.** They may be about to share their screen.

| They said | Do this |
|---|---|
| "run my postgres cdc demo", "run the demo", "present the demo", "start the demo", or anything else demo-only | **Go straight to Part 2. Do not ask.** Report nothing but a one-line confirmation that the connector is running and the row count is good. |
| "provision", "build", "rebuild", "set up" | Part 1 |
| "tear down", "clean up", "remove" | Part 3 |
| Anything ambiguous | Say what discovery found, then ask which part |

If the wording is demo-only but discovery shows the demo is **not** built, say so plainly and
stop. Do not start a 25-minute provision for someone who is about to present.

| Part | Load |
|---|---|
| 1. Provision | `<SKILL_DIR>/provision/SKILL.md` |
| 2. Demo CDC | `<SKILL_DIR>/demo/SKILL.md` |
| 3. Teardown | `<SKILL_DIR>/teardown/SKILL.md` |

Load one at a time: Part 2 is screen-shared, and provisioning detail on a customer's screen is
noise.

## Prerequisites

Three objects are **reused rather than created**, so they must already exist:
`OPENFLOW_GEN2.CONTROL` (the gen 2 control schema, owned by `OPENFLOWADMIN`), role
`OPENFLOW_CDC_ROLE`, and warehouse `OPENFLOW_WH`. Part 1 fails at the grants step without
them. Names are overridable, but the skill does not create them.

Locally: `snow`, `psql` and `uv`, and a role that reaches `ACCOUNTADMIN`.

## Run the demo

Load `<SKILL_DIR>/demo/SKILL.md` (Part 2). Five guided steps on a shared screen; the moment that lands is an `UPDATE` in Postgres appearing in the Snowflake table about half a minute later.

## Teardown

Load `<SKILL_DIR>/teardown/SKILL.md` (Part 3). It removes every object Part 1 created, including the Postgres instance.

## Status

Last verified: 2026-09-28

Known issues and their fixes are in `references/gotchas.md`. Two gaps against this repository's rules are still open:

- **Least privilege.** Part 1 reuses an existing role (`OPENFLOW_CDC_ROLE`) and warehouse (`OPENFLOW_WH`) rather than creating its own, and runs the database, secret and grant steps as `ACCOUNTADMIN`.
- **Fixed names.** The role, warehouse and `OPENFLOW_GEN2.CONTROL` names are written into the SQL, so overriding them means editing the steps.
