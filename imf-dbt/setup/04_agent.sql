-- Creates IMF_WEO_ANALYST, a Cortex Agent for Snowflake CoWork over the IMF
-- WEO semantic view that dbt builds.
--
-- Run after the project is built (build_layers.sql), so
-- DEV_GOLD.IMF_WEO_ECONOMY exists:
--   snow sql -c <connection> -f setup/04_agent.sql
-- The agent lives in IMF_DBT_DB.PUBLIC, so the teardown drops it with the
-- database. Set the warehouse in tool_resources below to the one you use.
--
-- Two tools: Cortex Analyst over the semantic view for the numbers, and
-- data_to_chart for the visuals. The business rules (never sum rates, flag
-- projections) already live in the semantic view; the instructions here only
-- shape how the agent plans and answers.

-- PUBLIC is owned by ACCOUNTADMIN, not IMF_DBT_ROLE, so the role needs this
-- one grant to create an agent there.
USE ROLE ACCOUNTADMIN;
GRANT CREATE AGENT ON SCHEMA IMF_DBT_DB.PUBLIC TO ROLE IMF_DBT_ROLE;

USE ROLE IMF_DBT_ROLE;

CREATE OR REPLACE AGENT IMF_DBT_DB.PUBLIC.IMF_WEO_ANALYST
  COMMENT = 'IMF World Economic Outlook analyst over the dbt-built semantic view IMF_DBT_DB.DEV_GOLD.IMF_WEO_ECONOMY'
  PROFILE = '{"display_name": "IMF WEO Analyst", "color": "blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    budget:
      seconds: 120
      tokens: 32000

  instructions:
    orchestration: >
      Use imf_weo_economy for every question about countries, GDP, growth,
      inflation, unemployment, government debt, current account or population.
      Break comparative or multi-part questions into separate queries, one per
      measure or time window, rather than one large query. After each query
      that returns more than a few rows, call data_to_chart. Don't answer
      numeric questions from general knowledge; if the data can't answer, say
      so.
    response: >
      Lead with the answer in one or two sentences, then the supporting table
      or chart. Use a line chart for trends over years, a bar chart for
      rankings, and a scatter chart for relationships between two measures.
      State units every time: GDP in billions of US dollars at current prices,
      rates in percent. Mark any year after the latest actual as an IMF
      projection. Cite the WEO vintage the figures come from. Use British
      English.
    sample_questions:
      - question: "What were the ten largest economies by GDP in 2025?"
      - question: "What is the IMF forecast for UK real GDP growth?"
      - question: "Which countries carry the highest government debt relative to GDP?"

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "imf_weo_economy"
        description: >
          IMF World Economic Outlook headline indicators for around 200
          countries, one row per country and year from 1980 to five years
          ahead, latest WEO vintage. Measures: GDP (billions of US dollars at
          current prices), population, real GDP growth, consumer price
          inflation, unemployment rate, general government gross debt and
          current account balance (all percent). Dimensions: country name and
          ISO3 code, year, projection flag, WEO vintage. Use for any
          macroeconomic question about countries or years. Not for IMF
          regional or income-group aggregates, sub-national data, or anything
          outside these indicators.
    - tool_spec:
        type: "data_to_chart"
        name: "data_to_chart"
        description: "Generates charts from data returned by imf_weo_economy"

  tool_resources:
    imf_weo_economy:
      semantic_view: "IMF_DBT_DB.DEV_GOLD.IMF_WEO_ECONOMY"
      execution_environment:
        type: "warehouse"
        warehouse: "COMPUTE_WH"
  $$;

DESCRIBE AGENT IMF_DBT_DB.PUBLIC.IMF_WEO_ANALYST;
