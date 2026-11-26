-- =============================================================================
-- Openflow gen 2 PostgreSQL CDC demo: presenter worksheet
-- =============================================================================
-- Paste into a Snowsight worksheet and keep it open beside the demo. Run one
-- statement at a time (Cmd/Ctrl+Enter on the cursor line).
--
-- Comments are the talk track: what the query shows and what to say over it.
-- The customer sees the worksheet, so keep the comments short if you share it.
--
-- Edit the SET block to match ~/.cache/openflow-weo-demo/state.json. Two
-- statements take literal names because SQL does not allow variables there;
-- they are marked EDIT.
-- =============================================================================

SET demo_db        = 'WEO_CDC_DEMO';
SET connector_fqn  = 'OPENFLOW_GEN2.CONTROL.WEO_PG_CDC';
SET target_table   = $demo_db || '.WEO.OBSERVATIONS';

-- The one row the demo changes: UK GDP in current US dollars, 2026, in billions.
SET country   = 'GBR';
SET indicator = 'NGDPD';
SET yr        = 2026;

USE ROLE ACCOUNTADMIN;
USE DATABASE IDENTIFIER($demo_db);


-- =============================================================================
-- 0. Setup, for reference. ALREADY RUN; do not run again.
-- =============================================================================
-- "This is the whole setup. Three SQL objects: a deployment, a runtime and a
-- connector. Each is a Snowflake object, owned by a role and governed like a
-- table or a warehouse. Nothing to install, no infrastructure ticket."
--
-- Wall clock, because people don't expect it: deployment 5 to 10 minutes,
-- runtime 3 to 5, connector about one.
--
-- The external access integration is attached inline on the runtime. In gen 1
-- that was a manual step in the Openflow UI; missing it produced errors that
-- looked like firewall faults.
--
-- CREATE OPENFLOW DEPLOYMENT WEO_CDC_DEPLOYMENT
--   DEPLOYMENT_TYPE = SNOWFLAKE;
--
-- CREATE OPENFLOW RUNTIME WEO_CDC_RT
--   IN DEPLOYMENT WEO_CDC_DEPLOYMENT
--   NODE_TYPE = MEDIUM NODE_TYPE_TIER = 'M4' MIN_NODES = 1 MAX_NODES = 1
--   EXECUTE_AS_ROLE = OPENFLOW_CDC_ROLE
--   EXTERNAL_ACCESS_INTEGRATIONS = (WEO_CDC_PG_EAI);
--
-- CREATE OPENFLOW CONNECTOR WEO_PG_CDC
--   IN RUNTIME WEO_CDC_RT
--   FROM '@WEO_CDC_DEMO.PUBLIC.CONNECTOR_BUNDLE/pg_cdc/';   -- or FROM DEFINITION OPENFLOW_POSTGRES_CDC


-- =============================================================================
-- 1. What exists: the objects and their state
-- =============================================================================
-- "Same SHOW and DESCRIBE you'd use on any Snowflake object."
-- SHOW ... IN ACCOUNT lists everything, so other runtimes may appear. That is a
-- real account; say so if asked.

SHOW OPENFLOW RUNTIMES IN ACCOUNT;
SHOW OPENFLOW CONNECTORS IN ACCOUNT;

DESCRIBE OPENFLOW CONNECTOR IDENTIFIER($connector_fqn);
-- Point at: status RUNNING, connector_definition, owner, default_version.

-- "Every configuration change is an immutable version. Rolling back is picking
-- a version, not rebuilding a state."
SHOW VERSIONS IN OPENFLOW CONNECTOR IDENTIFIER($connector_fqn);
-- source_location_uri shows where the version came from: here an internal
-- stage, in production a Git repository.


-- =============================================================================
-- 2. The configuration is a file, and you can query it
-- =============================================================================
-- "The connector's configuration is a JSON file on the connector's own stage.
-- So it's reviewable, diffable and deployable like any other code."
--
-- EDIT: the path must be a literal. Replace the connector FQN if yours differs.

LS 'snow://openflow_connector/OPENFLOW_GEN2.CONTROL.WEO_PG_CDC/versions/last/';
-- A version holds the config AND the JDBC driver, so it is a self-contained
-- bundle, not a pointer to whatever is installed on a server.

-- EDIT: same literal path as above.
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
WHERE setting IS NOT NULL
ORDER BY section, property;
-- Point at value_type:
--   SECRET_REFERENCE  the password is the NAME of a Snowflake secret. Nobody
--                     reading this file, in a stage or a pull request, sees a
--                     credential.
--   ASSET_REFERENCE   the JDBC driver is a versioned asset, not hand-installed.
--   Merge Task Schedule CRON is every second for the demo; the default is once
--   a minute, which is right for production.
--
-- Git: ALTER OPENFLOW CONNECTOR ... PUSH TO '@my_git_repo/branches/main/...'
-- commits this bundle to a repository, and CREATE OPENFLOW CONNECTOR ... FROM
-- '@my_git_repo/...' deploys from one. Same file, same review process as code.


-- =============================================================================
-- 3. The whole dataset, already there
-- =============================================================================
-- "This is the full IMF World Economic Outlook, not a sample. The connector
-- created the destination table from the source schema and snapshotted it.
-- The source is Snowflake Postgres, so nothing here runs outside Snowflake."

SELECT COUNT(*)                       AS observations,
       COUNT(DISTINCT COUNTRY_CODE)   AS countries,
       COUNT(DISTINCT INDICATOR_CODE) AS indicators,
       MIN(YEAR)                      AS from_year,
       MAX(YEAR)                      AS to_year
FROM IDENTIFIER($target_table);

SHOW TABLES IN SCHEMA WEO;   -- the worksheet's database is $demo_db
-- OBSERVATIONS is current state. OBSERVATIONS_JOURNAL_<n> is the change log,
-- section 5. The NESTED_ERROR_TABLE_* tables catch rows that fail to load.


-- =============================================================================
-- 4. One value changes at source
-- =============================================================================
-- The row before the change. Note VALUE and _SNOWFLAKE_UPDATED_AT.

SELECT COUNTRY_CODE, INDICATOR_CODE, YEAR, VALUE, _SNOWFLAKE_UPDATED_AT
FROM IDENTIFIER($target_table)
WHERE COUNTRY_CODE = $country AND INDICATOR_CODE = $indicator
  AND FREQUENCY = 'Annual' AND YEAR = $yr;

-- Now change it in Postgres: set VALUE to 0. CoCo prints the psql command.
-- "One row changes in a table of several hundred thousand. Nothing reruns,
-- nothing is rescheduled. The connector reads the change from the Postgres
-- write-ahead log and merges it."
--
-- Re-run the SELECT above every 15 seconds or so. Expect 30 to 60 seconds:
-- the merge runs every second, the rest is commit and batching.
-- VALUE becomes 0 and _SNOWFLAKE_UPDATED_AT moves.
--
-- Then revert it in Postgres, and re-run again to watch the original return.


-- =============================================================================
-- 5. The change itself is a record
-- =============================================================================
-- "Alongside current state, every change lands as a row in a journal table,
-- so you have the history of the change, not only its outcome."
--
-- The journal's name carries a suffix that changes on every rebuild, so find it.

SET journal_table = (
  SELECT TABLE_CATALOG || '.' || TABLE_SCHEMA || '."' || TABLE_NAME || '"'
  FROM INFORMATION_SCHEMA.TABLES
  WHERE TABLE_SCHEMA = 'WEO' AND TABLE_NAME ILIKE 'OBSERVATIONS_JOURNAL%'
  ORDER BY TABLE_NAME DESC
  LIMIT 1
);

SELECT SEEN_AT,
       EVENT_TYPE,
       PRIMARY_KEY__COUNTRY_CODE   AS country,
       PRIMARY_KEY__INDICATOR_CODE AS indicator,
       PRIMARY_KEY__YEAR           AS yr,
       PAYLOAD__VALUE              AS value
FROM IDENTIFIER($journal_table)
ORDER BY SEEN_AT DESC
LIMIT 5;
-- Newest first. The top two rows are the change to 0 and the revert.
-- The journal is append-only, so older rows are earlier run-throughs. That's
-- the point: a record over time, not a snapshot of the last thing.
--
-- Honest answers if engineers ask: gen 2 objects don't yet appear in
-- ACCESS_HISTORY, OBJECT_DEPENDENCIES or Snowsight lineage; resource monitors
-- don't cover gen 2 compute pools; telemetry is per deployment, not per runtime.
