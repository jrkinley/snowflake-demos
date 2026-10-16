{{ config(materialized = 'semantic_view') }}

-- A Snowflake semantic view, defined and versioned as a dbt model.
--
-- The dbt_semantic_view package places this body straight after
-- CREATE OR REPLACE SEMANTIC VIEW, so it is native Snowflake DDL and picks up new
-- semantic view syntax without waiting for a package release. ref() still
-- resolves per environment and puts the view in the dbt DAG, so lineage runs from
-- the IMF API all the way to the questions Cortex Analyst answers.
--
-- The blocks below build up the business model Cortex Analyst reasons over:
-- logical tables, how they join, row-level facts, the dimensions to group and
-- filter by, and the aggregated metrics people ask for. Names and synonyms are
-- the vocabulary Analyst matches questions against; comments are its context.

-- TABLES: the logical tables, each an alias over a physical table built by dbt.
-- The primary key states the grain, which Analyst uses to aggregate correctly
-- and to join. economy is one row per country and year; countries is one row
-- per country.
TABLES (
    economy AS {{ ref('country_economic_indicators') }}
        PRIMARY KEY (country_code, observation_year)
        WITH SYNONYMS = ('economic indicators', 'macro data')
        COMMENT = 'Headline IMF WEO indicators, one row per country and year, latest vintage',
    countries AS {{ ref('dim_entity') }}
        PRIMARY KEY (country_code)
        COMMENT = 'Countries published in the IMF WEO'
)

-- RELATIONSHIPS: how the logical tables join. Many economy rows to one country,
-- through country_code. Analyst writes the join itself, so a question about
-- country names and GDP never needs one spelled out.
RELATIONSHIPS (
    economy_to_countries AS economy(country_code) REFERENCES countries(country_code)
)

-- FACTS: row-level numeric values, the inputs metrics aggregate. Not exposed for
-- grouping. growth_x_gdp is derived here, growth times GDP per row, so the
-- GDP-weighted growth metric can divide one sum by another.
FACTS (
    economy.gdp_usd_bn AS economy.gdp_usd_bn
        COMMENT = 'GDP at current prices, billions of US dollars',
    economy.population_mn AS economy.population_mn
        COMMENT = 'Population, millions',
    economy.growth_x_gdp AS economy.real_gdp_growth_pct * economy.gdp_usd_bn
        COMMENT = 'Real growth weighted by nominal GDP, used for GDP-weighted averages'
)

-- DIMENSIONS: the attributes questions group and filter by: country, year,
-- projection or actual, and release. Synonyms map everyday words ("nation",
-- "forecast") onto them.
DIMENSIONS (
    countries.country_name AS countries.entity_name
        WITH SYNONYMS = ('country', 'nation', 'economy name')
        COMMENT = 'Country name',
    economy.country_code AS economy.country_code
        WITH SYNONYMS = ('ISO code', 'country code')
        COMMENT = 'ISO 3166 alpha-3 country code',
    economy.year AS economy.observation_year
        WITH SYNONYMS = ('year', 'calendar year')
        COMMENT = 'Observation year',
    economy.is_projection AS economy.is_projection
        WITH SYNONYMS = ('forecast', 'projected', 'estimate')
        COMMENT = 'True when the year is an IMF staff projection rather than actual data',
    economy.vintage AS economy.vintage_label
        WITH SYNONYMS = ('release', 'WEO edition')
        COMMENT = 'The WEO release the figures come from'
)

-- METRICS: named aggregations, the numbers people ask for. Each one fixes how a
-- measure rolls up, which is where the business rules live: GDP and population
-- sum, rates average and are never summed, and growth across a group can be
-- either a simple average or weighted by GDP.
METRICS (
    economy.total_gdp_usd_bn AS SUM(economy.gdp_usd_bn)
        WITH SYNONYMS = ('GDP', 'economic output', 'size of the economy')
        COMMENT = 'Total GDP at current prices, billions of US dollars',
    economy.total_population_mn AS SUM(economy.population_mn)
        WITH SYNONYMS = ('population', 'people')
        COMMENT = 'Total population, millions',
    economy.avg_real_gdp_growth_pct AS AVG(economy.real_gdp_growth_pct)
        WITH SYNONYMS = ('growth', 'GDP growth', 'real growth')
        COMMENT = 'Simple average of real GDP growth, percent. Each country counts equally',
    economy.gdp_weighted_growth_pct AS SUM(economy.growth_x_gdp) / NULLIF(SUM(economy.gdp_usd_bn), 0)
        WITH SYNONYMS = ('weighted growth', 'aggregate growth')
        COMMENT = 'Real GDP growth weighted by nominal GDP, percent. Big economies count for more',
    economy.avg_inflation_pct AS AVG(economy.inflation_pct)
        WITH SYNONYMS = ('inflation', 'CPI', 'price growth')
        COMMENT = 'Average consumer price inflation, percent',
    economy.avg_unemployment_rate_pct AS AVG(economy.unemployment_rate_pct)
        WITH SYNONYMS = ('unemployment', 'jobless rate')
        COMMENT = 'Average unemployment rate, percent of the labour force',
    economy.avg_govt_debt_pct_gdp AS AVG(economy.govt_gross_debt_pct_gdp)
        WITH SYNONYMS = ('government debt', 'public debt', 'debt to GDP')
        COMMENT = 'Average general government gross debt, percent of GDP',
    economy.avg_current_account_pct_gdp AS AVG(economy.current_account_pct_gdp)
        WITH SYNONYMS = ('current account', 'external balance')
        COMMENT = 'Average current account balance, percent of GDP',
    economy.country_count AS COUNT(DISTINCT economy.country_code)
        WITH SYNONYMS = ('number of countries')
        COMMENT = 'Number of countries'
)

-- COMMENT describes the view; AI_SQL_GENERATION is standing guidance Analyst
-- applies to every question it turns into SQL.
COMMENT = 'IMF World Economic Outlook headline indicators for Cortex Analyst. Latest vintage, countries only, 1980 to five years ahead.'

AI_SQL_GENERATION 'Rates such as growth, inflation, unemployment and debt are percentages and must never be summed across countries; use the AVG metrics, or gdp_weighted_growth_pct for growth across a group. Years after the latest actual year are IMF projections: say so when an answer includes them. GDP is in billions of US dollars at current prices.'

-- AI_VERIFIED_QUERIES: questions paired with SQL known to be right. Analyst uses
-- them as worked examples for similar questions, and ONBOARDING_QUESTION shows
-- them as suggested starting questions. {{ this }} resolves to the view itself
-- in the current environment.
AI_VERIFIED_QUERIES (
    largest_economies AS (
        QUESTION 'What were the ten largest economies by GDP in 2025?'
        ONBOARDING_QUESTION TRUE
        SQL 'SELECT * FROM SEMANTIC_VIEW({{ this }} DIMENSIONS countries.country_name, economy.year METRICS economy.total_gdp_usd_bn WHERE economy.year = 2025) ORDER BY total_gdp_usd_bn DESC LIMIT 10'
    ),
    uk_growth_outlook AS (
        QUESTION 'What is the IMF forecast for UK real GDP growth?'
        ONBOARDING_QUESTION TRUE
        SQL 'SELECT * FROM SEMANTIC_VIEW({{ this }} DIMENSIONS economy.year, economy.is_projection METRICS economy.avg_real_gdp_growth_pct WHERE economy.country_code = ''GBR'' AND economy.is_projection) ORDER BY year'
    )
)
