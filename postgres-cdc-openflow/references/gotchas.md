# Gotchas

The failures a run of this skill can actually hit. Each leads with what you see, because that is
all you have when it happens. Step numbers refer to `provision/SKILL.md`. Names are placeholders
from `state.json`, never the defaults.

Most diagnosis is in the event table. Its rows are JSON strings, so parse before extracting:
`TRY_PARSE_JSON(TO_VARCHAR(VALUE)):formattedMessage::STRING`.

## The snapshot works, then the first change never arrives

**Symptom.** The snapshot lands and the connector reports `RUNNING`. A source change never
arrives and the journal holds zero rows. The event table shows `Insufficient privileges to
perform Create Stream`, then the table moving from `INCREMENTAL_REPLICATION` to `FAILED`.

**Cause.** The connector builds a stream over each journal table to drive the merge. `CREATE
TABLE` is enough for the snapshot, so everything looks fine until the first change.

**Fix.** The step 6 grants. Granting afterwards is not enough: see the next entry.

## A table stuck in FAILED never retries

**Symptom.** After fixing the cause, `STOP` then `START` changes nothing. The event table shows
only `Stored state ... status=FAILED` being re-read.

**Cause.** Replication state is persisted per table, and a `FAILED` table is not retried.

**Fix.** Recreate the connector: `STOP`, `TERMINATE`, wait for `TERMINATED`, `DROP`, then:

```sql
DROP TABLE IF EXISTS <DEMO_DB>.WEO.OBSERVATIONS;
DROP TABLE IF EXISTS <DEMO_DB>.WEO."<JOURNAL_TABLE>";
```

Then rerun the connector part of step 8 (the stage and files are already there; skip `CREATE
STAGE`). About five minutes, and the snapshot reruns. The journal's numeric suffix
changes on the rebuild, which is why the demo discovers it.

## START_FAILED names several Source properties that are plainly set

**Symptom.** `Connector is invalid: Source Database Connection URL is required; Source Database
User is required; ...`, though `config.json` sets them all.

**Cause.** Not four missing values but one dropped section. Further back the event table says
`Failed to replace working configuration for step [Source]`. Usually the runtime role cannot
resolve the `SECRET_REFERENCE` because it lacks `USAGE` on the secret's schema. `READ ON SECRET`
alone is not enough.

**Fix.** Grant both, then rebuild the version, because config is synced at `COMMIT`, not `START`:

```sql
GRANT READ  ON SECRET <DEMO_DB>.PUBLIC.<PG_INSTANCE>_PASSWORD TO ROLE <RUNTIME_ROLE>;
GRANT USAGE ON SCHEMA <DEMO_DB>.PUBLIC TO ROLE <RUNTIME_ROLE>;
ALTER OPENFLOW CONNECTOR <CONTROL_SCHEMA>.<CONNECTOR> ADD LIVE VERSION FROM LAST;
ALTER OPENFLOW CONNECTOR <CONTROL_SCHEMA>.<CONNECTOR> COMMIT;
SELECT SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS(600, '<CONTROL_SCHEMA>.<CONNECTOR>');
ALTER OPENFLOW CONNECTOR <CONTROL_SCHEMA>.<CONNECTOR> START;
```

The staged files carry over. Whenever `START_FAILED` names several properties in one section,
suspect the section.

## START is accepted, then the connector sits in START_FAILED

**Symptom.** Retries every 10 seconds. The event table shows `PostgreSQL Connection Pool` failing
to enable, with no cause.

**Cause.** `Source Database Driver` is an `ASSET_REFERENCE` and is unset, or the JAR is not in
the same version as the config.

**Fix.** Check `LS` in step 8 lists both files and the template's `assetIds` is the bare
filename `postgresql-42.7.8.jar`. If the event table shows successful sessions as
`<RUNTIME_ROLE>`, the Snowflake half is fine and the source half is the problem.

## CDC replicates nothing, and nothing reports an error

**Symptom.** The snapshot lands, later changes never arrive, the connector is `RUNNING`.

**Cause.** `DROP TABLE` silently removes a table from a Postgres publication.

**Fix.** Always run both step 5 files together. To check by hand:

```sql
SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = 'openflow';
```

## CREATE NETWORK RULE rejects a host that looks fine

**Symptom.** "One or more values might be an unresolvable host name."

**Cause.** The rule checks the host resolves, so it cannot precede the instance.

**Fix.** Keep the order: instance in step 3, egress rule in step 6.

## START is rejected right after COMMIT

**Symptom.** "ALTER START not allowed while ... is in UPDATING status."

**Cause.** `COMMIT` moves the connector to `UPDATING`, asynchronously.

**Fix.** `SYSTEM$WAIT_FOR_STABLE_OPENFLOW_CONNECTORS` between `COMMIT` and `START`.

## DROP is rejected straight after TERMINATE, though the wait returned OK

**Symptom.** The `DROP` fails and `SHOW` still says `TERMINATING`.

**Cause.** The wait function reports stability, not the terminal state.

**Fix.** Wait for `SHOW` to report `TERMINATED`, issue the `DROP` as its own call, and retry it
once. Applies to runtimes too.

## CREATE POSTGRES INSTANCE fails with "Internal error occurred"

**Symptom.** Exactly that, with no detail.

**Cause.** Unknown, transient.

**Fix.** Confirm `SHOW POSTGRES INSTANCES` shows nothing, then retry step 3 once.

## You cannot query your own demo data

**Symptom.** The row count query fails on privileges, or the schema looks empty.

**Cause.** `<RUNTIME_ROLE>` owns what the connector creates.

**Fix.** The step 6 `FUTURE` grants to `<ADMIN_ROLE>`. They must be in place before the
connector starts, because `FUTURE` grants do not apply retroactively.

## snow sql cannot find the connection

**Symptom.** "Connection <account> is not configured."

**Cause.** No default connection, or `default_connection_name` names one that does not exist.

**Fix.** Pass `-c <CONNECTION>`, resolved in preflight with `snow connection list`.

## Editing the connector config does nothing

**Symptom.** A changed `config.json` is uploaded and behaviour does not change.

**Cause.** Committed versions are immutable.

**Fix.** `ALTER OPENFLOW CONNECTOR <CONTROL_SCHEMA>.<CONNECTOR> ADD LIVE VERSION FROM LAST;`,
upload, then `COMMIT` (or `ABORT`).

## LS on versions/live fails with "version live is not found"

**Symptom.** `LS 'snow://openflow_connector/<CONTROL_SCHEMA>.<CONNECTOR>/versions/live/'` errors.

**Cause.** `live` is the draft, which exists only between `ADD LIVE VERSION` and `COMMIT`.

**Fix.** List committed files through `versions/last/`. To read `config.json` itself, read it from
`@<DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/`, as the demo does: a path to one file inside a
connector version reads every file in it, JAR included, and fails to parse, and `PATTERN` or
`FILES` there return "No files found" (seen 2026-11-27).
