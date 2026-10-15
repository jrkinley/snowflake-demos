{% docs __overview__ %}

# IMF World Economic Outlook

This project turns the IMF World Economic Outlook (WEO) into a governed, tested,
documented set of economic metrics, and keeps every release so you can see how
the IMF's forecasts move.

## Where the data comes from

The IMF publishes the WEO twice a year, in April and October. Each release, or
vintage, covers about 145 indicators for around 200 countries and 13 IMF
aggregates from 1980 to five years ahead. The `LOAD_IMF_WEO` stored procedure
lands each vintage from the public IMF SDMX 3.0 API into the `RAW` schema, with
the IMF's own codelists for indicator and country names. dbt reads `RAW` and
never writes to it.

## Layers

| Layer | Schema | What it holds |
|---|---|---|
| Bronze | `<ENV>_BRONZE` | Staging views: raw columns renamed and cast, nothing else |
| Silver | `<ENV>_SILVER` | `dim_entity`, `dim_indicator`, and `fct_indicator_observations`, one row per country, indicator, year and vintage |
| Gold | `<ENV>_GOLD` | `gdp_growth_by_country`, `country_economic_indicators`, and the `imf_weo_economy` semantic view for Cortex Analyst |
| Snapshots | `<ENV>_SNAPSHOTS` | `snap_gdp_growth_projections`, what this pipeline believed about each forecast, and when |

`<ENV>` is `DEV` or `PROD`, set by the environment chosen in `env.yml`.

## Business rules worth knowing

- **Countries versus aggregates.** Countries carry ISO3 codes and IMF aggregates
  carry G-prefixed codes such as G001 (World). `assert_country_sum_matches_world`
  checks that countries add up to the IMF's World total in every vintage.
- **Actuals versus projections.** Each IMF series says which year is its last
  actual. Later years are staff projections, flagged `is_projection`.
- **Units.** Values are stored in full units. The gold mart converts currency
  levels to billions and population to millions.

## Running it

Scheduled by a task graph in `DBT_PROJECTS`: `LOAD_IMF_WEO_TASK` lands the
latest vintage, then `BUILD_IMF_WEO_TASK` runs `dbt build` in the prod
environment.

{% enddocs %}
