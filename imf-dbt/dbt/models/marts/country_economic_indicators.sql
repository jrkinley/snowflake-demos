{{
    config(
        materialized = 'table'
    )
}}

-- One row per country and year with the headline WEO indicators side by side.
--
-- The fact table is long and narrow, which is right for storage and wrong for
-- most questions. This is the wide, analyst-friendly shape, and the table the
-- semantic view is built on. Currency levels are converted from units to
-- billions here, once, so nobody has to remember the scale.

with observations as (

    select * from {{ ref('int_observations_latest_vintage') }}
    where indicator_code in (
        'NGDPD', 'NGDPDPC', 'NGDP_RPCH', 'PCPIPCH', 'LUR',
        'GGXWDG_NGDP', 'GGXCNL_NGDP', 'BCA_NGDPD', 'LP'
    )

),

entities as (

    select * from {{ ref('dim_entity') }}
    where entity_type = 'COUNTRY'

)

select
    o.country_code,
    e.entity_name                                                       as country_name,
    o.observation_year,

    max(iff(o.indicator_code = 'NGDPD',       o.observation_value / 1e9, null)) as gdp_usd_bn,
    max(iff(o.indicator_code = 'NGDPDPC',     o.observation_value, null))       as gdp_per_capita_usd,
    max(iff(o.indicator_code = 'NGDP_RPCH',   o.observation_value, null))       as real_gdp_growth_pct,
    max(iff(o.indicator_code = 'PCPIPCH',     o.observation_value, null))       as inflation_pct,
    max(iff(o.indicator_code = 'LUR',         o.observation_value, null))       as unemployment_rate_pct,
    max(iff(o.indicator_code = 'GGXWDG_NGDP', o.observation_value, null))       as govt_gross_debt_pct_gdp,
    max(iff(o.indicator_code = 'GGXCNL_NGDP', o.observation_value, null))       as govt_net_lending_pct_gdp,
    max(iff(o.indicator_code = 'BCA_NGDPD',   o.observation_value, null))       as current_account_pct_gdp,
    max(iff(o.indicator_code = 'LP',          o.observation_value / 1e6, null)) as population_mn,

    -- A year counts as projected if the headline GDP series says so.
    booland_agg(iff(o.indicator_code = 'NGDP_RPCH', o.is_projection, null))    as is_projection,
    max(o.vintage_label)                                                        as vintage_label

from observations o
inner join entities e
    on o.country_code = e.country_code
group by 1, 2, 3
