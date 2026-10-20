---
name: openflow-gen2-pg-cdc-provision
description: "Part 1 of the Openflow gen 2 PostgreSQL CDC demo: build the Postgres source, load the WEO dataset, and create the runtime and connector. Not customer-facing."
parent_skill: postgres-cdc-openflow
---

# Part 1: Provision

## When to load

Router Step 0 found no working connector, or the user asked to rebuild.

Not customer-facing. Print progress plainly; there is no audience to protect.

Read [../references/provision.md](../references/provision.md) before starting. The steps below
are the sequence; that file is why each one is where it is.

`<SKILL_DIR>` is the skill root, resolved by the router. Every path below is relative to it.

## How to run SQL

**Use the `snowflake_sql_execute` tool, not `snow sql`.** It runs against the connection already
established in the session, so it needs no token of its own. Every `snow sql` invocation is a
separate process that must authenticate, and on an OAuth connection that means a browser prompt
each time. Over a build this long that is dozens of interruptions.

Two things still need the CLI, because neither has a SQL equivalent:

- `snow stage copy`, for the connector's config and JDBC driver in step 7.
- The two scripts in `scripts/`, which manage their own connections.

Both take `-c <connection>`, resolved by the router.

Where a step below shows several statements together, send them as one call. Fewer, larger calls
beat many small ones.

Two things to know about batching. The tool returns **only the last statement's result**, so put
the statement whose output you want at the end, and split the call when you need two result sets.
And you lose the per-statement status lines `snow sql -f` prints, so a failure part-way through a
long grant block is not obvious. Verify the outcome afterwards rather than trusting silence. A
`USE ROLE` applies only within the call it appears in, so repeat it at the top of each batch that
needs it.

## 1. Preflight and load the dataset

The router has already resolved `<SKILL_DIR>` and the `snow` connection name.

Check `psql` and `uv` are present, and that your role reaches `ACCOUNTADMIN`.

Confirm the three reused objects exist, because the grants in step 5 fail without them:

```sql
SHOW SCHEMAS LIKE 'CONTROL' IN DATABASE OPENFLOW_GEN2;
SHOW ROLES LIKE 'OPENFLOW_CDC_ROLE';
SHOW WAREHOUSES LIKE 'OPENFLOW_WH';
```

Then load the WEO export. **This is the real load, not a check** — it parses the xlsx and
writes the CSV that step 4 copies into Postgres:

```bash
<SKILL_DIR>/scripts/load-weo-data.py
```

Doing it first is deliberate. If the export is missing you find out now, rather than after
spending two minutes building a Postgres instance with nothing to put in it.

Exit 2 means no export is present, and it has printed the download steps. **Stop there and
show them.** Exit 3 means the file is the wrong shape; show what it printed.

Report the counts it prints. Do not state an expected figure: a new WEO vintage changes all of
them.

The dataset lives in `~/.cache/openflow-weo-demo/`, deliberately outside the skill directory:
the xlsx alone is over the 2 MB per-file stage limit, so keeping it here would break publishing
the skill to the catalog.

## 2. Choose the deployment

From the `SHOW OPENFLOW DEPLOYMENTS` output the router already has, pick the gen 2 deployment.

**If exactly one exists, say which one you are using and move on.** A question with one
possible answer is friction, not a checkpoint. Ask only when there are two or more, or when the
user might want a new one, and then say both of these:

- The account cap is three deployments across both generations, gen 1 data planes included.
- An idle deployment costs around 2.64 credits a day with no runtime under it, and nothing in
  Snowflake will chase it. Resource monitors do not cover gen 2 compute pools and gen 2 objects
  cannot be added to a budget.

**Record whether you created it.** Teardown only drops what this skill made.

The runtime is chosen and created together in step 6, where it belongs: it attaches its
external access integration inline and that needs a Postgres hostname that does not exist yet.

## 3. Postgres source

Offer to reuse an existing instance if `SHOW POSTGRES INSTANCES` listed one.

Everything the instance depends on is ordinary SQL, so run it directly. Order matters and is not
obvious: the database holds the ingress network rule, the policy references that rule, and the
instance references the policy. Teardown unwinds in reverse.

```sql
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS WEO_CDC_DEMO
  COMMENT = 'Openflow gen 2 Postgres CDC demo. Destination tables, ingress rule and secret.';

CREATE SCHEMA IF NOT EXISTS WEO_CDC_DEMO.WEO
  COMMENT = 'Destination schema. The connector creates the tables inside it.';

CREATE NETWORK RULE IF NOT EXISTS WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_INGRESS
  TYPE = IPV4
  VALUE_LIST = ('0.0.0.0/0')
  MODE = POSTGRES_INGRESS;

CREATE NETWORK POLICY IF NOT EXISTS WEO_CDC_PG_POLICY
  ALLOWED_NETWORK_RULE_LIST = ('WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_INGRESS');
```

Ingress is wide open so `psql` can reach the instance from a laptop that moves between
networks. Fine for a demo account, narrow it if you ever leave the instance up.

Then create the instance itself:

```bash
<SKILL_DIR>/scripts/create-postgres-instance.py -c <connection>
```

**This one statement is a script rather than inline SQL for a reason.**
`CREATE POSTGRES INSTANCE` returns the `snowflake_admin` password in its `access_roles` output,
and `DESCRIBE` will not return it again. Any method that shows the statement's output puts a
live credential on screen and into the session transcript. The script runs it, writes the
password to `~/.pgpass` at mode 600 and into a Snowflake secret, and prints neither.

It creates `WEO_CDC_PG` with `BURST_S` on 10 GB, ample for roughly 360,000 rows. `wal_level` is
already `logical` on a fresh Snowflake Postgres 17 instance, so there is no `ALTER SYSTEM` and
no restart.

The script returns when the instance is **actually usable**, polling through `CREATING` and
`FINALIZING` to `READY`. Expect two to three minutes. It ends with a line to run:

```bash
export PG_HOST=<the host it printed>
```

**Export it before going further.** The egress network rule, the JDBC URL and both `psql` calls
all use it, and a hand-typed hostname is the easiest thing to get subtly wrong here. It is also
cached at `~/.cache/openflow-weo-demo/pg-host`, so a resumed session can recover it without
rebuilding.

Re-running is safe. If the instance already exists the password is recovered from `~/.pgpass`,
because Snowflake issues it only once. If `~/.pgpass` has no entry either, the password is
unrecoverable and the instance must be recreated; the script says so and stops.

On "Internal error occurred", confirm nothing was created with `SHOW POSTGRES INSTANCES` and
retry once.

## 4. Create the source schema and copy the data in

The CSV already exists from step 1. This step is `psql` only, so the SQL goes in on stdin.

```bash
export PG_HOST=$(cat ~/.cache/openflow-weo-demo/pg-host)
PGC="host=$PG_HOST port=5432 user=snowflake_admin dbname=postgres sslmode=require"

psql "$PGC" -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS weo;

DROP TABLE IF EXISTS weo.observations;

CREATE TABLE weo.observations (
    country_code    VARCHAR(16)     NOT NULL,
    indicator_code  VARCHAR(64)     NOT NULL,
    frequency       VARCHAR(16)     NOT NULL,
    year            SMALLINT        NOT NULL,
    value           NUMERIC(24, 6)  NOT NULL,
    PRIMARY KEY (country_code, indicator_code, frequency, year)
);

ALTER TABLE weo.observations REPLICA IDENTITY DEFAULT;

DROP PUBLICATION IF EXISTS openflow;
CREATE PUBLICATION openflow FOR TABLE weo.observations;

SELECT pubname, puballtables FROM pg_publication;
SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = 'openflow';
SQL
```

Four things in that block are load-bearing:

- **The primary key is what the connector merges on**, so it has to match the natural grain of
  an observation.
- **Column widths come from what the file actually contains**, verified against
  `WEOApr2026all.xlsx`. Aggregates and commodity series use 4-character country codes such as
  `G001` (World), so `CHAR(3)` rejects them. `frequency` carries the word `Annual`, not the
  letter `A`. `SCALE` in the source is a label (`Billions`, `Units`) and values are already
  expressed in it, so nothing is rescaled.
- **`REPLICA IDENTITY DEFAULT` uses the primary key**, which the connector needs on UPDATE and
  DELETE to target the right row. It is already the default; asserting it stops a future schema
  edit breaking CDC silently.
- **The publication is created in the same breath as the table.** `DROP TABLE` silently removes
  a table from a publication, so recreating the table alone leaves CDC replicating nothing with
  no error anywhere. Keeping them together makes that impossible, and means re-running this
  block requires re-loading the data.

Then copy the data in. The load file has no header row, so do not add `HEADER true`:

```bash
psql "$PGC" -v ON_ERROR_STOP=1 \
  -c "\copy weo.observations (country_code, indicator_code, frequency, year, value) \
      FROM '$HOME/.cache/openflow-weo-demo/weo-observations.csv' WITH (FORMAT csv)"

psql "$PGC" -c "SELECT COUNT(*) FROM weo.observations"
```

Confirm the count matches what step 1 reported.

## 5. Destination grants and network access

Substitute the real host for `<PG_HOST>` and send this as one call.

**These grants must be right before the connector first starts.** `CREATE STREAM` in
particular: without it the snapshot still succeeds and the connector still reports `RUNNING`,
but the first change flips the table to `FAILED` and granting it afterwards does not recover.
See `gotchas.md`.

```sql
USE ROLE ACCOUNTADMIN;

-- The connector writes as OPENFLOW_CDC_ROLE and creates its own objects, so it needs
-- create rights rather than just write rights. CREATE STREAM is the one that is easy to
-- miss and expensive to debug: the connector builds a journal table per replicated table
-- and a stream over it to drive the merge.
GRANT USAGE ON DATABASE WEO_CDC_DEMO TO ROLE OPENFLOW_CDC_ROLE;
GRANT CREATE SCHEMA ON DATABASE WEO_CDC_DEMO TO ROLE OPENFLOW_CDC_ROLE;
GRANT USAGE ON SCHEMA WEO_CDC_DEMO.WEO TO ROLE OPENFLOW_CDC_ROLE;
GRANT CREATE TABLE ON SCHEMA WEO_CDC_DEMO.WEO TO ROLE OPENFLOW_CDC_ROLE;
GRANT CREATE STREAM ON SCHEMA WEO_CDC_DEMO.WEO TO ROLE OPENFLOW_CDC_ROLE;
GRANT CREATE VIEW ON SCHEMA WEO_CDC_DEMO.WEO TO ROLE OPENFLOW_CDC_ROLE;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE WEO_CDC_DEMO TO ROLE OPENFLOW_CDC_ROLE;
GRANT CREATE TABLE ON FUTURE SCHEMAS IN DATABASE WEO_CDC_DEMO TO ROLE OPENFLOW_CDC_ROLE;
GRANT CREATE STREAM ON FUTURE SCHEMAS IN DATABASE WEO_CDC_DEMO TO ROLE OPENFLOW_CDC_ROLE;
GRANT USAGE, OPERATE ON WAREHOUSE OPENFLOW_WH TO ROLE OPENFLOW_CDC_ROLE;

-- Without these two you cannot read your own demo data: the connector owns the objects
-- it creates and ACCOUNTADMIN does not inherit that. FUTURE grants are not retroactive,
-- so they have to be here rather than after the snapshot.
GRANT SELECT ON FUTURE TABLES IN DATABASE WEO_CDC_DEMO TO ROLE ACCOUNTADMIN;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE WEO_CDC_DEMO TO ROLE ACCOUNTADMIN;

-- BOTH secret grants are needed. READ alone is not enough: reading a secret also needs
-- USAGE on the schema holding it. Verified 24 Sep 2026 by omitting the second one, which
-- silently dropped the entire Source config step and produced a START_FAILED blaming four
-- unrelated properties. See gotchas.md.
GRANT READ ON SECRET WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_PASSWORD TO ROLE OPENFLOW_CDC_ROLE;
GRANT USAGE ON SCHEMA WEO_CDC_DEMO.PUBLIC TO ROLE OPENFLOW_CDC_ROLE;

-- For the connector's own schema, where the gen 2 object lives.
GRANT USAGE ON DATABASE OPENFLOW_GEN2 TO ROLE OPENFLOW_CDC_ROLE;
GRANT USAGE ON SCHEMA OPENFLOW_GEN2.CONTROL TO ROLE OPENFLOW_CDC_ROLE;

-- Part 2 step 2 reads the connector's own config.json straight off its internal stage with
-- SELECT, to show that the pipeline's configuration is a queryable Snowflake object rather
-- than something buried in a UI. That needs a JSON file format, created here so nothing has
-- to be built on a shared screen.
CREATE OR REPLACE FILE FORMAT WEO_CDC_DEMO.PUBLIC.RAW_JSON
  TYPE = JSON
  COMMENT = 'Reads the gen 2 connector config.json off its internal stage for the demo.';

-- CREATE NETWORK RULE validates that the host resolves, which is why the instance had to
-- come first. It lives in WEO_CDC_DEMO rather than OPENFLOW_GEN2.CONTROL because that
-- schema is owned by OPENFLOWADMIN and ACCOUNTADMIN does not inherit CREATE NETWORK RULE
-- on another role's schema. Keeping it here also means teardown takes it with the database.
CREATE OR REPLACE NETWORK RULE WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_EGRESS
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('<PG_HOST>:5432');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION WEO_CDC_PG_EAI
  ALLOWED_NETWORK_RULES = (WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_EGRESS)
  ENABLED = TRUE
  COMMENT = 'Lets the gen 2 CDC runtime reach the demo Postgres instance.';

GRANT USAGE ON INTEGRATION WEO_CDC_PG_EAI TO ROLE OPENFLOW_CDC_ROLE;
```

The secret is not created here. `scripts/create-postgres-instance.py` made it in step 3, as
the only thing that ever sees the password, so the credential has exactly one home and never
reaches a SQL statement, the screen or shell history.

If `WEO_CDC_DEMO` already exists, offer to truncate `WEO_CDC_DEMO.WEO.OBSERVATIONS` rather
than dropping the database, which would take the ingress network rule and the secret with it.

## 6. Runtime and connector

**Decide the runtime here, at the point of creation.** If runtimes exist on the chosen
deployment, offer to reuse one, noting that a reused runtime needs `WEO_CDC_PG_EAI` adding with
`ALTER OPENFLOW RUNTIME` and that teardown will leave it alone. If none exist, say you are
creating `WEO_CDC_RT` and move on without asking.

Allow **three to five minutes**: the `CREATE` returns quickly but the wait function dominates,
which makes this the longest single step in the build. Measured 3m18s, 4m21s and 4m34s.

The external access integration is attached inline, at create time. In gen 1 this was a manual
step in the Openflow UI that had to happen before any flow could reach the source, and skipping
it produced `UnknownHostException` or "SSH Connection failed", both of which look like firewall
faults and are not. Worth saying out loud in the demo.

```sql
USE ROLE OPENFLOWADMIN;

CREATE OPENFLOW RUNTIME IF NOT EXISTS OPENFLOW_GEN2.CONTROL.WEO_CDC_RT
  IN DEPLOYMENT <DEPLOYMENT>
  NODE_TYPE = MEDIUM
  NODE_TYPE_TIER = 'M4'
  MIN_NODES = 1
  MAX_NODES = 1
  EXECUTE_AS_ROLE = OPENFLOW_CDC_ROLE
  EXTERNAL_ACCESS_INTEGRATIONS = (WEO_CDC_PG_EAI)
  COMMENT = 'Runs the WEO Postgres CDC connector. Demo-scoped, safe to drop.';

SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES(900, 'OPENFLOW_GEN2.CONTROL.WEO_CDC_RT');
```

The connector starts `STOPPED` and in Draft: a live version exists, but there is no committed
default until you commit one. `SHOW OPENFLOW CONNECTOR DEFINITIONS` lists what the account
offers, if `OPENFLOW_POSTGRES_CDC` is not present.

```sql
USE ROLE OPENFLOWADMIN;
USE DATABASE OPENFLOW_GEN2;
USE SCHEMA CONTROL;

CREATE OPENFLOW CONNECTOR IF NOT EXISTS WEO_PG_CDC
  IN RUNTIME WEO_CDC_RT
  FROM DEFINITION OPENFLOW_POSTGRES_CDC
  DISPLAY_NAME = 'WEO Postgres CDC';
```

**Wait for it to leave `CREATING` before touching its stage in step 7.** It takes about a
minute to settle to `STOPPED`, and the config download in the next step needs the stage to
exist. Poll rather than assume:

```sql
SHOW OPENFLOW CONNECTORS IN ACCOUNT;   -- expect STOPPED, not CREATING
```

## 7. Configure and start the connector

The connector's configuration is a versioned `config.json` on its own internal stage, not SQL.
Download it, edit it, upload it alongside the JDBC driver, then commit. This is the one step
that needs `snow`, because Snowsight cannot `GET` or `PUT` on connector stages and there is no
SQL equivalent.

```bash
curl -sL -o postgresql-42.7.8.jar https://jdbc.postgresql.org/download/postgresql-42.7.8.jar

STAGE='snow://openflow_connector/OPENFLOW_GEN2.CONTROL.WEO_PG_CDC/versions/live'
snow stage copy -c <connection> "$STAGE/config.json" .
```

Edit the downloaded `config.json` in place. It holds a `configuration` array of sections, each
with a `properties` object. **Set only these keys, and only where they already exist.** A key
you invent is silently ignored, which produces a connector that starts, reports `RUNNING` and
moves nothing. If a key or section below is missing from the template, stop and say which one:
the connector definition has changed and the template is the contract.

| Section | Property | Value |
|---|---|---|
| Source | Source Database Connection URL | `jdbc:postgresql://<PG_HOST>:5432/postgres?ssl=true&sslmode=require` |
| Source | Source Database User | `snowflake_admin` |
| Source | Source Database Publication Name | `openflow` |
| Replication table schema | Included Comma Separated Source Table Names | `weo.observations` |
| Destination authentication | Snowflake Role | `OPENFLOW_CDC_ROLE` |
| Destination details | Snowflake Destination Database | `WEO_CDC_DEMO` |
| Destination details | Snowflake Warehouse | `OPENFLOW_WH` |
| Tuning | Merge Task Schedule CRON | `* * * * * ?` |

Ordinary properties take a `value`. Two do not:

- **Source Database Password** carries `"valueType": "SECRET_REFERENCE"`. Set
  `fullyQualifiedSecretName` to `WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_PASSWORD`, never a literal
  password. Confirm the `valueType` before writing it.
- **Source Database Driver** carries `"valueType": "ASSET_REFERENCE"`. Set `assetIds` to
  `["postgresql-42.7.8.jar"]`, the bare filename of the JAR uploaded to the **same** connector
  version. This format is undocumented and was established by trying it.

Assert each `valueType` as you write, rather than trusting the table. A patch script that
checks the type and fails loudly on a missing key is better than one that writes blind, because
a wrong key produces a connector that looks healthy and moves nothing.

Leave **Snowflake Private Key** unset. Under `SNOWFLAKE_MANAGED` there is no key to supply and
its controller service is expected to fail validation. That is normal and does not stop the
connector.

The merge CRON default is `0 * * * * ?`, once a minute on the zero second, so a single change
can sit for up to 60 seconds. Correct for production, painful to narrate live, hence every
second for the demo.

```bash
snow stage copy -c <connection> postgresql-42.7.8.jar "$STAGE/" --overwrite
snow stage copy -c <connection> config.json "$STAGE/" --overwrite
```

Then list the stage and **confirm both files are present before committing.** A missing JAR is
the single most expensive failure here and it gives no useful error. See `gotchas.md`.

```sql
LS 'snow://openflow_connector/OPENFLOW_GEN2.CONTROL.WEO_PG_CDC/versions/live/';

ALTER OPENFLOW CONNECTOR OPENFLOW_GEN2.CONTROL.WEO_PG_CDC COMMIT;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'OPENFLOW_GEN2.CONTROL.WEO_PG_CDC');
ALTER OPENFLOW CONNECTOR OPENFLOW_GEN2.CONTROL.WEO_PG_CDC START;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'OPENFLOW_GEN2.CONTROL.WEO_PG_CDC');
SHOW OPENFLOW CONNECTORS IN ACCOUNT;
```

`COMMIT` puts the connector into `UPDATING` and `START` is rejected while it sits there, which
is what the first wait is for.

**If this lands in `START_FAILED`, read the gotchas entry on several Source properties being
reported as required before changing anything.** The likely cause is a config section that
failed to apply rather than a value that is missing, and recovery needs a new live version, not
a retried `START`.

## 8. Wait for the snapshot, then capture the demo values

Poll until the destination count matches the source. Around 35 to 90 seconds for 360,000
rows, so quick, but not instant.

```sql
SELECT COUNT(*) AS ROW_COUNT,
       COUNT(DISTINCT COUNTRY_CODE) AS COUNTRIES,
       COUNT(DISTINCT INDICATOR_CODE) AS INDICATORS,
       MIN(YEAR) AS MIN_YEAR,
       MAX(YEAR) AS MAX_YEAR
FROM WEO_CDC_DEMO.WEO.OBSERVATIONS;
```

Then capture the value Part 2 will change, and derive the revised figure from it:

```sql
SELECT VALUE FROM WEO_CDC_DEMO.WEO.OBSERVATIONS
WHERE COUNTRY_CODE = 'GBR' AND INDICATOR_CODE = 'NGDPD' AND YEAR = 2026;
```

Hold both. **Nothing in Part 2 carries a hardcoded number**, so the demo survives a WEO
restatement.

## Output

Report green with the real figures, and remind the user to run Part 3 after the meeting.

**Next:** when the customer is present, load `<SKILL_DIR>/demo/SKILL.md`.
