---
name: openflow-gen2-pg-cdc-provision
description: "Part 1 of the Openflow gen 2 PostgreSQL CDC demo: reuse or create the Openflow and Postgres infrastructure with SQL, load the IMF WEO dataset, and start the connector. Not customer-facing."
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
4. Run it, show the verification result, and update `state.json` (`created` gets each new object).

Read-only discovery and verification queries run without a gate. Anything that creates, alters
or costs money gets one. If a statement fails, show the error, check
[../references/gotchas.md](../references/gotchas.md), and stop. Do not improvise fixes.

## Step 1: Reuse or create (one gate)

Discover first, all read-only:

```sql
SHOW OPENFLOW DEPLOYMENTS;
```
```sql
SHOW OPENFLOW RUNTIMES IN ACCOUNT;
```
```sql
SHOW ROLES LIKE '%OPENFLOW%';
```
```sql
SHOW WAREHOUSES;
```
```sql
SHOW POSTGRES INSTANCES;
```

Then ask **one** `ask_user_question` call with up to four questions, one per component that has
candidates. Each lists the existing objects as options plus `Create new <default name>`. Put
what you found in chat text before the call.

| Component | Offer | If creating |
|---|---|---|
| Deployment | Gen 2 deployments with status `ACTIVE`. Show each `comment` | `WEO_CDC_DEPLOYMENT`. Say: 5 to 10 minutes, **max three deployments per account across gen 1 and gen 2**, around 2.64 credits a day idle, no budget or resource monitor covers it |
| Runtime role | Roles granted to `<OPENFLOW_ROLE>` that are an existing runtime's `execute_as_role` | `OPENFLOW_CDC_ROLE` |
| Warehouse | Warehouses `<RUNTIME_ROLE>` already uses, else any XSMALL or SMALL | `OPENFLOW_WH`, XSMALL, auto-suspend 60 |
| Runtime | `ACTIVE` runtimes on the chosen deployment | `WEO_CDC_RT`, MEDIUM M4, 1 node. **Default to create**: a reused runtime gets a demo EAI added and teardown leaves it in place |

With exactly one candidate, still ask: reuse is the user's decision. With none, say what will be
created and move on without a question for that component.

`CONTROL_SCHEMA` follows the deployment: the `database_name.schema_name` of its existing runtimes,
else `OPENFLOW_GEN2.CONTROL` (created in step 2).

If a `<PG_INSTANCE>` already exists, ask: `Reuse it (reload the data)` / `Drop and recreate` /
`Stop`. Reusing needs the credential step (step 5) to rotate the password.

Write `state.json` with the choices before moving on.

## Step 2: Openflow foundations (only what was chosen for creation)

Skip any block whose object was reused. Run as `<ADMIN_ROLE>` unless shown otherwise.

**Deployment**, as `<OPENFLOW_ROLE>`. Long: wait with a poll, not a fixed sleep.

```sql
USE ROLE <OPENFLOW_ROLE>;
CREATE OPENFLOW DEPLOYMENT IF NOT EXISTS WEO_CDC_DEPLOYMENT
  DEPLOYMENT_TYPE = SNOWFLAKE
  DISPLAY_NAME = 'WEO CDC demo';
```

Poll `SHOW OPENFLOW DEPLOYMENTS` every 60 s until `ACTIVE`.

**Control schema**:

```sql
USE ROLE <OPENFLOW_ROLE>;
CREATE DATABASE IF NOT EXISTS OPENFLOW_GEN2;
CREATE SCHEMA IF NOT EXISTS OPENFLOW_GEN2.CONTROL;
```

**Runtime role**:

```sql
USE ROLE <ADMIN_ROLE>;
CREATE ROLE IF NOT EXISTS <RUNTIME_ROLE>;
GRANT ROLE <RUNTIME_ROLE> TO ROLE <OPENFLOW_ROLE>;
```

**Warehouse**:

```sql
USE ROLE <ADMIN_ROLE>;
CREATE WAREHOUSE IF NOT EXISTS <WAREHOUSE>
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
```

Always, reused or not:

```sql
USE ROLE <ADMIN_ROLE>;
GRANT USAGE ON DATABASE <CONTROL_DB> TO ROLE <RUNTIME_ROLE>;
GRANT USAGE ON SCHEMA <CONTROL_SCHEMA> TO ROLE <RUNTIME_ROLE>;
GRANT USAGE, OPERATE ON WAREHOUSE <WAREHOUSE> TO ROLE <RUNTIME_ROLE>;
```

## Step 3: Demo database and Postgres network policy

The database holds the ingress rule, the policy references the rule, and the instance references
the policy, so this order is enforced.

```sql
USE ROLE <ADMIN_ROLE>;
CREATE DATABASE IF NOT EXISTS <DEMO_DB>
  COMMENT = 'Openflow gen 2 Postgres CDC demo. Safe to drop with the demo.';
CREATE SCHEMA IF NOT EXISTS <DEMO_DB>.WEO;
CREATE NETWORK RULE IF NOT EXISTS <DEMO_DB>.PUBLIC.<PG_INSTANCE>_INGRESS
  TYPE = IPV4 VALUE_LIST = ('0.0.0.0/0') MODE = POSTGRES_INGRESS;
CREATE NETWORK POLICY IF NOT EXISTS <PG_INSTANCE>_POLICY
  ALLOWED_NETWORK_RULE_LIST = ('<DEMO_DB>.PUBLIC.<PG_INSTANCE>_INGRESS');
```

Ingress is open so `psql` works from a laptop on any network. Fine for a demo account. Say so.

## Step 4: Postgres instance

`CREATE POSTGRES INSTANCE` returns the `snowflake_admin` password once. **Never run it bare**:
the output would put a live password on a screen. This block runs it, stores the password in a
Snowflake secret and returns only the host. Query history redacts `SECRET_STRING`.

```sql
EXECUTE IMMEDIATE $$
DECLARE
  qid STRING;
  pw STRING;
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
  SELECT "host", PARSE_JSON("access_roles"):snowflake_admin::STRING
    INTO :h, :pw FROM TABLE(RESULT_SCAN(:qid));
  EXECUTE IMMEDIATE 'CREATE OR REPLACE SECRET <DEMO_DB>.PUBLIC.<PG_INSTANCE>_PASSWORD '
    || 'TYPE = GENERIC_STRING SECRET_STRING = ''' || REPLACE(:pw, '''', '''''') || '''';
  RETURN :h;
END;
$$;
```

Save the returned host as `pg_host` in `state.json`. BURST_S on 10 GB is ample, and `wal_level`
is already `logical` on a new PG 17 instance, so there is no restart.

Poll every 30 s until `READY`, about three minutes through `CREATING` and `FINALIZING`:

```sql
DESCRIBE POSTGRES INSTANCE <PG_INSTANCE>
  ->> SELECT "value" AS state FROM $1 WHERE "property" = 'state';
```

On "Internal error occurred", check `SHOW POSTGRES INSTANCES` shows nothing and retry once.

## Step 5: Give psql the password, without showing it

psql runs on this laptop, so the password has to land in `~/.pgpass`. The secret cannot be read
back, so this command **resets** the password and writes the new one to both `~/.pgpass` and
the secret in one go. It is never echoed and never on a command line. Also use it to recover a
lost `~/.pgpass`, or before reusing an existing instance.

```bash
CONN=<CONNECTION> PG=<PG_INSTANCE> SECRET=<DEMO_DB>.PUBLIC.<PG_INSTANCE>_PASSWORD HOST=<pg_host>
PW=$(snow sql -c "$CONN" --format json -q "USE ROLE <ADMIN_ROLE>; ALTER POSTGRES INSTANCE $PG RESET ACCESS FOR 'snowflake_admin'" | jq -r '.[-1][0].password')
touch ~/.pgpass && chmod 600 ~/.pgpass && grep -v "^$HOST:" ~/.pgpass > ~/.pgpass.tmp
printf '%s:5432:*:snowflake_admin:%s\n' "$HOST" "$PW" >> ~/.pgpass.tmp && mv ~/.pgpass.tmp ~/.pgpass && chmod 600 ~/.pgpass
printf "USE ROLE <ADMIN_ROLE>; CREATE OR REPLACE SECRET %s TYPE = GENERIC_STRING SECRET_STRING = '%s';" "$SECRET" "$PW" | snow sql -c "$CONN" -i > /dev/null
echo "password length ${#PW}, stored in ~/.pgpass and $SECRET"; unset PW
psql "host=$HOST port=5432 user=snowflake_admin dbname=postgres sslmode=require" -Atc "select version()"
```

Expect `password length 64` and a PostgreSQL 17 version string. Anything else: stop.

The `snow` calls here prompt for auth on an OAuth connection. That is expected and happens once.

## Step 6: Load the IMF WEO dataset into Postgres

The full World Economic Outlook from the IMF's public SDMX API: about 32 MB and 360,000
observations, no key. See [../references/weo-data.md](../references/weo-data.md).

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

## Step 7: Destination grants, secret access and egress

**All of this must be in place before the connector's first START.** `CREATE STREAM` especially:
without it the snapshot succeeds and the connector reports `RUNNING`, but the first change marks
the table `FAILED` and that state is never retried.

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
CREATE OR REPLACE NETWORK RULE <DEMO_DB>.PUBLIC.<PG_INSTANCE>_EGRESS
  MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('<pg_host>:5432');
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION <PG_INSTANCE>_EAI
  ALLOWED_NETWORK_RULES = (<DEMO_DB>.PUBLIC.<PG_INSTANCE>_EGRESS) ENABLED = TRUE
  COMMENT = 'Lets the gen 2 CDC runtime reach the demo Postgres instance.';
GRANT USAGE ON INTEGRATION <PG_INSTANCE>_EAI TO ROLE <RUNTIME_ROLE>;
```

## Step 8: Runtime

**Creating.** Three to five minutes, dominated by the wait:

```sql
USE ROLE <OPENFLOW_ROLE>;
CREATE OPENFLOW RUNTIME IF NOT EXISTS <CONTROL_SCHEMA>.<RUNTIME>
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

Then poll every 30 s until `ACTIVE`:

```sql
SHOW OPENFLOW RUNTIMES LIKE '<RUNTIME>' IN SCHEMA <CONTROL_SCHEMA>;
```

Poll with `SHOW`, not `SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES`: the wait function has been
seen erroring while the runtime is still `CREATING`, moments before it went `ACTIVE`.

## Step 9: Connector, from a configuration bundle

The connector is created **from a complete configuration bundle** on a stage, so it starts with
a committed `VERSION$1` and needs no edit, commit or second upload. This is the same mechanism
used to promote a connector from Git or clone one between runtimes.

Build the bundle locally. Fill the five placeholders in the template with `sed`:

```bash
B=~/.cache/openflow-weo-demo/bundle && mkdir -p "$B"
curl -sS --fail -o "$B/postgresql-42.7.8.jar" https://jdbc.postgresql.org/download/postgresql-42.7.8.jar
sed -e 's/__PG_HOST__/<pg_host>/' \
    -e 's/__PG_SECRET__/<DEMO_DB>.PUBLIC.<PG_INSTANCE>_PASSWORD/' \
    -e 's/__RUNTIME_ROLE__/<RUNTIME_ROLE>/' \
    -e 's/__DEST_DB__/<DEMO_DB>/' \
    -e 's/__WAREHOUSE__/<WAREHOUSE>/' \
    <SKILL_DIR>/assets/connector-config.template.json > "$B/config.json"
grep -c '__' "$B/config.json"   # must print 0
```

Create a stage for it, readable by the role that creates the connector:

```sql
USE ROLE <ADMIN_ROLE>;
CREATE STAGE IF NOT EXISTS <DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE
  COMMENT = 'Configuration bundle for the WEO CDC connector';
GRANT USAGE ON DATABASE <DEMO_DB> TO ROLE <OPENFLOW_ROLE>;
GRANT USAGE ON SCHEMA <DEMO_DB>.PUBLIC TO ROLE <OPENFLOW_ROLE>;
GRANT READ ON STAGE <DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE TO ROLE <OPENFLOW_ROLE>;
```

Upload both files. Snowsight cannot PUT local files, so this is the CLI:

```bash
snow stage copy -c <CONNECTION> "$B/config.json" @<DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/ --overwrite
snow stage copy -c <CONNECTION> "$B/postgresql-42.7.8.jar" @<DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/ --overwrite
```

```sql
LS @<DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/;
```

**Both files must be listed.** A missing JAR gives no useful error later.

Create the connector, wait for it to settle, then start it:

```sql
USE ROLE <OPENFLOW_ROLE>;
CREATE OPENFLOW CONNECTOR IF NOT EXISTS <CONTROL_SCHEMA>.<CONNECTOR>
  IN RUNTIME <CONTROL_SCHEMA>.<RUNTIME>
  FROM '@<DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/'
  COMMENT = 'WEO Postgres CDC demo connector';
```

Poll `SHOW OPENFLOW CONNECTORS LIKE '<CONNECTOR>' IN SCHEMA <CONTROL_SCHEMA>` until it leaves
`CREATING` (about a minute), then:

```sql
USE ROLE <OPENFLOW_ROLE>;
ALTER OPENFLOW CONNECTOR <CONTROL_SCHEMA>.<CONNECTOR> START;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, '<CONTROL_SCHEMA>.<CONNECTOR>');
```

Expect `RUNNING`. On `START_FAILED`, read the gotchas entry on Source properties reported as
required before changing anything.

The template's settings worth knowing: password is a `SECRET_REFERENCE` (the file holds the
secret's name, never the password), driver is an `ASSET_REFERENCE` to the JAR's bare filename,
and the merge schedule is every second (`* * * * * ?`) rather than the once-a-minute default,
so a change lands fast enough to narrate.

## Step 10: Verify the snapshot

Poll every 20 s until the count matches step 6's row count, usually inside 90 s:

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

Report green with real figures and the list in `created`. Point the presenter at
`<SKILL_DIR>/assets/cdc.sql`: paste it into a Snowsight worksheet, edit the `SET` block at the top
to match `state.json`, and keep it open as a second screen during the demo.

**Next:** with the customer present, load `<SKILL_DIR>/demo/SKILL.md`. Afterwards, Part 3.
