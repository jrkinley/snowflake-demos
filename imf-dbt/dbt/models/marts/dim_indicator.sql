{{
    config(
        materialized = 'table'
    )
}}

-- Indicator dimension, built from the IMF's own CL_WEO_INDICATOR codelist.
--
-- The codelist is the governed definition of what each code means, so if the
-- source starts emitting an indicator the IMF has not defined, the relationships
-- test on the fact table fails. An indicator with no agreed definition should
-- not quietly reach gold.
--
-- The codelist carries names and definitions but not units. Units arrive on
-- each observation, so we take the unit and display scale each indicator is
-- published in.

with indicators as (

    select * from {{ ref('stg_imf__indicators') }}

),

published_units as (

    select
        indicator_code,
        mode(unit_code)         as unit_code,
        mode(display_scale)     as display_scale
    from {{ ref('stg_imf__observations') }}
    group by indicator_code

),

units as (

    select * from {{ ref('stg_imf__units') }}

)

select
    i.indicator_code,
    i.indicator_name,
    i.indicator_description,
    p.unit_code,
    coalesce(u.unit_label, 'Units')                     as unit_label,
    p.display_scale,

    -- Whether the value is a rate or a level changes how it can be aggregated.
    -- Summing a percentage or an index across countries is meaningless, so flag
    -- it here once rather than in every dashboard.
    not coalesce(u.is_rate, false)                      as is_additive,

    i.codelist_version

from indicators i
left join published_units p
    on i.indicator_code = p.indicator_code
left join units u
    on p.unit_code = u.unit_code
