{{ config(materialized = 'semantic_view') }}

-- A Snowflake semantic view, defined and versioned as a dbt model.
--
-- The dbt_semantic_view package places this body straight after
-- CREATE OR REPLACE SEMANTIC VIEW, so it is native Snowflake DDL and picks up new
-- semantic view syntax without waiting for a package release. ref() still
-- resolves per environment and puts the view in the dbt DAG, so lineage runs from
-- the IMF API all the way to the questions Cortex Analyst answers.

TABLES (
    economy AS {{ ref('country_economic_indicators') }}
        PRIMARY KEY (country_code, observation_year)
        WITH SYNONYMS = ('economic indicators', 'macro data')
        COMMENT = 'Headline IMF WEO indicators, one row per country and year, latest vintage',
    countries AS {{ ref('dim_entity') }}
        PRIMARY KEY (country_code)
        COMMENT = 'Countries published in the IMF WEO'
)

RELATIONSHIPS (
    economy_to_countries AS economy(country_code) REFERENCES countries(country_code)
)

FACTS (
    economy.gdp_usd_bn AS economy.gdp_usd_bn
        COMMENT = 'GDP at current prices, billions of US dollars',
    economy.population_mn AS economy.population_mn
        COMMENT = 'Population, millions',
    economy.growth_x_gdp AS economy.real_gdp_growth_pct * economy.gdp_usd_bn
        COMMENT = 'Real growth weighted by nominal GDP, used for GDP-weighted averages'
)

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

COMMENT = 'IMF World Economic Outlook headline indicators for Cortex Analyst. Latest vintage, countries only, 1980 to five years ahead.'

AI_SQL_GENERATION 'Rates such as growth, inflation, unemployment and debt are percentages and must never be summed across countries; use the AVG metrics, or gdp_weighted_growth_pct for growth across a group. Years after the latest actual year are IMF projections: say so when an answer includes them. GDP is in billions of US dollars at current prices.'

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
