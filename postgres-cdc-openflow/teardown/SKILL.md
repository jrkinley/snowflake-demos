---
name: openflow-gen2-pg-cdc-teardown
description: "Part 3 of postgres-cdc-openflow. Load only from that skill's router, never directly."
parent_skill: postgres-cdc-openflow
---

# Part 3: Teardown

Not customer-facing. Irreversible: there is no undrop for a Postgres instance, runtime or
connector.

## Scope: only what was created

Read `~/.cache/openflow-weo-demo/state.json`. **Drop only objects listed in `created`.** Anything
reused (deployment, runtime, role, warehouse, control schema) stays. If the state file is
missing, stop and ask; never fall back to dropping by default name.

Show the list as a table of `object` and `created or reused`, then one gate:
`Tear down the created objects` / `Cancel`. A created deployment gets its own extra gate,
because it is the expensive one to leave and the slow one to rebuild.

## Order

Each group runs only if its objects are in `created`. Reused runtimes still get one change:
remove the demo EAI (group 2b), so nothing keeps a reference to a dropped integration.

**Issue every `DROP` as its own call after confirming the terminal state with `SHOW`.** The wait
functions return `OK` while `SHOW` still says `TERMINATING`, and a `DROP` in the same batch is
rejected. Retry a refused `DROP` once.

### 1. Connector

```sql
USE ROLE <OPENFLOW_ROLE>;
ALTER OPENFLOW CONNECTOR IF EXISTS <CONTROL_SCHEMA>.<CONNECTOR> STOP;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, '<CONTROL_SCHEMA>.<CONNECTOR>');
ALTER OPENFLOW CONNECTOR IF EXISTS <CONTROL_SCHEMA>.<CONNECTOR> TERMINATE;
```

Poll `SHOW OPENFLOW CONNECTORS LIKE '<CONNECTOR>' IN SCHEMA <CONTROL_SCHEMA>` every 15 s until `TERMINATED`, at most 20 checks, then:

```sql
USE ROLE <OPENFLOW_ROLE>;
DROP OPENFLOW CONNECTOR IF EXISTS <CONTROL_SCHEMA>.<CONNECTOR>;
```

### 2a. Runtime, if created

```sql
USE ROLE <OPENFLOW_ROLE>;
ALTER OPENFLOW RUNTIME IF EXISTS <CONTROL_SCHEMA>.<RUNTIME> SUSPEND;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES(900, '<CONTROL_SCHEMA>.<RUNTIME>');
ALTER OPENFLOW RUNTIME IF EXISTS <CONTROL_SCHEMA>.<RUNTIME> TERMINATE;
```

Poll `SHOW OPENFLOW RUNTIMES LIKE '<RUNTIME>' IN SCHEMA <CONTROL_SCHEMA>` every 30 s until `TERMINATED`, at most 30 checks, then:

```sql
USE ROLE <OPENFLOW_ROLE>;
DROP OPENFLOW RUNTIME IF EXISTS <CONTROL_SCHEMA>.<RUNTIME>;
```

If a poll reaches its limit, stop and report the last status.

### 2b. Runtime, if reused

```sql
USE ROLE <OPENFLOW_ROLE>;
ALTER OPENFLOW RUNTIME <CONTROL_SCHEMA>.<RUNTIME> REMOVE EXTERNAL_ACCESS_INTEGRATIONS = (<PG_INSTANCE>_EAI);
```

### 3. Access integration

```sql
USE ROLE <ADMIN_ROLE>;
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS <PG_INSTANCE>_EAI;
```

### 4. Postgres, policy, database

Each object only if listed in `created`. Enforced order: the instance holds the policy, and the
policy references a rule inside the database.

```sql
USE ROLE <ADMIN_ROLE>;
DROP POSTGRES INSTANCE IF EXISTS <PG_INSTANCE>;
DROP NETWORK POLICY IF EXISTS <PG_INSTANCE>_POLICY;
DROP DATABASE IF EXISTS <DEMO_DB>;   -- tables, journal, rules, secret, stage, file format
```

### 5. Foundations, if created

Each only if listed in `created`, after the gate for the deployment:

```sql
USE ROLE <ADMIN_ROLE>;
DROP WAREHOUSE IF EXISTS <WAREHOUSE>;
DROP ROLE IF EXISTS <RUNTIME_ROLE>;
```

```sql
USE ROLE <OPENFLOW_ROLE>;
DROP OPENFLOW DEPLOYMENT IF EXISTS <DEPLOYMENT>;
```

Drop `OPENFLOW_GEN2` only if it is listed in `created` and `SHOW OPENFLOW RUNTIMES IN SCHEMA
OPENFLOW_GEN2.CONTROL` returns nothing:

```sql
USE ROLE <OPENFLOW_ROLE>;
DROP DATABASE IF EXISTS OPENFLOW_GEN2;
```

## Verify

Each as its own call, starting with `USE ROLE <ADMIN_ROLE>;` (`<OPENFLOW_ROLE>` for the Openflow
checks). Each is empty for created objects, and still present for reused ones:

```sql
SHOW OPENFLOW CONNECTORS LIKE '<CONNECTOR>' IN ACCOUNT;
```
```sql
SHOW POSTGRES INSTANCES LIKE '<PG_INSTANCE>';
```
```sql
SHOW DATABASES LIKE '<DEMO_DB>';
```
```sql
SHOW EXTERNAL ACCESS INTEGRATIONS LIKE '<PG_INSTANCE>_EAI';
```
```sql
SHOW OPENFLOW RUNTIMES LIKE '<RUNTIME>' IN ACCOUNT;
```
```sql
SHOW OPENFLOW DEPLOYMENTS LIKE '<DEPLOYMENT>';
```
```sql
SHOW WAREHOUSES LIKE '<WAREHOUSE>';
```
```sql
SHOW ROLES LIKE '<RUNTIME_ROLE>';
```

## Local cleanup

Remove only this demo's `~/.pgpass` line, never the file, which holds other servers' logins:

```bash
umask 077
HOST=<pg_host>
grep -v "^$HOST:" ~/.pgpass > ~/.pgpass.tmp; mv ~/.pgpass.tmp ~/.pgpass; chmod 600 ~/.pgpass
rm -rf ~/.cache/openflow-weo-demo/bundle ~/.cache/openflow-weo-demo/state.json ~/.cache/openflow-weo-demo/cdc.sql \
  ~/.cache/openflow-weo-demo/reset-access.sql ~/.cache/openflow-weo-demo/credential.sh
```

Keep `weo.csv`; it saves a download next time.

## Output

Report what was dropped and what was kept. If a reused or kept deployment remains, say that a
deployment bills while idle and nothing caps it, so keeping it is a conscious choice. Rates are
in the [Snowflake Credit Consumption Table](https://www.snowflake.com/legal-files/CreditConsumptionTable.pdf).
