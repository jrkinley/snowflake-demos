---
name: openflow-gen2-pg-cdc-provision
description: "Part 1 of postgres-cdc-openflow. Load only from that skill's router, never directly."
parent_skill: postgres-cdc-openflow
---

# Part 1: Provision

Not customer-facing. 20 to 30 minutes, most of it waiting on Snowflake.

`<NAME>` placeholders are parameters from the router. Substitute the resolved value from
`state.json` everywhere, including inside SQL and file paths. `<SKILL_DIR>` is the skill root.

## How each step runs

Every step follows the same pattern, so the SE always knows what is about to happen:

1. **Say what the step does** in one sentence.
2. **Show the exact SQL or command**, with values substituted, in a fenced block.
3. **Stop for approval** with `ask_user_question`: `Run it` / `Skip, already done` / `Stop here`.
   Skip only gates the step; never skip a verification query.
4. **Check before you create.** Before a gated `CREATE`, run `SHOW <type> LIKE '<name>'` in the
   right scope. If the object exists, offer `Reuse it` / `Stop` and record it as reused. Only an
   object this run created goes into `created`, because teardown drops everything listed there.
   Gated creates have no `IF NOT EXISTS`, so a collision fails loudly instead of being recorded
   as new.
5. Run it, show the verification result, update `state.json`, and append the step number to `done`.

Read-only discovery and verification queries run without a gate. Anything that creates, alters
or costs money gets one. If a statement fails, show the error, check
`<SKILL_DIR>/references/gotchas.md`, and stop. Do not improvise fixes.

Every poll has a limit. When it is reached, stop and report the last status.

## Resume

If `state.json` exists with entries in `done`, say which steps are done and ask:
`Resume from step N` / `Start over (teardown first)` / `Stop`. On resume, skip every step in
`done` and keep the existing `created`.

## Step 1: Reuse or create

Use the router's Step 0 results. Add only these, as parallel read-only calls, each starting
`USE ROLE <OPENFLOW_ROLE>;`:

```sql
SHOW ROLES LIKE '%OPENFLOW%';
```
```sql
SHOW WAREHOUSES;
```

Then ask **one** `ask_user_question` call, one question per component that has candidates. Each
lists the existing objects as options plus `Create new <default name>`. Put what you found in
chat text before the call.

| Component | Offer | If creating |
|---|---|---|
| Deployment | Gen 2 deployments with status `ACTIVE`. Show each `comment` | `WEO_CDC_DEPLOYMENT`. Say: 5 to 10 minutes; a deployment bills while idle and nothing caps it, rates are in the [Snowflake Credit Consumption Table](https://www.snowflake.com/legal-files/CreditConsumptionTable.pdf); the docs currently limit an account to three deployments across gen 1 and gen 2 |
| Runtime role | Roles granted to `<OPENFLOW_ROLE>` that are an existing runtime's `execute_as_role` | `OPENFLOW_CDC_ROLE` |
| Warehouse | Warehouses `<RUNTIME_ROLE>` already uses, else any XSMALL or SMALL | `OPENFLOW_WH`, XSMALL, auto-suspend 60 |
| Runtime | `ACTIVE` runtimes on the chosen deployment | `WEO_CDC_RT`, MEDIUM M4, 1 node. **Default to create**: a reused runtime gets a demo EAI added and teardown leaves it in place |

With exactly one candidate, still ask: reuse is the user's decision. With none, say what will be
created and move on without a question for that component.

Two parameters are derived, not asked. `OPENFLOW_ROLE` is the owner of the chosen deployment,
else `OPENFLOWADMIN`. `CONTROL_SCHEMA` is the `database_name.schema_name` of the deployment's
existing runtimes, else `OPENFLOW_GEN2.CONTROL` (created in step 2).

Then check `<PG_INSTANCE>` in the Step 0 results and run `SHOW DATABASES LIKE '<DEMO_DB>'`. If
either exists, ask a second `ask_user_question`:

- Instance: `Drop and recreate` / `Stop`. An existing instance's network policy points at a rule
  in a database this run does not own, so it is not reused. Drop and recreate shows and runs, as
  `<ADMIN_ROLE>`, `DROP POSTGRES INSTANCE <PG_INSTANCE>;` and, if it exists,
  `DROP NETWORK POLICY <PG_INSTANCE>_POLICY;`. Step 2 and step 3 then create both, so they go
  into `created`.
- Database: `Stop` only. Teardown removes the demo's rules, secret and stage by dropping the
  database, so it must be one this run created. Ask for a different `<DEMO_DB>` and re-check.

Merge the choices into `state.json` and append `1` to `done`.

## Step 2: Foundations and demo database

One gate covers every block below whose object is being created; the deployment, if created, has
its own. Leave out of the batch any statement whose object was reused. The grants always run.

**Deployment**, as `<OPENFLOW_ROLE>`, behind its own gate because it is slow and bills while idle:

```sql
USE ROLE <OPENFLOW_ROLE>;
CREATE OPENFLOW DEPLOYMENT <DEPLOYMENT>
  DEPLOYMENT_TYPE = SNOWFLAKE
  DISPLAY_NAME = 'WEO CDC demo';
```

Poll `SHOW OPENFLOW DEPLOYMENTS` every 60 s until `ACTIVE`, at most 15 checks.

**Control schema**, only when it is `OPENFLOW_GEN2.CONTROL`. Leave out whichever of the database
and schema already exists (check with `SHOW DATABASES LIKE 'OPENFLOW_GEN2'` and
`SHOW SCHEMAS LIKE 'CONTROL' IN DATABASE OPENFLOW_GEN2`):

```sql
USE ROLE <OPENFLOW_ROLE>;
CREATE DATABASE OPENFLOW_GEN2;
CREATE SCHEMA OPENFLOW_GEN2.CONTROL;
```

**Runtime role, warehouse, demo database and Postgres network policy**, as `<ADMIN_ROLE>`
because they need CREATE ROLE, CREATE WAREHOUSE, CREATE DATABASE and CREATE NETWORK POLICY. The
database holds the ingress rule, the policy references the rule, and the instance references the
policy, so this order is enforced:

```sql
USE ROLE <ADMIN_ROLE>;
CREATE ROLE <RUNTIME_ROLE>;
GRANT ROLE <RUNTIME_ROLE> TO ROLE <OPENFLOW_ROLE>;
CREATE WAREHOUSE <WAREHOUSE>
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
CREATE DATABASE <DEMO_DB>
  COMMENT = 'Openflow gen 2 Postgres CDC demo. Safe to drop with the demo.';
CREATE SCHEMA IF NOT EXISTS <DEMO_DB>.WEO;
CREATE NETWORK RULE <DEMO_DB>.PUBLIC.<PG_INSTANCE>_INGRESS
  TYPE = IPV4 VALUE_LIST = ('0.0.0.0/0') MODE = POSTGRES_INGRESS;
CREATE NETWORK POLICY <PG_INSTANCE>_POLICY
  ALLOWED_NETWORK_RULE_LIST = ('<DEMO_DB>.PUBLIC.<PG_INSTANCE>_INGRESS');
```

Ingress is open so `psql` works from a laptop on any network. Fine for a demo account. Say so.

**Grants**, always, reused or not. `<ADMIN_ROLE>` because the control schema and warehouse may be
owned by another role. The database in the first grant is the database part of
`<CONTROL_SCHEMA>`:

```sql
USE ROLE <ADMIN_ROLE>;
GRANT USAGE ON DATABASE <database part of CONTROL_SCHEMA> TO ROLE <RUNTIME_ROLE>;
GRANT USAGE ON SCHEMA <CONTROL_SCHEMA> TO ROLE <RUNTIME_ROLE>;
GRANT USAGE, OPERATE ON WAREHOUSE <WAREHOUSE> TO ROLE <RUNTIME_ROLE>;
```

## Step 3: Postgres instance

`CREATE POSTGRES INSTANCE` returns the `snowflake_admin` password once. **Never run it bare**:
the output would put a live password on a screen. This block runs it as `<ADMIN_ROLE>`, which
holds CREATE POSTGRES INSTANCE, and returns only the host. Step 4 sets the password.

```sql
EXECUTE IMMEDIATE $$
DECLARE
  qid STRING;
  h STRING;
BEGIN
  USE ROLE <ADMIN_ROLE>;
  CREATE POSTGRES INSTANCE <PG_INSTANCE>
    COMPUTE_FAMILY = 'BURST_S'
    STORAGE_SIZE_GB = 10
    AUTHENTICATION_AUTHORITY = POSTGRES
    POSTGRES_VERSION = 17
    NETWORK_POLICY = '<PG_INSTANCE>_POLICY'
    COMMENT = 'Source for the Openflow gen 2 CDC demo. Safe to drop with the demo.';
  qid := LAST_QUERY_ID();
  SELECT "host" INTO :h FROM TABLE(RESULT_SCAN(:qid));
  RETURN :h;
END;
$$;
```

Save the returned host as `pg_host` in `state.json`. BURST_S on 10 GB is ample, and `wal_level`
is already `logical` on a new PG 17 instance, so there is no restart.

Poll every 30 s until `READY`, at most 20 checks (10 minutes). It usually takes about three
minutes through `CREATING` and `FINALIZING`:

```sql
DESCRIBE POSTGRES INSTANCE <PG_INSTANCE>
  ->> SELECT "value" AS state FROM $1 WHERE "property" = 'state';
```

On "Internal error occurred", check `SHOW POSTGRES INSTANCES` shows nothing and retry once.

## Step 4: Give psql the password, without showing it

psql runs on this laptop, so the password has to land in `~/.pgpass`. A secret cannot be read
back, so this step **resets** the password, writes it to the secret and returns it to a shell
variable. It is never echoed and never on a command line. Also use this step to recover a lost
`~/.pgpass`.

Write this to `~/.cache/openflow-weo-demo/reset-access.sql` with your file write tool. It holds
no secret:

```sql
EXECUTE IMMEDIATE $$
DECLARE
  qid STRING;
  pw STRING;
BEGIN
  USE ROLE <ADMIN_ROLE>;
  ALTER POSTGRES INSTANCE <PG_INSTANCE> RESET ACCESS FOR 'snowflake_admin';
  qid := LAST_QUERY_ID();
  SELECT "password" INTO :pw FROM TABLE(RESULT_SCAN(:qid));
  EXECUTE IMMEDIATE 'CREATE OR REPLACE SECRET <DEMO_DB>.PUBLIC.<PG_INSTANCE>_PASSWORD '
    || 'TYPE = GENERIC_STRING SECRET_STRING = ''' || REPLACE(:pw, '''', '''''') || '''';
  RETURN :pw;
END;
$$;
```

Then write this to `~/.cache/openflow-weo-demo/credential.sh` and run it with `bash`:

```bash
umask 077
HOST=<pg_host>
PW=$(snow sql -c <CONNECTION> --format json -f "$HOME/.cache/openflow-weo-demo/reset-access.sql" | jq -r '.[0]["anonymous block"]')
case "$PW" in ""|null|*:*) echo "credential call failed, ~/.pgpass unchanged"; exit 1;; esac
touch ~/.pgpass
grep -v "^$HOST:" ~/.pgpass > ~/.pgpass.tmp; printf '%s:5432:*:snowflake_admin:%s\n' "$HOST" "$PW" >> ~/.pgpass.tmp
mv ~/.pgpass.tmp ~/.pgpass; chmod 600 ~/.pgpass
echo "password length ${#PW}"; unset PW
psql "host=$HOST port=5432 user=snowflake_admin dbname=postgres sslmode=require" -Atc "select version()"
```

`<ADMIN_ROLE>` because it owns the instance and creates the secret in `<DEMO_DB>`. Expect
`password length 64` and a PostgreSQL 17 version string. Anything else: stop. Query history keeps
only the statement prefix of the `CREATE SECRET`, not the value (checked 2026-11-27).

The `snow` call prompts for auth on an OAuth connection. That is expected and happens once.

## Step 5: Load the IMF WEO dataset into Postgres

The full World Economic Outlook from the IMF's public SDMX API: about 32 MB and 360,000
observations, no key. See `<SKILL_DIR>/references/weo-data.md`.

```bash
mkdir -p ~/.cache/openflow-weo-demo
curl -sS --fail -H 'Accept: application/vnd.sdmx.data+csv;version=2.0.0' \
  'https://api.imf.org/external/sdmx/3.0/data/dataflow/IMF.RES/WEO/+/*?attributes=SCALE,UNIT,PUBLICATION_DATE,LATEST_ACTUAL_ANNUAL_DATA' \
  -o ~/.cache/openflow-weo-demo/weo.csv && wc -l ~/.cache/openflow-weo-demo/weo.csv

PGC="host=<pg_host> port=5432 user=snowflake_admin dbname=postgres sslmode=require"
psql "$PGC" -q -v ON_ERROR_STOP=1 -f <SKILL_DIR>/assets/pg-schema.sql
psql "$PGC" -q -v ON_ERROR_STOP=1 -c "\copy weo.observations_raw FROM '$HOME/.cache/openflow-weo-demo/weo.csv' CSV HEADER"
psql "$PGC" -v ON_ERROR_STOP=1 -f <SKILL_DIR>/assets/pg-load.sql
```

About a minute. The last command prints rows, countries and indicators. **Report those figures,
not expected ones**: every WEO vintage moves them.

`pg-schema.sql` drops and recreates the table, and `pg-load.sql` recreates the publication.
They must always run together: `DROP TABLE` silently removes a table from its publication, and CDC
then replicates nothing with no error anywhere.

## Step 6: Destination grants, secret access and egress

**All of this must be in place before the connector's first START.** `CREATE STREAM` especially:
without it the snapshot succeeds and the connector reports `RUNNING`, but the first change marks
the table `FAILED` and that state is never retried. `<ADMIN_ROLE>` because it owns `<DEMO_DB>`
and holds CREATE INTEGRATION.

```sql
USE ROLE <ADMIN_ROLE>;
GRANT USAGE ON DATABASE <DEMO_DB> TO ROLE <RUNTIME_ROLE>;
GRANT CREATE SCHEMA ON DATABASE <DEMO_DB> TO ROLE <RUNTIME_ROLE>;
GRANT USAGE, CREATE TABLE, CREATE STREAM, CREATE VIEW ON SCHEMA <DEMO_DB>.WEO TO ROLE <RUNTIME_ROLE>;
GRANT USAGE, CREATE TABLE, CREATE STREAM ON FUTURE SCHEMAS IN DATABASE <DEMO_DB> TO ROLE <RUNTIME_ROLE>;

-- The connector owns what it creates. These let you query your own demo data.
GRANT SELECT ON FUTURE TABLES IN DATABASE <DEMO_DB> TO ROLE <ADMIN_ROLE>;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE <DEMO_DB> TO ROLE <ADMIN_ROLE>;

-- Secret access needs BOTH: READ on the secret and USAGE on its schema.
GRANT USAGE ON SCHEMA <DEMO_DB>.PUBLIC TO ROLE <RUNTIME_ROLE>;
GRANT READ ON SECRET <DEMO_DB>.PUBLIC.<PG_INSTANCE>_PASSWORD TO ROLE <RUNTIME_ROLE>;

-- Lets cdc.sql read the connector's config.json with SELECT.
CREATE FILE FORMAT IF NOT EXISTS <DEMO_DB>.PUBLIC.RAW_JSON TYPE = JSON;

-- CREATE NETWORK RULE checks the host resolves, which is why Postgres came first.
-- The rule lives in <DEMO_DB>, which this run created. The integration is account-level, so it
-- gets the rule 4 existence check and fails loudly on a collision.
CREATE OR REPLACE NETWORK RULE <DEMO_DB>.PUBLIC.<PG_INSTANCE>_EGRESS
  MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('<pg_host>:5432');
CREATE EXTERNAL ACCESS INTEGRATION <PG_INSTANCE>_EAI
  ALLOWED_NETWORK_RULES = (<DEMO_DB>.PUBLIC.<PG_INSTANCE>_EGRESS) ENABLED = TRUE
  COMMENT = 'Lets the gen 2 CDC runtime reach the demo Postgres instance.';
GRANT USAGE ON INTEGRATION <PG_INSTANCE>_EAI TO ROLE <RUNTIME_ROLE>;
```

## Step 7: Runtime

**Creating.** Three to five minutes, dominated by the wait:

```sql
USE ROLE <OPENFLOW_ROLE>;
CREATE OPENFLOW RUNTIME <CONTROL_SCHEMA>.<RUNTIME>
  IN DEPLOYMENT <DEPLOYMENT>
  NODE_TYPE = MEDIUM NODE_TYPE_TIER = 'M4' MIN_NODES = 1 MAX_NODES = 1
  EXECUTE_AS_ROLE = <RUNTIME_ROLE>
  EXTERNAL_ACCESS_INTEGRATIONS = (<PG_INSTANCE>_EAI)
  COMMENT = 'Runs the WEO Postgres CDC connector. Demo-scoped, safe to drop.';
```

**Reusing:**

```sql
USE ROLE <OPENFLOW_ROLE>;
ALTER OPENFLOW RUNTIME <CONTROL_SCHEMA>.<RUNTIME> ADD EXTERNAL_ACCESS_INTEGRATIONS = (<PG_INSTANCE>_EAI);
```

Then poll every 30 s until `ACTIVE`, at most 20 checks:

```sql
SHOW OPENFLOW RUNTIMES LIKE '<RUNTIME>' IN SCHEMA <CONTROL_SCHEMA>;
```

Poll with `SHOW`, not `SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES`: the wait function has been
seen erroring while the runtime is still `CREATING`, moments before it went `ACTIVE`.

## Step 8: Connector, from a configuration bundle

The connector is created **from a complete configuration bundle** on a stage, so it starts with
a committed `VERSION$1` and needs no edit, commit or second upload. This is the same mechanism
used to promote a connector from Git or clone one between runtimes.

Download the driver:

```bash
B=~/.cache/openflow-weo-demo/bundle && mkdir -p "$B"
curl -sS --fail -o "$B/postgresql-42.7.8.jar" https://jdbc.postgresql.org/download/postgresql-42.7.8.jar
```

Then write `~/.cache/openflow-weo-demo/bundle/config.json` yourself with your file write tool:
read `<SKILL_DIR>/assets/connector-config.template.json` and replace its five placeholders,
`__PG_HOST__` with `<pg_host>`, `__PG_SECRET__` with `<DEMO_DB>.PUBLIC.<PG_INSTANCE>_PASSWORD`,
`__RUNTIME_ROLE__` with `<RUNTIME_ROLE>`, `__DEST_DB__` with `<DEMO_DB>` and `__WAREHOUSE__`
with `<WAREHOUSE>`. Confirm no `__` remains in what you wrote.

Create a stage for it, readable by the role that creates the connector. `<ADMIN_ROLE>` because
it owns `<DEMO_DB>`:

```sql
USE ROLE <ADMIN_ROLE>;
CREATE STAGE <DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE
  COMMENT = 'Configuration bundle for the WEO CDC connector';
GRANT USAGE ON DATABASE <DEMO_DB> TO ROLE <OPENFLOW_ROLE>;
GRANT USAGE ON SCHEMA <DEMO_DB>.PUBLIC TO ROLE <OPENFLOW_ROLE>;
GRANT READ ON STAGE <DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE TO ROLE <OPENFLOW_ROLE>;
```

Upload both files through the SQL tool. `<BUNDLE_DIR>` is the absolute path of
`~/.cache/openflow-weo-demo/bundle`, with `~` expanded:

```sql
PUT file://<BUNDLE_DIR>/config.json @<DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
```
```sql
PUT file://<BUNDLE_DIR>/postgresql-42.7.8.jar @<DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
```
```sql
LS @<DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/;
```

**Both files must be listed.** A missing JAR gives no useful error later.

Create the connector, wait for it to settle, then start it:

```sql
USE ROLE <OPENFLOW_ROLE>;
CREATE OPENFLOW CONNECTOR <CONTROL_SCHEMA>.<CONNECTOR>
  IN RUNTIME <CONTROL_SCHEMA>.<RUNTIME>
  FROM '@<DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/'
  COMMENT = 'WEO Postgres CDC demo connector';
```

Poll `SHOW OPENFLOW CONNECTORS LIKE '<CONNECTOR>' IN SCHEMA <CONTROL_SCHEMA>` every 15 s until
it leaves `CREATING`, at most 12 checks (usually about a minute), then:

```sql
USE ROLE <OPENFLOW_ROLE>;
ALTER OPENFLOW CONNECTOR <CONTROL_SCHEMA>.<CONNECTOR> START;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, '<CONTROL_SCHEMA>.<CONNECTOR>');
```

Expect `RUNNING`. On `START_FAILED`, read the gotchas entry on several Source properties reported
as required before changing anything.

The template's settings worth knowing: password is a `SECRET_REFERENCE` (the file holds the
secret's name, never the password), driver is an `ASSET_REFERENCE` to the JAR's bare filename,
and the merge schedule is every second (`* * * * * ?`) rather than the once-a-minute default,
so a change lands fast enough to narrate.

## Step 9: Verify the snapshot

Poll every 20 s until the count matches step 5's row count, at most 15 checks. It is usually
inside 90 s:

```sql
SELECT COUNT(*) AS rows_loaded,
       COUNT(DISTINCT COUNTRY_CODE) AS countries,
       COUNT(DISTINCT INDICATOR_CODE) AS indicators
FROM <DEMO_DB>.WEO.OBSERVATIONS;
```

Then confirm the demo row exists:

```sql
SELECT VALUE FROM <DEMO_DB>.WEO.OBSERVATIONS
WHERE COUNTRY_CODE = 'GBR' AND INDICATOR_CODE = 'NGDPD' AND FREQUENCY = 'Annual' AND YEAR = 2026;
```

## Output

Report green with real figures and the list in `created`. Write a filled-in presenter worksheet
to `~/.cache/openflow-weo-demo/cdc.sql` with your file write tool: copy `<SKILL_DIR>/assets/cdc.sql`,
substitute the `SET` block values and the lines marked `EDIT` from `state.json`. Tell the
presenter to paste that file into a Snowsight worksheet and keep it open as a second screen
during the demo.

**Next:** with the customer present, load `<SKILL_DIR>/demo/SKILL.md`. Afterwards, Part 3.
