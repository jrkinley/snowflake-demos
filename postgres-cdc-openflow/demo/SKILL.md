---
name: openflow-gen2-pg-cdc-walkthrough
description: "Part 2 of the Openflow gen 2 PostgreSQL CDC demo: five guided steps showing change data capture live, with a customer watching the screen."
parent_skill: postgres-cdc-openflow
---

# Part 2: Demo CDC

## When to load

Router Step 0 confirmed a `RUNNING` connector with rows in `WEO_CDC_DEMO.WEO.OBSERVATIONS`,
and the customer is present.

**The customer is looking at this pane.** Everything you print is on a shared screen, so
everything you print must be customer-facing.

## How to run SQL

**Use `snowflake_sql_execute`, never `snow sql`.** Two reasons, and the second one is the
important one on a shared screen.

Each `snow` invocation is a separate process that authenticates on its own, so on an OAuth
connection it can throw a browser prompt mid-demo. And the CLI returns raw text you then have to
reformat, which tempts you into post-processing output with `python3` pipelines. The customer sees
that scaffolding and it looks nothing like the clean SQL story you are telling.

`SHOW` and `LS` both work directly. For a `SHOW` with too many columns to read on screen, narrow
it in the same call:

```sql
SHOW OPENFLOW RUNTIMES IN ACCOUNT;
SELECT "name", "status", "deployment", "node_type", "execute_as_role"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
```

The column names are lowercase and must be quoted. `RESULT_SCAN(LAST_QUERY_ID())` only works when
the `SHOW` is in the **same** call, because each call is its own session.

Only the last statement's result is returned, which is exactly what you want here.

`psql` is still the CLI, unavoidably. That is fine: the source change should visibly happen
outside Snowflake.

## Pre-flight: reset the demo value

**Do this before step 1, every time, and print nothing about it unless it needs fixing.**

Step 4 changes GBR 2026 `NGDPD` to zero and step 5 reverts it. If a previous run ended without
the revert, the value is already zero and step 4 asks the customer to watch zero become zero.
Nothing appears to happen, and you find out in front of them.

Check the **source**, not the destination, since the destination lags:

```bash
psql -t -c "SELECT value FROM weo.observations
            WHERE country_code='GBR' AND indicator_code='NGDPD' AND year=2026"
```

If it is not the published figure, reset it and wait for it to reach Snowflake before starting:

```bash
psql -c "UPDATE weo.observations SET value = <published figure>
         WHERE country_code='GBR' AND indicator_code='NGDPD' AND year=2026"
```

The published figure is whatever Part 1 recorded. If you do not have it, take it from the
journal table: the most recent non-zero `PAYLOAD__VALUE` for that key is it. Do not guess, and
do not assume 4264.794 — a new WEO vintage changes it.

Allow up to a minute for the reset to propagate, then confirm in Snowflake before step 1.
Starting the demo with the source and destination disagreeing is worse than waiting.

*Verified 24 September 2026: caught exactly this on a third run-through, where an earlier revert
had never been executed.*

## Pre-flight: confirm the connector version

**Also before step 1.** Step 2 reads the configuration out of the connector's stage, so confirm
the committed version is there first:

```sql
SHOW VERSIONS IN OPENFLOW CONNECTOR OPENFLOW_GEN2.CONTROL.WEO_PG_CDC;
```

A clean provision produces exactly one version, `VERSION$1`, and **one version is what the demo
uses**. Do not create a second one to illustrate versioning. Two versions on screen invite the
question of why the connector was committed twice, and the honest answer, that a commit had to
be redone, is a distraction from the point being made. A single immutable bundle carries it
perfectly well.

If a previous run left more than one version, that is cosmetic rather than a problem: step 2
reads `versions/last/`, so it still works. Say it was committed more than once if anyone asks.

*Added 28 September 2026, after a clean provision left one version where the step assumed two.
Simplified to one version on 29 September, because the branching was the confusing part.*

## Rules

Read all fourteen before starting, then follow them exactly.

1. Each step below has an **OUTPUT** section and a **NOTES** section. OUTPUT is what you
   print. NOTES is for you and the presenter only, and is **never printed, quoted or
   paraphrased on screen**.
2. Begin each step's output with a level-one heading using the title given, for example
   `# Step 3 of 5: The whole dataset, already there`.
3. **Directly under the heading, print the progress list**, exactly these five labels in this
   order, with `✅` for steps already done, `▶️` for the step you are on, and `⬜` for steps not
   yet reached:

   ```
   ✅ Built out of SQL
   ▶️ The configuration is a file, and the file is versioned
   ⬜ The whole dataset, already there
   ⬜ One value changes at source
   ⬜ The change itself is a record
   ```

   Nothing else in the list, and no commentary about it. This is an agenda, so it deliberately
   overrides rule 8 for titles only: the audience sees where the demo is going, which is worth
   more than preserving the surprise. Rule 8 still holds for everything else — never preview a
   step's content, queries or numbers.
4. **Never print scaffolding.** No "say", "run", "then", "point at", "takeaway", "what they
   see", no stage directions. If a line would look odd to a customer reading over the
   presenter's shoulder, it does not belong on screen.
5. Printed prose is explanation, not narration. Two or three short sentences that stand on
   their own. The presenter reads the screen and talks around it.
6. **One step per turn. Never more.** Do the step, then stop.
7. End every step with an `ask_user_question` gate worded so a customer can read it.
   "Continue" and "Stay on this step" are fine. Never put demo mechanics or internal object
   names in the gate.
8. Never preview a step's content, queries or numbers. The progress list in rule 3 is the one
   exception, and it shows titles only.
9. **Run every query yourself so the result appears on screen, and print the query too.**
   The customer should see both. Run it through `snowflake_sql_execute` and print the result as a
   table. **Never post-process output with a shell pipeline**: the customer sees the scaffolding,
   and it undercuts the point that all of this is plain SQL.
10. Keep each step short enough not to scroll. Roughly two minutes of talking.
11. **Every number comes from a live query.** Never print a figure from this file or from a
    previous run.
12. Never print the Postgres password. `~/.pgpass` supplies it.
13. Print `psql` commands for the presenter to run themselves, rather than running Postgres
    changes silently. The audience should see the change made at source.
14. **If something fails, say so plainly and stop.** Do not improvise on a shared screen.

## Step 1 of 5: Built out of SQL

**OUTPUT**

Open with the DDL, before showing anything else. Three statements are the entire setup:

```sql
CREATE OPENFLOW DEPLOYMENT WEO_CDC_DEPLOYMENT
  DEPLOYMENT_TYPE = SNOWFLAKE
  DISPLAY_NAME = 'WEO CDC demo';

CREATE OPENFLOW RUNTIME WEO_CDC_RT
  IN DEPLOYMENT WEO_CDC_DEPLOYMENT
  NODE_TYPE = MEDIUM
  NODE_TYPE_TIER = 'M4'
  MIN_NODES = 1
  MAX_NODES = 1
  EXECUTE_AS_ROLE = OPENFLOW_CDC_ROLE
  EXTERNAL_ACCESS_INTEGRATIONS = (WEO_CDC_PG_EAI);

CREATE OPENFLOW CONNECTOR WEO_PG_CDC
  IN RUNTIME WEO_CDC_RT
  FROM DEFINITION OPENFLOW_POSTGRES_CDC;
```

Say what each one costs in wall-clock time, because that is the part people do not expect:
the deployment takes five to ten minutes, the runtime three to five, the connector about one.
No infrastructure to request, no agents to install, nothing to size beyond a node type.

Then show what those statements produced:

```sql
SHOW OPENFLOW RUNTIMES IN ACCOUNT;
SHOW OPENFLOW CONNECTORS IN ACCOUNT;
```

```sql
DESCRIBE OPENFLOW CONNECTOR OPENFLOW_GEN2.CONTROL.WEO_PG_CDC;
```

Explain, in your own short sentences: a deployment, a runtime and a connector, each a
Snowflake object created with SQL, owned by a Snowflake role, and governed exactly like a table
or a warehouse. No infrastructure to request and no agent to install anywhere.

Stop there. The configuration is the next step's job.

**NOTES**

The DDL above is the shape of the setup, not a transcript of this build: the deployment was
reused, and the runtime carried a `COMMENT` that is stripped here for readability. Say "this is
all it takes", not "this is what I ran ten minutes ago" — an engineer may ask to see the
deployment's creation timestamp.

`SHOW ... IN ACCOUNT` is account-wide, so unrelated runtimes and connectors can appear,
including terminated ones. That is deliberate: it is a real account, and "what is that one"
is a fair question with an easy answer. Do not pretend it is not there.

`DESCRIBE` returns around twenty columns, most of them empty version and git fields, plus a
NiFi URL carrying the account hostname. Show `status`, `runtime`, `connector_definition`,
`owner` and `default_version` and leave the rest.

`status RUNNING` next to the `default_version` column makes the versioning point on its own.
Worth a pause.

The gen 1 contrast is the point, if they ask: a manual external access attach in the UI
before anything could reach the source, and a manual detach before teardown. Here the
integration is attached inline on `CREATE OPENFLOW RUNTIME` and dropping the runtime
detaches it.

Do not offer to open the canvas. It is read-only on a gen 2 connector and the error message
is unhelpful in front of an audience.

## Step 2 of 5: The configuration is a file, and the file is versioned

**OUTPUT**

The connector's own configuration lives on an internal stage that belongs to the connector.
Every commit creates an immutable version. List the committed version:

```sql
LS 'snow://openflow_connector/OPENFLOW_GEN2.CONTROL.WEO_PG_CDC/versions/version$1/';
```

Point out that the version carries **both** the configuration and the JDBC driver it needs, so
a version is a complete, self-contained bundle rather than a pointer to whatever happens to be
installed. Committing again produces `VERSION$2` and leaves this one untouched, so a rollback is
picking a version rather than reconstructing a state.

Then read the configuration itself, with SQL, out of the stage:

```sql
WITH cfg AS (
  SELECT $1 AS j
  FROM 'snow://openflow_connector/OPENFLOW_GEN2.CONTROL.WEO_PG_CDC/versions/last/config.json'
    (FILE_FORMAT => 'WEO_CDC_DEMO.PUBLIC.RAW_JSON')
)
SELECT s.value:name::STRING        AS section,
       p.key                       AS property,
       p.value:valueType::STRING   AS value_type,
       COALESCE(p.value:value::STRING,
                p.value:fullyQualifiedSecretName::STRING,
                ARRAY_TO_STRING(p.value:assetIds, ', ')) AS setting
FROM cfg,
     LATERAL FLATTEN(input => j:configuration) s,
     LATERAL FLATTEN(input => s.value:properties) p
WHERE s.value:name::STRING = 'Source'
  AND COALESCE(p.value:value::STRING,
               p.value:fullyQualifiedSecretName::STRING,
               ARRAY_TO_STRING(p.value:assetIds, ', ')) IS NOT NULL
ORDER BY property;
```

Draw out the `value_type` column, which is where the interesting part is:

- `SECRET_REFERENCE` on the password. The file holds the **name** of a Snowflake secret, never
  the password. Nobody reading this configuration, in a stage or a pull request, sees a
  credential.
- `ASSET_REFERENCE` on the driver. The JDBC JAR is a versioned asset alongside the config, not
  something installed on a server by hand.
- Everything else is a plain literal, so the whole pipeline is a text file: reviewable,
  diffable, and deployable the same way you deploy anything else.

**NOTES**

`versions/last/` is an alias, verified working, so this needs no substitution as versions
accumulate. `versions/live/` only exists **between** `ADD LIVE VERSION` and `COMMIT` — once
committed it disappears, and using it here fails with "version live is not found".

The demo deliberately runs on a single version. If a previous run left two, the step still works
because it reads `versions/last/`, and "it was committed twice" is the honest answer. Do not
manufacture a second version for effect.

`RAW_JSON` is created during provisioning, so there is no file format to create on screen.

`DESCRIBE` also exposes `default_version_source_location_uri` and
`default_version_git_commit_hash`, both empty here. They strongly suggest configurations can be
sourced from Git. **Do not promise that** — it is untested. If someone asks, say the fields
exist and you will confirm the workflow rather than guessing at it.

If they ask how the config got there: downloaded from the stage, edited, uploaded, committed.
Four steps, all scriptable, no wizard.

Do not open config.json in an editor on screen. It is 4.8 KB of mostly empty properties and it
undersells what the query above shows cleanly.

## Step 3 of 5: The whole dataset, already there

**OUTPUT**

```sql
SELECT COUNT(*) AS observations,
       COUNT(DISTINCT COUNTRY_CODE) AS countries,
       COUNT(DISTINCT INDICATOR_CODE) AS indicators,
       MIN(YEAR) AS from_year,
       MAX(YEAR) AS to_year
FROM WEO_CDC_DEMO.WEO.OBSERVATIONS;
```

Explain: this is the entire published IMF World Economic Outlook, not a sample, and the
connector created the destination table itself from the source schema. The source is a
Snowflake Postgres instance, so the database being replicated is also inside Snowflake and
there is no external infrastructure in the picture.

**NOTES**

If asked where it came from: the IMF publishes the full database twice a year and this is
the current vintage, loaded unchanged.

## Step 4 of 5: One value changes at source

**OUTPUT**

Show the current row first:

```sql
SELECT COUNTRY_CODE, INDICATOR_CODE, YEAR, VALUE
FROM WEO_CDC_DEMO.WEO.OBSERVATIONS
WHERE COUNTRY_CODE = 'GBR' AND INDICATOR_CODE = 'NGDPD' AND YEAR = 2026;
```

Then print the command for the presenter to run against Postgres, using the captured before
and after values:

```sql
UPDATE weo.observations SET value = <after>
WHERE country_code = 'GBR' AND indicator_code = 'NGDPD' AND year = 2026;
```

Wait for them to confirm they have run it, then re-run the Snowflake query until the new
value appears. Say that it takes around half a minute rather than implying instant.

Explain: one row changed in a table of several hundred thousand, and nothing was rerun or
rescheduled. The connector read the change from the Postgres write-ahead log and merged it.

**NOTES**

Observed latency is 30 to 45 seconds because the merge schedule is set to every second. The
connector default is once a minute, which is right for production and too slow to narrate.

If nothing arrives after about 90 seconds, stop and say so. Then check, in this order: the
journal table's row count, and the event table for a `CREATE STREAM` privilege error. Both
are in [../references/gotchas.md](../references/gotchas.md). Do not debug on the shared
screen.

## Step 5 of 5: The change itself is a record

**OUTPUT**

Find the journal table, then read it:

```sql
SELECT TABLE_NAME FROM WEO_CDC_DEMO.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'WEO' AND TABLE_NAME ILIKE 'OBSERVATIONS_JOURNAL%';
```

```sql
SELECT SEEN_AT, EVENT_TYPE,
       PAYLOAD__COUNTRY_CODE AS COUNTRY,
       PAYLOAD__YEAR AS YEAR,
       PAYLOAD__VALUE AS VALUE
FROM WEO_CDC_DEMO.WEO."<JOURNAL_TABLE>"
ORDER BY SEEN_AT DESC
LIMIT 5;
```

Newest first, five rows. The change from step 4 is the top row, so point at that before talking
about the ones underneath it.

Explain: alongside the current state, every change arrives as a row in a journal table, so
the history of the change is available rather than only its outcome.

Then print the revert for the presenter to run, so the demo can be given again:

```sql
UPDATE weo.observations SET value = <before>
WHERE country_code = 'GBR' AND indicator_code = 'NGDPD' AND year = 2026;
```

**NOTES**

`EVENT_TYPE` is `IncrementalUpdateRows`. The destination table also carries
`_SNOWFLAKE_UPDATED_AT`, which moves with each change, if that question comes up.

`LIMIT 5` is deliberate. The journal is append-only and never truncated, so it accumulates a row
for every rehearsal as well as every real change. An unbounded `ORDER BY SEEN_AT` grows with each
run, scrolls the result, and buries the change just made under older ones. Newest first keeps it
at the top where the customer is already looking.

The older rows are a feature rather than a mess, so do not apologise for them. They are previous
edits to the same two UK figures, and they make the point that the journal is a record over time
rather than a snapshot of the last thing that happened. If anyone asks, say they are earlier
run-throughs of this demo.

Its numeric suffix changes on every redeploy, which is why it is discovered rather than
written down.

Gaps to answer honestly if their engineers ask: gen 2 objects do not appear in
`ACCESS_HISTORY`, `OBJECT_DEPENDENCIES` or Snowsight lineage; resource monitors do not cover
gen 2 compute pools; telemetry is deployment-scoped rather than runtime-scoped. Say so
plainly rather than deflecting. Full list in `gotchas.md`.

## Output

Confirm the revert landed, then stop.

**Next:** remind the presenter privately, not on screen, that Part 3 should run after the
meeting. Load `<SKILL_DIR>/teardown/SKILL.md` when they are ready.
