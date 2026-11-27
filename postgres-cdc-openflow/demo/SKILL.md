---
name: openflow-gen2-pg-cdc-walkthrough
description: "Part 2 of postgres-cdc-openflow. Load only from that skill's router, never directly."
parent_skill: postgres-cdc-openflow
---

# Part 2: Demo CDC

**The customer is looking at this pane.** Everything printed must be customer-facing. The
presenter's talk track lives in `<SKILL_DIR>/assets/cdc.sql`, open in Snowsight on their side;
nothing in this file is commentary to repeat.

Names come from `~/.cache/openflow-weo-demo/state.json`. Below, `<TARGET>` is
`<DEMO_DB>.WEO.OBSERVATIONS`, `<CONNECTOR_FQN>` is `<CONTROL_SCHEMA>.<CONNECTOR>`,
`<JOURNAL_TABLE>` is the journal table name found in step 6, and `<PSQL>` is:

```
psql "host=<pg_host> port=5432 user=snowflake_admin dbname=postgres sslmode=require"
```

with the real host substituted, so every printed command is paste-ready. `~/.pgpass` supplies
the password.

## Rules

Prose is two or three short sentences of explanation. No stage directions: never "say",
"point at", "now we", "takeaway".

1. **One step per turn.** Do the step, print its output, end with its gate, stop. Start each
   step with `# Step N of 6: <title>`, then this progress list, `✅` done, `▶️` current, `⬜` to
   come. Titles only, nothing else:
   ```
   ⬜ Built out of SQL
   ⬜ The configuration is a file
   ⬜ The whole dataset, already there
   ⬜ One value changes at source
   ⬜ And changes back
   ⬜ The change itself is a record
   ```
2. **Show every query, then run it** with the SQL tool and print the result as a table. Never
   post-process with shell pipelines; never show a figure that was not just queried. Begin every
   call with `USE ROLE <ADMIN_ROLE>;` (or `<OPENFLOW_ROLE>` for the connector queries in steps 1
   and 2), because the demo usually runs in a fresh session whose default role cannot see the
   demo objects. Keep the `USE ROLE` out of what you show the customer.
3. **Gates.** Every step ends with `ask_user_question`, customer-readable, no object names:
   - Plain steps: `Continue` / `Stay on this step`.
   - Postgres steps (4 and 5): **print the psql command in chat as a fenced `bash` block first**,
     then gate with `I've run it` / `Run it for me` / `Stay on this step`. The command is in chat
     so it can be copied; the gate only records the choice. "Run it for me" runs exactly the
     printed command with the bash tool and shows its output (`UPDATE 1`), nothing added.
4. **Polling.** After a Postgres change, poll the row every 10 s with the query shown, at most
   12 checks, printing each result. Say it usually takes under 30 seconds, never "instant".
5. **Never print the Postgres password**, and never print `state.json`. If anything fails or the
   change has not arrived after 12 checks, say so plainly and stop. Do not debug on a shared
   screen; `<SKILL_DIR>/references/gotchas.md` is for afterwards.

## Pre-flight (silent unless something is wrong)

Before step 1, every time:

1. Read `state.json`. If missing, stop: the demo is not provisioned.
2. Read the current source value. This command and its output are not shown on screen:
   ```bash
   <PSQL> -Atc "SELECT value FROM weo.observations WHERE country_code='GBR' AND indicator_code='NGDPD' AND frequency='Annual' AND year=2026"
   ```
3. **If it is `0`, a previous run never reverted.** Find the journal as in step 6, take the most
   recent non-zero `PAYLOAD__VALUE` for that key, and tell the presenter privately, in one line,
   before the customer is watching. Offer to restore it. Never guess a figure.
4. Hold the non-zero value as `ORIGINAL`. Steps 4 and 5 use it; nothing is hard-coded.
5. Confirm the destination agrees with the source. If not, wait up to 60 s for it to catch up.

## Step 1 of 6: Built out of SQL

Show that the pipeline is three Snowflake objects. Print this DDL as the shape of the setup,
not run, and say it is all it takes:

```sql
CREATE OPENFLOW DEPLOYMENT ... DEPLOYMENT_TYPE = SNOWFLAKE;
CREATE OPENFLOW RUNTIME ... IN DEPLOYMENT ... EXECUTE_AS_ROLE = ... EXTERNAL_ACCESS_INTEGRATIONS = (...);
CREATE OPENFLOW CONNECTOR ... IN RUNTIME ... FROM '@stage/path/';
```

Then run, narrowing the columns in the same call:

```sql
DESCRIBE OPENFLOW CONNECTOR <CONNECTOR_FQN>;
SELECT "name", "status", "runtime", "connector_definition", "owner", "default_version_name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
```

Explain: a deployment, a runtime and a connector, each created with SQL, owned by a role and
governed like any other Snowflake object.

Gate: `Continue` / `Stay on this step`.

## Step 2 of 6: The configuration is a file

```sql
LS 'snow://openflow_connector/<CONNECTOR_FQN>/versions/last/';
```

That is the connector's own committed copy: `config.json` plus the driver. Then read the
configuration from the bundle it was created from (the same file; a path to one file inside a
connector version reads every file in it, JAR included, and fails):

```sql
WITH cfg AS (
  SELECT $1 AS j
  FROM @<DEMO_DB>.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/config.json
       (FILE_FORMAT => '<DEMO_DB>.PUBLIC.RAW_JSON')
)
SELECT s.value:name::STRING AS section, p.key AS property, p.value:valueType::STRING AS value_type,
       COALESCE(p.value:value::STRING, p.value:fullyQualifiedSecretName::STRING,
                ARRAY_TO_STRING(p.value:assetIds, ', ')) AS setting
FROM cfg, LATERAL FLATTEN(input => j:configuration) s, LATERAL FLATTEN(input => s.value:properties) p
WHERE s.value:name::STRING = 'Source' AND setting IS NOT NULL
ORDER BY property;
```

Explain: each version is an immutable bundle of configuration plus driver, held on the
connector's own stage. The password is a `SECRET_REFERENCE`, the name of a Snowflake secret and
never the credential; the driver is an `ASSET_REFERENCE`. The whole pipeline is a reviewable file.

Gate: `Continue` / `Stay on this step`.

## Step 3 of 6: The whole dataset, already there

```sql
SELECT COUNT(*) AS observations, COUNT(DISTINCT COUNTRY_CODE) AS countries,
       COUNT(DISTINCT INDICATOR_CODE) AS indicators, MIN(YEAR) AS from_year, MAX(YEAR) AS to_year
FROM <TARGET>;
```

Explain: the full IMF World Economic Outlook, snapshotted by the connector into a table it
created from the source schema. The source is Snowflake Postgres, so nothing runs outside
Snowflake.

Gate: `Continue` / `Stay on this step`.

## Step 4 of 6: One value changes at source

Show the row first:

```sql
SELECT COUNTRY_CODE, INDICATOR_CODE, YEAR, VALUE, _SNOWFLAKE_UPDATED_AT
FROM <TARGET>
WHERE COUNTRY_CODE = 'GBR' AND INDICATOR_CODE = 'NGDPD' AND FREQUENCY = 'Annual' AND YEAR = 2026;
```

One sentence: UK GDP for 2026, in billions of US dollars. We will set it to zero in Postgres.

Then print the command, as a fenced `bash` block:

```bash
<PSQL> -c "UPDATE weo.observations SET value = 0 WHERE country_code = 'GBR' AND indicator_code = 'NGDPD' AND frequency = 'Annual' AND year = 2026"
```

Under it: "Run this in a terminal, or let me run it. Expect `UPDATE 1`."

Gate: `I've run it` / `Run it for me` / `Stay on this step`.

After the gate, apply rules 3 and 4 with the row query above until `VALUE` is `0`. Then explain:
one row changed among hundreds of thousands, nothing reran; the connector read it from the
Postgres write-ahead log and merged it. `_SNOWFLAKE_UPDATED_AT` moved.

Gate: `Continue` / `Stay on this step`.

## Step 5 of 6: And changes back

Print the revert, as a fenced `bash` block, with `ORIGINAL` substituted:

```bash
<PSQL> -c "UPDATE weo.observations SET value = <ORIGINAL> WHERE country_code = 'GBR' AND indicator_code = 'NGDPD' AND frequency = 'Annual' AND year = 2026"
```

Under it: "Putting the published figure back. Expect `UPDATE 1`."

Gate: `I've run it` / `Run it for me` / `Stay on this step`.

Then poll the step 4 row query until `VALUE` equals `ORIGINAL`. One sentence: the same path in
reverse, no special handling for a correction.

Gate: `Continue` / `Stay on this step`.

## Step 6 of 6: The change itself is a record

The connector creates the journal at the first change, so find it now, not earlier. The suffix
changes on every rebuild, so take the newest and hold it as `<JOURNAL_TABLE>`:

```sql
SELECT TABLE_NAME FROM <DEMO_DB>.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'WEO' AND TABLE_NAME ILIKE 'OBSERVATIONS_JOURNAL%'
ORDER BY CREATED DESC LIMIT 1;
```

```sql
SELECT SEEN_AT, EVENT_TYPE, PRIMARY_KEY__COUNTRY_CODE AS country,
       PRIMARY_KEY__YEAR AS yr, PAYLOAD__VALUE AS value
FROM <DEMO_DB>.WEO."<JOURNAL_TABLE>"
ORDER BY SEEN_AT DESC
LIMIT 5;
```

Explain: alongside current state, every change lands in a journal table, newest first. The top
two rows are the change to zero and the revert. Older rows, if any, are earlier run-throughs:
the journal is a record over time.

Final gate: `Finish` / `Stay on this step`.

## Output

On `Finish`, print one line thanking the audience. Then, privately and not on screen, remind the
presenter that Part 3 (`<SKILL_DIR>/teardown/SKILL.md`) removes everything after the meeting.
