# Provisioning, in full

`SKILL.md` carries the steps CoCo follows. This is the detail behind them: why the
order is what it is, and what each step's failure looks like.

Roughly 20 minutes end to end, most of it waiting on the Postgres instance and the runtime.
Measured 23 September 2026: Postgres create to `READY` about two minutes, the WEO load 5
seconds for 361,733 rows, runtime create and stabilise about four and a half minutes, and the
snapshot 35 to 90 seconds. Run it the day before a demo, not an hour before.

## Nothing is remembered between runs, by design

There is no state file. Every value is discovered:

| Value | Where it comes from |
|---|---|
| Postgres host | `DESCRIBE POSTGRES INSTANCE`, cached to `/tmp/weo_cdc_pg_host` |
| Postgres password | `~/.pgpass`, written once at create time, and a Snowflake secret |
| `snow` connection | `snow connection list`, then `-c <name>` on CLI calls |
| Connector config | the connector's own stage |
| Runtime URL | `DESCRIBE OPENFLOW RUNTIME ... server_url` |
| Journal table name | `INFORMATION_SCHEMA.TABLES` |
| Demo before and after values | queried from the loaded data |

The Postgres host changes on every rebuild, and the journal table name carries a numeric
suffix that changes with it. Discover both rather than carrying them forward.

## Default object names

Deliberately distinctive, so they don't collide with other demos in the same account.

| Object | Name |
|---|---|
| Postgres instance | `WEO_CDC_PG` |
| Network policy | `WEO_CDC_PG_POLICY` |
| Demo database | `WEO_CDC_DEMO` |
| Destination schema | `WEO_CDC_DEMO.WEO` |
| Ingress rule | `WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_INGRESS` |
| Egress rule | `WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_EGRESS` |
| External access integration | `WEO_CDC_PG_EAI` |
| Secret | `WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_PASSWORD` |
| Runtime | `OPENFLOW_GEN2.CONTROL.WEO_CDC_RT` |
| Connector | `OPENFLOW_GEN2.CONTROL.WEO_PG_CDC` |

Reused rather than created: role `OPENFLOW_CDC_ROLE`, warehouse `OPENFLOW_WH`, control
schema `OPENFLOW_GEN2.CONTROL`.

## The one ordering constraint

**Postgres must exist before the runtime.** The runtime attaches its external access
integration inline at create time, that integration wraps a network rule, and
`CREATE NETWORK RULE` validates that the host resolves. So the rule cannot be written
before the instance has a hostname. Everything else is flexible.

Within that, the demo database comes first because it holds the ingress rule, the policy
references the rule, and the instance references the policy.

## Step by step

### 1. Preflight

`snow` CLI, `psql`, `uv`, and a role that can reach `ACCOUNTADMIN`.

**Establish the `snow` connection name.** There may be no default, and it is not necessarily
named after the account, so `snow connection list` first and then `-c <name>` on CLI calls.
SQL itself goes through `snowflake_sql_execute`, which avoids a per-process OAuth prompt.

Plus a WEO export in `~/.cache/openflow-weo-demo/`: check this **before** provisioning anything, or you create a
Postgres instance and then discover you cannot load it. `./scripts/load-weo-data.py` exits 2
with the download steps if the file is missing.

### 2. Deployment

`SHOW OPENFLOW DEPLOYMENTS` lists gen 2 deployments; `SHOW OPENFLOW DATA PLANE
INTEGRATIONS` lists gen 1, which this demo does not use. Report the choice when there is only
one, and ask only when there are several or a new one might be wanted.

Two things to say when offering: the account cap is **three deployments across both
generations**, and an idle deployment bills around **2.64 credits a day** with no runtime
under it, because resource monitors do not cover gen 2 compute pools and gen 2 objects
cannot be added to a budget. Nothing will chase a forgotten one.

Record whether the skill created it. Teardown only drops what it made.

### 3. Runtime selection

Deferred to step 6, where the runtime is created. The external access integration is attached
inline at create time and that needs the Postgres host, so there is nothing useful to decide
before the instance exists. Asking earlier means asking and then waiting four steps, which reads
as a stall.

### 4. Postgres instance

Run the prerequisite SQL from the step 3 block in `provision/SKILL.md` first, then:

```bash
./scripts/create-postgres-instance.py -c <connection>
```

This exists because of one detail: the `snowflake_admin` password is returned **once**, in the
`access_roles` column of the `CREATE` output, and `DESCRIBE` will not return it again. So any
way of running that statement that shows its output puts the credential on screen and into
the session transcript. The script runs it, parses the result, writes `~/.pgpass` at mode 600
and creates the Snowflake secret, and prints neither the password nor the statement.

It is idempotent. When the instance already exists, `CREATE` returns no password and the
script recovers it from `~/.pgpass`, which is what makes provisioning re-runnable. If neither
has it, the instance must be recreated.

The secret goes in `WEO_CDC_DEMO.PUBLIC`, not beside the connector in `OPENFLOW_GEN2.CONTROL`.
The config references it by fully-qualified name, so it can live anywhere the runtime role can
read it. Keeping it in the demo database means `ACCOUNTADMIN` owns it throughout, and teardown
removes it with the database rather than leaving a live credential behind.

Poll `DESCRIBE POSTGRES INSTANCE` until `state` is `READY`, roughly two minutes through
`CREATING` and `FINALIZING`. `CREATE POSTGRES INSTANCE` has been seen failing with a bare
"Internal error occurred"; nothing is left behind, so confirm with `SHOW POSTGRES INSTANCES`
and retry once.

### 5. Load the data

The source schema and publication are created together by the step 4 block in
`provision/SKILL.md`, sent to `psql` on stdin, then the CSV is copied in:

```bash
psql "host=$PG_HOST port=5432 user=snowflake_admin dbname=postgres sslmode=require" \
  -v ON_ERROR_STOP=1 \
  -c "\copy weo.observations (country_code, indicator_code, frequency, year, value) \
      FROM '$HOME/.cache/openflow-weo-demo/weo-observations.csv' WITH (FORMAT csv)"
```

Note the load file has **no header**, so no `HEADER true`.

Report what actually loaded rather than an expected figure. On the April 2026 vintage it
is 361,733 observations across 210 countries and aggregates, 145 indicators and years
1980 to 2031, but a new vintage moves all four numbers.

The table and the publication are created in the same block, which is not tidiness.
`DROP TABLE` silently removes a table from a publication, so recreating the schema without
recreating the publication leaves CDC replicating nothing, with no error anywhere. The pairing
makes that impossible. It also means re-running the block requires re-loading the data.

### 6. Destination grants and network access

The step 5 block in `provision/SKILL.md`, with the real host substituted for `<PG_HOST>`. The
secret already exists from step 4, so no password is involved here.

**Get these grants right before the connector first starts.** Three are easy to miss:

- `CREATE STREAM` on the destination schema. The connector builds a journal table per
  replicated table and a stream over it to drive the merge. Without it the snapshot still
  succeeds and the connector still reports `RUNNING`, but the first change flips the table's
  replication state to `FAILED`, and granting it afterwards does not recover, because the
  state is persisted and never retried. See `gotchas.md`.
- `SELECT ON FUTURE TABLES` and `USAGE ON FUTURE SCHEMAS` to `ACCOUNTADMIN`. The connector
  creates and therefore owns the destination objects, so without these you cannot query your
  own demo data. `FUTURE` grants do not apply retroactively.

The egress network rule lives in `WEO_CDC_DEMO.PUBLIC` rather than `OPENFLOW_GEN2.CONTROL`,
because that schema is owned by `OPENFLOWADMIN` and `ACCOUNTADMIN` cannot create a network
rule in it. Teardown then takes the rule with the database.

If the database already exists, offer to truncate the destination table rather than dropping
the database, which would take the ingress rule with it.

### 7. Runtime and connector

The `CREATE OPENFLOW RUNTIME` and `CREATE OPENFLOW CONNECTOR` statements are inline in
`provision/SKILL.md` step 6, with the deployment substituted. Allow about five minutes: the
`CREATE` returns quickly but `SYSTEM$WAIT_FOR_STABLE_OPENFLOW_RUNTIMES` dominates, and that is
the longest single step in the build.

The EAI is attached inline via `EXTERNAL_ACCESS_INTEGRATIONS = (...)`, which in gen 1 was a
manual attach in the Openflow UI and a manual detach before teardown.

The connector is created STOPPED and in Draft: a live version exists, but no committed
default.

### 8. Configure the connector

The configuration is a versioned file on the connector's own stage, so the workflow is
download, patch, upload, commit.

```bash
curl -sL -o postgresql-42.7.8.jar https://jdbc.postgresql.org/download/postgresql-42.7.8.jar

STAGE='snow://openflow_connector/OPENFLOW_GEN2.CONTROL.WEO_PG_CDC/versions/live'
snow stage copy -c <connection> "$STAGE/config.json" .

# Edit config.json here. The key-by-key table is in provision/SKILL.md step 7.

snow stage copy -c <connection> postgresql-42.7.8.jar "$STAGE/" --overwrite
snow stage copy -c <connection> config.json "$STAGE/" --overwrite
```

Then `LS '$STAGE/';` through `snowflake_sql_execute`.

Check both files are listed before committing. Snowsight cannot `GET` or `PUT` on
connector stages, so use the CLI.

```sql
ALTER OPENFLOW CONNECTOR OPENFLOW_GEN2.CONTROL.WEO_PG_CDC COMMIT;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'OPENFLOW_GEN2.CONTROL.WEO_PG_CDC');

ALTER OPENFLOW CONNECTOR OPENFLOW_GEN2.CONTROL.WEO_PG_CDC START;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, 'OPENFLOW_GEN2.CONTROL.WEO_PG_CDC');
```

`COMMIT` puts the connector into `UPDATING`, and `START` is rejected while it sits there.
Wait between the two.

To change anything after a commit, versions are immutable:

```sql
ALTER OPENFLOW CONNECTOR OPENFLOW_GEN2.CONTROL.WEO_PG_CDC ADD LIVE VERSION FROM LAST;
-- download, edit, upload, then COMMIT again, or ABORT
```

### 9. Wait for the snapshot, then verify

The snapshot is not instant at this volume, so poll rather than assume. Measured at 35 to 90
seconds for 361,733 rows:

```sql
SELECT COUNT(*) AS row_count,
       COUNT(DISTINCT COUNTRY_CODE) AS countries,
       COUNT(DISTINCT INDICATOR_CODE) AS indicators
FROM WEO_CDC_DEMO.WEO.OBSERVATIONS;
```

Poll until it matches the source count, then capture the value the walkthrough will change:

```sql
SELECT VALUE FROM WEO_CDC_DEMO.WEO.OBSERVATIONS
WHERE COUNTRY_CODE = 'GBR' AND INDICATOR_CODE = 'NGDPD' AND YEAR = 2026;
```

Hold that as the "before" and derive a visibly different "after" from it. Nothing in the
walkthrough carries a hardcoded figure, so any WEO vintage works.
