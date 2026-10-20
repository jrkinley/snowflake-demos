# Gotchas

Each entry leads with what you actually see, because that is all you have when it
happens. Cause and fix follow. Every entry says whether it is verified or assumed.

## The snapshot works, then the first change never arrives

**Symptom.** The snapshot lands completely and the connector reports `RUNNING`. You change a
row at source, wait, and nothing happens. The journal table exists but holds zero rows.
Postgres looks healthy: the replication slot is `active`, the publication contains the
table, and the new value is committed. Only the event table shows why:

```
UpdateSnowflakeStream[...] Insufficient privileges to perform Create Stream for stream
  "OBSERVATIONS_JOURNAL_<n>_1_STREAM" ... routing to 'failure'
StandardTableStateService[...] Replication state for table "weo"."observations" changed
  from INCREMENTAL_REPLICATION to FAILED, reason: [Failed to create, update, or manage
  Snowflake object]
```

**Cause.** The connector builds a journal table per replicated table **and a stream over
it** to drive the merge. The destination role needs `CREATE STREAM` on the schema.
`CREATE TABLE` alone is enough for the snapshot, which is why everything looks fine until
the first change.

**Fix.** Granted in the step 5 block of `provision/SKILL.md`:

```sql
GRANT CREATE STREAM ON SCHEMA WEO_CDC_DEMO.WEO TO ROLE OPENFLOW_CDC_ROLE;
GRANT CREATE STREAM ON FUTURE SCHEMAS IN DATABASE WEO_CDC_DEMO TO ROLE OPENFLOW_CDC_ROLE;
```

**Granting it afterwards is not enough**, see the next entry. Get the grants right before
the first `START`.

*Verified 23 September 2026. This is the single most expensive failure in the build, because
every other indicator says the pipeline is healthy.*

## A table stuck in FAILED never retries

**Symptom.** After fixing whatever caused a failure, `STOP` then `START` changes nothing.
The event table shows only the state being re-read:

```
StandardTableStateService[...] Stored state for table "weo"."observations": status=FAILED,
  created=..., reason=[Failed to create, update, or manage Snowflake object]
```

**Cause.** Replication state is persisted per table and a `FAILED` table is not retried on
restart.

**Fix.** Recreate the connector. Nothing lighter worked:

```sql
ALTER OPENFLOW CONNECTOR ... STOP;      -- wait
ALTER OPENFLOW CONNECTOR ... TERMINATE; -- wait
DROP OPENFLOW CONNECTOR ...;
DROP TABLE IF EXISTS WEO_CDC_DEMO.WEO.OBSERVATIONS;
DROP TABLE IF EXISTS WEO_CDC_DEMO.WEO.OBSERVATIONS_JOURNAL_<n>_1;
```

Then recreate, patch the config, upload both files, commit and start. About five minutes,
and the snapshot re-runs from scratch.

Two notes. `DROP` is rejected while the connector is `TERMINATING`, so wait for
`TERMINATED` before dropping. And the journal table's numeric suffix changes on the
rebuild, which is one reason never to hardcode it.

*Verified 23 September 2026.*

## LS on versions/live fails with "version live is not found"

**Symptom.** `LS 'snow://openflow_connector/<fqn>/versions/live/'` worked during provisioning and
now errors. `DESCRIBE` shows `live_version_location_uri` as empty.

**Cause.** `live` is the **draft** version, not an alias for the current one. It exists only
between `ADD LIVE VERSION` and `COMMIT`. Committing turns it into `VERSION$n` and there is no
live version again until you add one.

**Fix.** For reading a committed configuration, use the `last` alias, which is stable as versions
accumulate and needs no substitution:

```sql
LS 'snow://openflow_connector/<fqn>/versions/last/';
```

`DESCRIBE OPENFLOW CONNECTOR` also gives `last_version_name` and `last_version_location_uri` if
you want the concrete version. Each committed version holds its own copy of **both** config.json
and the JDBC driver, so versions are self-contained bundles.

Provisioning is unaffected: a freshly created connector has a live version, which is why the
provision step uses `versions/live` and is correct to.

*Verified 24 September 2026.*

## START_FAILED blaming several Source properties that are plainly set

**Symptom.** `START` leaves the connector in `START_FAILED`. The event table says:

```
Connector is invalid: Source Database Connection URL is required;
Source Database User is required; Source Database Password is required;
Source Database Publication Name is required
```

All four are set in the `config.json` you just uploaded, and `LS` on the stage confirms both
files are there.

**Cause.** Not four missing values. **One dropped section.** Dig further back in the event
table and you find:

```
Failed to replace working configuration for step [Source] ... continuing with remaining steps
```

The whole `Source` step failed to apply, so every property in it reads as unset. The usual
reason is that the connector's role cannot resolve the `SECRET_REFERENCE`, and the most likely
cause of that is a missing `USAGE` on the schema holding the secret. `READ ON SECRET` alone is
not sufficient.

**Fix.** Grant both, then **rebuild the version**:

```sql
GRANT READ  ON SECRET WEO_CDC_DEMO.PUBLIC.WEO_CDC_PG_PASSWORD TO ROLE OPENFLOW_CDC_ROLE;
GRANT USAGE ON SCHEMA WEO_CDC_DEMO.PUBLIC                     TO ROLE OPENFLOW_CDC_ROLE;
```

Granting the privilege and re-running `START` **does nothing**, because the config is synced at
`COMMIT`, not at `START`. Same sticky-state lesson as a `FAILED` table:

```sql
ALTER OPENFLOW CONNECTOR <fqn> ADD LIVE VERSION FROM LAST;
ALTER OPENFLOW CONNECTOR <fqn> COMMIT;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, '<fqn>');
ALTER OPENFLOW CONNECTOR <fqn> START;
```

The staged files carry over to the new version, so there is nothing to re-upload.

**Generalise it.** Whenever `START_FAILED` names more than one required property in the same
section, suspect the section rather than the properties, and search the event table for
"Failed to replace working configuration".

*Verified 24 September 2026, caused by moving the secret between schemas without moving the
usage grant.*

## The connector accepts START, then sits in START_FAILED

**Symptom.** `ALTER ... START` returns success. Status goes to `START_FAILED` and retries
every 10 seconds. `DESCRIBE OPENFLOW CONNECTOR` reports only the status. The event table
shows a `DBCPConnectionPool` named `PostgreSQL Connection Pool` that will not enable, with
no cause attached:

```
WARN  Failed to enable service StandardControllerServiceNode[
        service=DBCPConnectionPool[id=...], name=PostgreSQL Connection Pool, active=true]
ERROR Failed to start StandardConnectorNode[... state=STARTING] retrying in 10 seconds
```

**Cause.** `Source Database Driver` is an `ASSET_REFERENCE` and arrives unset. The
connector cannot start without it and never says so.

**Fix.** The provisioning step sets it explicitly, so this is closed in the normal flow. If you
hit it, the JAR must be uploaded to the **same connector version** as the config, and
`assetIds` takes the bare filename:

```json
"Source Database Driver": {
  "valueType": "ASSET_REFERENCE",
  "assetIds": ["postgresql-42.7.8.jar"]
}
```

**Diagnostic shortcut.** If the event table shows successful OAuth sessions against the
account with `OPENFLOW_CDC_ROLE`, `WEO_CDC_DEMO` and `OPENFLOW_WH`, the Snowflake half is
fine and the problem is the source half. The destination connects before the source does.

*Verified.* The `assetIds` format is undocumented and was established by trying it.

## CDC replicates nothing, and nothing anywhere reports an error

**Symptom.** The snapshot lands correctly. Later changes never arrive. No error in the
event table, the connector shows `RUNNING`, and the destination table just stops moving.

**Cause.** `DROP TABLE` silently removes a table from a Postgres publication. Recreating
the source table without recreating the publication leaves the publication empty.

**Fix.** The step 4 block in `provision/SKILL.md` creates the table and the publication together, so
this cannot happen if you use it. To check by hand:

```sql
SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = 'openflow';
```

*Verified.*

## CREATE NETWORK RULE rejects a host that looks fine

**Symptom.** "One or more values might be an unresolvable host name."

**Cause.** `CREATE NETWORK RULE` validates that the host resolves in DNS, so you cannot
pre-create a rule for an instance that does not exist yet.

**Fix.** Create the Postgres instance first and take the host from
`DESCRIBE POSTGRES INSTANCE`. This is the reason for the one hard ordering constraint in
provisioning. Where a host changes on every rebuild and you want a stable rule, a wildcard
works, but a Postgres instance hostname has no stable suffix worth wildcarding.

*Verified.*

## ALTER START is rejected right after COMMIT

**Symptom.** "ALTER START not allowed while ... is in UPDATING status."

**Cause.** `COMMIT` puts the connector into `UPDATING`, asynchronously.

**Fix.** `SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, '<fqn>')` between `COMMIT`
and `START`. Teardown needs the same waits, with the caveat in the next entry.

*Verified.*

## DROP is rejected straight after TERMINATE, even though the wait returned OK

**Symptom.** Teardown terminates the connector, `SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS`
returns `OK`, and the `DROP` in the same batch fails. `SHOW OPENFLOW CONNECTORS IN ACCOUNT`
still reports `TERMINATING`.

**Cause.** The wait function returns before `SHOW` catches up. It reports stability, not that
the object has reached its terminal state.

**Fix.** Issue the `DROP` as its own call rather than chaining it after `TERMINATE`,
and check `SHOW` reports `TERMINATED` first. A moment's gap is enough; retry the `DROP` once if
it is rejected. Applies to runtimes as well as connectors.

*Verified 23 Sep 2026, on teardown of `WEO_PG_CDC`.*

## The journal table does not exist

**Symptom.** Looking for `OBSERVATIONS_JOURNAL%` returns nothing.

**Cause.** It is created alongside the destination table during the snapshot. On an older
connector build it appeared only on the first incremental event. Either way, an empty journal
before any change has been made is correct.

**Fix.** Nothing to fix. But **discover the name rather than hardcoding it**, because the
numeric suffix changes on every connector rebuild:

```sql
SELECT TABLE_NAME FROM WEO_CDC_DEMO.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'WEO' AND TABLE_NAME ILIKE 'OBSERVATIONS_JOURNAL%';
```

An existing journal holding **zero rows after a change has been made** is a different
problem: see the `CREATE STREAM` entry at the top.

*Verified 23 September 2026: created at snapshot, and the suffix changed from `1790195723_1`
to `1790196923_1` across a rebuild.*

## ACCOUNTADMIN cannot create objects in OPENFLOW_GEN2.CONTROL

**Symptom.** "Insufficient privileges to operate on schema 'CONTROL'. Your primary role
ACCOUNTADMIN must have CREATE SECRET granted on SCHEMA", or the same for
`CREATE NETWORK RULE`.

**Cause.** That schema is owned by `OPENFLOWADMIN`, and `ACCOUNTADMIN` does not inherit
create privileges on a schema owned by another role. Being account administrator is not the
same as owning everything.

**Fix.** Put both in `WEO_CDC_DEMO.PUBLIC`, which `ACCOUNTADMIN` owns. The secret does not
need to sit beside the connector: the connector config references it by fully-qualified name,
so it can live anywhere the runtime role has `READ` on it. Keeping it in the demo database
means one role throughout, and teardown removes it with everything else.

The secret was originally created in `OPENFLOW_GEN2.CONTROL` as `OPENFLOWADMIN`. That worked,
but it needed a role switch to create *and* another to drop, and it survived as an orphan
holding a live credential if teardown stopped part way.

*Verified 23 September 2026.*

## Repeated browser re-authentication during a build

**Symptom.** An OAuth browser prompt every few steps, sometimes many times in one provision.

**Cause.** Each `snow` invocation is a separate process that authenticates on its own. With
`authenticator = "oauth_authorization_code"` the token is meant to come from the macOS keychain
via `client_store_temporary_credential = true`, and when that cache is missed you get a fresh
prompt. Nothing about the build is wrong; there are simply too many separate CLI calls.

**Fix.** Use `snowflake_sql_execute`, which runs on the connection already established in the
session and needs no token. Keep `snow` for `snow stage copy` and the two scripts, which have no
SQL equivalent.

*Verified 28 September 2026, on a provision that prompted repeatedly until SQL moved off the
CLI.*

## Only the last statement's result comes back from a multi-statement call

**Symptom.** You send a batch through `snowflake_sql_execute` and see one result set rather than
one per statement.

**Cause.** Expected. The tool accepts several statements separated by semicolons and returns the
last one's result.

**Fix.** Nothing, but structure batches around it. Put the statement whose output you want last,
and split the call when you genuinely need two result sets. For grant blocks this does not matter,
because there is nothing to read.

One thing this costs you: per-statement confirmation. A `snow sql -f` run prints a status line per
statement, so a failure part-way through a long grant block is visible. Through the tool it is
not, so verify the outcome afterwards rather than trusting silence.

*Verified 28 September 2026.*

## snow sql cannot find the connection

**Symptom.** "Connection <account> is not configured."

**Cause.** No default connection is set, so `snow` falls back to the account name and finds
nothing. `default_connection_name` in `~/.snowflake/config.toml` can also name a connection that
does not exist, which looks like a default but is not one.

**Fix.** Establish the name once in preflight with `snow connection list` and pass
`-c <name>` on every CLI invocation. Do not assume a default exists, and do not assume the
connection is named after the account.

*Verified 23 September 2026. The dangling `default_connection_name` was seen on 28 September
2026, where it pointed at a connection name with no matching connection block.*

## Running the source SQL file prints the Postgres password

**Symptom.** The password appears in the terminal, the session transcript, and anywhere that
output is shared.

**Cause.** `CREATE POSTGRES INSTANCE` returns it in the `access_roles` column, so any method
that displays the statement's output exposes it.

**Fix.** `scripts/create-postgres-instance.py` runs that statement itself, parses the result,
and writes the password to `~/.pgpass` and a Snowflake secret without printing it. Everything
the instance depends on is ordinary SQL in the step 3 block of `provision/SKILL.md`, which stops short of the
`CREATE` for exactly this reason and is safe to run whole.

*Verified 23 September 2026, by doing exactly that during the build.*

## A commented SQL file cannot be split on semicolons

**Symptom.** Snowflake rejects a statement that is obviously prose, for example "syntax error
line 1 at position 0 unexpected 'if'".

**Cause.** Splitting on `;` before stripping comments cuts any comment containing a semicolon
in half, and the orphaned second half no longer starts with `--`, so a comment filter misses
it.

**Fix.** Do not hand-roll a SQL splitter. Send the whole block to `snowflake_sql_execute`, which
parses properly, or write it to a temporary file and use `snow sql -f`. Related: each `snow sql`
invocation is its own session, so a `USE ROLE` applies only to statements sent in the same call.
The same holds for the direct tool: a `USE ROLE` in one call does not carry to the next, so
include it at the top of any batch that needs it.

*Verified 23 September 2026.*

## CREATE POSTGRES INSTANCE fails with "Internal error occurred"

**Symptom.** Exactly that, with no detail.

**Cause.** Unknown, transient.

**Fix.** Nothing is left behind. Confirm with `SHOW POSTGRES INSTANCES` and retry once.

*Verified, seen once.*

## You cannot query your own demo data

**Symptom.** The connector reports success and the row count query fails on privileges, or
the schema appears empty.

**Cause.** The connector creates the destination schema and tables, so `OPENFLOW_CDC_ROLE`
owns them. `ACCOUNTADMIN` does not inherit ownership of objects created by another role.

**Fix.** The `GRANT SELECT ON FUTURE TABLES` and `GRANT USAGE ON FUTURE SCHEMAS` to
`ACCOUNTADMIN` in the step 5 block of `provision/SKILL.md`. They must be in place before the connector
starts, because `FUTURE` grants do not apply retroactively.

*Verified.*

## A single-row change takes up to a minute to appear

**Symptom.** The change is correct but arrives too late to narrate.

**Cause.** The default merge schedule is `0 * * * * ?`, once a minute on the zero second.

**Fix.** The patcher sets `* * * * * ?`. Observed end to end latency is then 25 to 30
seconds, so pace the narration for that rather than promising instant.

*Verified.*

## Editing the connector config appears to do nothing

**Symptom.** You upload a changed `config.json` and the connector keeps its old behaviour.

**Cause.** Committed versions are immutable. Uploading to a committed version is not an
edit.

**Fix.**

```sql
ALTER OPENFLOW CONNECTOR OPENFLOW_GEN2.CONTROL.WEO_PG_CDC ADD LIVE VERSION FROM LAST;
-- download, edit, upload, then COMMIT again, or ABORT
```

*Verified.*

## Inspecting connector components fails

**Symptom.** "Component [x] is managed by a Connector [y]; the Connector must be in
Troubleshooting mode for this component to be accessible."

**Cause.** A gen 2 connector's canvas is read-only.

**Fix.** Troubleshooting mode is a toggle in the Openflow UI, not a SQL command. Avoid
needing it: the event table plus `SYSTEM$GET_DBT_LOG`-style log access covers most
diagnosis.

*Verified.*

## Filtering the event table to one runtime returns nothing useful

**Symptom.** `RESOURCE_ATTRIBUTES` has `snow.openflow.deployment.id` but no runtime name,
so a deployment shared between runtimes gives mixed logs.

**Cause.** Telemetry is deployment-scoped, not runtime-scoped.

**Fix.** The runtime id is inside the log record, at `mdc.openflow.runtime.id`. Event table
rows are JSON *strings*, so parse before extracting:

```sql
SELECT TRY_PARSE_JSON(TO_VARCHAR(VALUE)):formattedMessage::STRING AS message
FROM <event_table>
WHERE ...;
```

*Verified.* This is a known product gap, not a configuration mistake.

## Snowsight cannot GET or PUT on the connector stage

**Symptom.** The stage browser will not upload or download.

**Cause.** Connector stages are not supported in the Snowsight stage UI.

**Fix.** `snow stage copy`.

*Verified.*

## Gen 2 objects are invisible to the tooling you would reach for

Not failures, but worth knowing before a customer finds them:

- Absent from `ACCESS_HISTORY`, `OBJECT_DEPENDENCIES` and Snowsight lineage.
- Resource monitors do not cover gen 2 compute pools, and gen 2 objects cannot be added to
  a budget, so nothing catches a forgotten deployment.
- No `CLONE`, `CREATE OR REPLACE`, `CREATE OR ALTER`, object tagging, sharing or DCM
  support. No replication or failover group, so no built-in cross-region DR.
- Avoid `GRANT OWNERSHIP` on a runtime. It is accepted in SQL and can break control-plane
  bindings.

One improvement worth quoting the other way: `USAGE` on a deployment does **not** grant
visibility of its runtimes, and a user needs a privilege on a deployment even to see it
listed. That makes multi-team isolation enforceable rather than a matter of trust.

*Verified.*
