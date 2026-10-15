{{
    config(
        materialized = 'incremental',
        incremental_strategy = 'merge',
        unique_key = ['country_code', 'indicator_code', 'observation_year', 'vintage_published_at'],
        on_schema_change = 'append_new_columns'
    )
}}

-- The grain-level fact: one row per country, indicator, year and vintage.
--
-- The IMF publishes a full WEO vintage twice a year, in April and October. A new
-- vintage restates history as well as moving the forecast, so we keep every
-- vintage rather than overwriting. That lets you ask how a forecast changed
-- between releases, which the source itself cannot answer once it has moved on.
--
-- On the first run the is_incremental() block is skipped and everything is built.
-- On later runs we only read vintages newer than what we already hold, and merge
-- on the full grain so a reloaded vintage replaces itself rather than doubling.
--
-- Worth knowing: if you change this logic, a normal run will not repair rows that
-- the old logic already wrote. You need --full-refresh for that.

with observations as (

    select * from {{ ref('stg_imf__observations') }}
    where observation_year is not null

    {% if is_incremental() %}
      and vintage_published_at >= (
          select coalesce(max(vintage_published_at), '1900-01-01'::timestamp_ntz)
          from {{ this }}
      )
    {% endif %}

)

select
    -- Natural key made explicit so the merge is readable.
    country_code,
    indicator_code,
    observation_year,
    vintage_published_at,

    observation_value,

    -- The business rule. The IMF says, per series, which year is the last one of
    -- actual data, and everything after it is a staff projection. Where a series
    -- carries no such marker, fall back to the project-wide default.
    coalesce(latest_actual_year, {{ var('last_actual_year') }})     as latest_actual_year,
    observation_year > coalesce(latest_actual_year, {{ var('last_actual_year') }})
                                                                    as is_projection,
    greatest(observation_year - coalesce(latest_actual_year, {{ var('last_actual_year') }}), 0)
                                                                    as years_ahead_of_actual,

    'WEO ' || to_char(vintage_published_at, 'MON YYYY')             as vintage_label,

    batch_loaded_at,
    current_timestamp()                                             as dbt_updated_at

from observations
