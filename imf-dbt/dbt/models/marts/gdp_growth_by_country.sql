{{
    config(
        materialized = 'table'
    )
}}

-- Real GDP growth by country and year, the metric played end to end.
--
-- This is the model to walk through, because it shows what the layers bought us:
--   the opaque code NGDP_RPCH now carries a name, a unit and a definition
--   IMF aggregates are excluded, so an average across rows means something
--   actual and projected years are distinguishable, per the IMF's own marker
--   the metric is defined once, here, rather than in every BI tool

with observations as (

    select * from {{ ref('int_observations_latest_vintage') }}
    where indicator_code = 'NGDP_RPCH'

),

entities as (

    select * from {{ ref('dim_entity') }}
    where entity_type = 'COUNTRY'

),

indicators as (

    select * from {{ ref('dim_indicator') }}

)

select
    o.country_code,
    e.entity_name                   as country_name,
    o.observation_year,

    o.observation_value             as real_gdp_growth_pct,
    i.indicator_name,
    i.unit_label,

    o.is_projection,
    o.years_ahead_of_actual,
    o.vintage_label,

    -- Simple derived measures, the sort of thing an analyst would otherwise
    -- rewrite in every dashboard.
    avg(o.observation_value) over (
        partition by o.country_code
        order by o.observation_year
        rows between 4 preceding and current row
    )                               as real_gdp_growth_pct_5yr_avg,

    o.observation_value < 0         as is_contraction,

    o.vintage_published_at

from observations o
inner join entities e
    on o.country_code = e.country_code
inner join indicators i
    on o.indicator_code = i.indicator_code
where o.observation_value is not null
