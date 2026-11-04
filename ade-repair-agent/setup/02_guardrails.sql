-- The agent's guardrails. Run after 01_pipeline.sql.
--
-- The repair agent runs as you, not as a separate user. What keeps it safe is
-- the combination of two things:
--
--   1. ADE_AGENT_ROLE, a read-only role: it can read the demo data and the
--      semantic view, see the pipeline's run history and read its code, and
--      nothing else.
--   2. A restricted session scope, ADE_REPAIR_AGENT, attached to the agent. It
--      allows only ADE_AGENT_ROLE, so the agent can't switch to DEMO_ROLE,
--      ACCOUNTADMIN or any other role you hold, and it extends the built-in
--      read-only scope, so no write is possible whatever the role allows.
--
-- The fix the agent proposes goes to GitHub as a pull request. It never needs
-- to write to Snowflake.

-- Role. USERADMIN is enough to create it and grant it to you.
USE ROLE USERADMIN;
SET demo_user = CURRENT_USER();
CREATE ROLE IF NOT EXISTS ADE_AGENT_ROLE
  COMMENT = 'ADE repair agent demo: read-only access the repair agent works within';
GRANT ROLE ADE_AGENT_ROLE TO USER IDENTIFIER($demo_user);

-- Grants. DEMO_ROLE owns everything here, so it grants them.
USE ROLE DEMO_ROLE;
GRANT USAGE ON WAREHOUSE DEMO_WH TO ROLE ADE_AGENT_ROLE;
GRANT USAGE ON DATABASE DEMO_DB TO ROLE ADE_AGENT_ROLE;
GRANT USAGE ON SCHEMA DEMO_DB.TPCH_TRANSFORMED TO ROLE ADE_AGENT_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA DEMO_DB.TPCH_TRANSFORMED TO ROLE ADE_AGENT_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA DEMO_DB.TPCH_TRANSFORMED TO ROLE ADE_AGENT_ROLE;
GRANT SELECT ON SEMANTIC VIEW DEMO_DB.TPCH_TRANSFORMED.TPCH_ORDERS TO ROLE ADE_AGENT_ROLE;
-- Run history, errors and artifacts of the dbt project and the task
GRANT MONITOR ON DBT PROJECT DEMO_DB.TPCH_TRANSFORMED.COCO_DE_GUIDE TO ROLE ADE_AGENT_ROLE;
GRANT MONITOR ON TASK DEMO_DB.TPCH_TRANSFORMED.RUN_COCO_DE_GUIDE TO ROLE ADE_AGENT_ROLE;
-- The pipeline's code, as Snowflake last fetched it
GRANT READ ON GIT REPOSITORY DEMO_DB.TPCH_TRANSFORMED.ADE_DEMO_REPO TO ROLE ADE_AGENT_ROLE;

-- The scope. It lives in your personal database; replace <YOU> with your user name.
-- Desktop's "Restrict by role" picker lists scopes from USER$<YOU>.RSS, which
-- may not exist yet.
-- CREATE SCHEMA IF NOT EXISTS USER$<YOU>.RSS;
-- CREATE RESTRICTED SESSION SCOPE USER$<YOU>.RSS.ADE_REPAIR_AGENT
--   COMMENT = 'ADE repair agent: read only, ADE_AGENT_ROLE only'
--   AS $$
-- extend: [SNOWFLAKE$DATA_READ_WITH_AI]
-- role_scopes:
--   allowed_roles:
--     - ADE_AGENT_ROLE
-- $$;
