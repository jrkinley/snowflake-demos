---
name: openflow-gen2-pg-cdc-teardown
description: "Part 3 of the Openflow gen 2 PostgreSQL CDC demo: remove everything the skill created, in dependency order, with a gate before each group."
parent_skill: postgres-cdc-openflow
---

# Part 3: Teardown

## When to load

The demo is finished. Not customer-facing. Everything here is irreversible and there is no
undrop.

## How to run SQL

Use `snowflake_sql_execute`, not `snow sql`. Reasoning is in `provision/SKILL.md`; it applies
equally here, and teardown has a specific need for it: the `DROP` statements must be separate
calls, and separate `snow sql` processes mean separate OAuth prompts.

`USE ROLE` applies only within the call it appears in, so each group below repeats it.

## Workflow

Run the five groups below **in order, asking before each one**. Reasoning for the ordering is in
[../references/teardown.md](../references/teardown.md).

Three things to get right, all verified the hard way:

- **Issue each `DROP` as its own call, not chained after `TERMINATE`.**
  `SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS` and its runtime equivalent return `OK` while
  `SHOW` still reports `TERMINATING`, and a `DROP` in the same batch is rejected. Confirm the
  terminal state first, and retry the `DROP` once if it is refused.
- **Drop the Postgres instance, then the network policy, then the database.** The instance
  holds the policy and the policy references a rule inside the database. This is enforced, not
  advisory: dropping the policy first fails outright.
- **Only drop the deployment if this skill created it.** A pre-existing one is shared. If the
  skill did create one, drop it: dropping the runtime alone leaves the control pool billing
  around 2.64 credits a day, and nothing will chase it.

The secret needs no separate step. It lives in `WEO_CDC_DEMO.PUBLIC`, so the database drop
takes it.

Not dropped, deliberately: `OPENFLOW_GEN2.CONTROL`, `OPENFLOW_CDC_ROLE` and `OPENFLOW_WH`, all
reused rather than created.

### Group 1: the connector

`TERMINATE` drains in-flight data; `TERMINATE FORCE` discards it. This does not remove the
destination tables, nor the Postgres replication slot on the source. The slot goes with the
instance in group 4.

```sql
USE ROLE OPENFLOWADMIN;

ALTER OPENFLOW CONNECTOR IF EXISTS OPENFLOW_GEN2.CONTROL.WEO_PG_CDC STOP;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'OPENFLOW_GEN2.CONTROL.WEO_PG_CDC');

ALTER OPENFLOW CONNECTOR IF EXISTS OPENFLOW_GEN2.CONTROL.WEO_PG_CDC TERMINATE;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'OPENFLOW_GEN2.CONTROL.WEO_PG_CDC');

SHOW OPENFLOW CONNECTORS IN ACCOUNT;
```

Confirm `TERMINATED` in that output, then drop as a **separate call**:

```sql
USE ROLE OPENFLOWADMIN;
DROP OPENFLOW CONNECTOR IF EXISTS OPENFLOW_GEN2.CONTROL.WEO_PG_CDC;
```

### Group 2: the runtime

Same caveat as the connector. Dropping the runtime detaches its external access integration, so
there is no manual detach step as there is in gen 1.

```sql
USE ROLE OPENFLOWADMIN;

ALTER OPENFLOW RUNTIME IF EXISTS OPENFLOW_GEN2.CONTROL.WEO_CDC_RT SUSPEND;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES(900, 'OPENFLOW_GEN2.CONTROL.WEO_CDC_RT');

ALTER OPENFLOW RUNTIME IF EXISTS OPENFLOW_GEN2.CONTROL.WEO_CDC_RT TERMINATE;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES(900, 'OPENFLOW_GEN2.CONTROL.WEO_CDC_RT');

SHOW OPENFLOW RUNTIMES IN ACCOUNT;
```

Confirm `TERMINATED`, then, as a separate call:

```sql
USE ROLE OPENFLOWADMIN;
DROP OPENFLOW RUNTIME IF EXISTS OPENFLOW_GEN2.CONTROL.WEO_CDC_RT;
```

### Group 3: access objects

The runtime above held the EAI, so this order works. The secret is not here: it lives in
`WEO_CDC_DEMO.PUBLIC`, so group 4 takes it with the database.

```sql
USE ROLE ACCOUNTADMIN;

DROP EXTERNAL ACCESS INTEGRATION IF EXISTS WEO_CDC_PG_EAI;
DROP NETWORK RULE IF EXISTS WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_EGRESS;
```

### Group 4: source and destination

Dependency order matters and is enforced, not merely advisory: dropping the policy first fails
with "The policy is attached to POSTGRES with name WEO_CDC_PG". The instance holds the network
policy, and the policy references a network rule that lives inside `WEO_CDC_DEMO`.

```sql
USE ROLE ACCOUNTADMIN;

DROP POSTGRES INSTANCE IF EXISTS WEO_CDC_PG;
DROP NETWORK POLICY IF EXISTS WEO_CDC_PG_POLICY;
DROP DATABASE IF EXISTS WEO_CDC_DEMO;   -- tables, journal, ingress rule, secret
```

### Group 5: verify

Everything below should come back empty, except the deployment, which should still be listed
unless the skill created it this run.

```sql
SHOW OPENFLOW CONNECTORS IN ACCOUNT;
SHOW OPENFLOW RUNTIMES IN ACCOUNT;
SHOW OPENFLOW DEPLOYMENTS;
SHOW POSTGRES INSTANCES LIKE 'WEO_CDC_PG';
SHOW DATABASES LIKE 'WEO_CDC_DEMO';
SHOW EXTERNAL ACCESS INTEGRATIONS LIKE '%WEO_CDC%';
SHOW NETWORK POLICIES LIKE 'WEO_CDC%';
SHOW SECRETS LIKE 'WEO_CDC%' IN ACCOUNT;   -- 0 confirms the database drop took it
```

Send these as separate calls, or as one batch knowing only the last result comes back. Separate
calls are clearer here, since the point is that each one is empty.

## Local cleanup

```bash
rm -f postgresql-42.7.8.jar config.json
```

**Remove only this demo's `~/.pgpass` entry, not the file.** `~/.pgpass` holds credentials for
every Postgres server the user connects to, so deleting it destroys unrelated logins:

```bash
PG_HOST=$(cat ~/.cache/openflow-weo-demo/pg-host 2>/dev/null)
if [ -n "$PG_HOST" ] && [ -f ~/.pgpass ]; then
  grep -v "^${PG_HOST}:" ~/.pgpass > ~/.pgpass.tmp && mv ~/.pgpass.tmp ~/.pgpass
  chmod 600 ~/.pgpass
fi
rm -f ~/.cache/openflow-weo-demo/pg-host
```

The host cache is removed too, because the hostname changes on every rebuild and a stale one
silently sends the next provision at an instance that no longer exists.

Keep the rest of `~/.cache/openflow-weo-demo/`. It holds the WEO export and saves a manual
download next time.

## Output

Report which groups ran and confirm the verification counts. If the deployment survived, say
so explicitly along with its idle cost, so the decision to keep it is a conscious one.
