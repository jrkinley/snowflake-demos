{{
    config(
        materialized = 'table'
    )
}}

-- Conformed entity dimension.
--
-- The source mixes real countries with IMF aggregates in one column. Sum them
-- together and world GDP comes out at several times its real value, while every
-- structural test still passes.
--
-- In the SDMX codelist the rule is clean: countries carry ISO 3166 alpha-3 codes
-- (GBR, USA), and IMF aggregates carry G-prefixed group codes (G001 World,
-- G119 G7, G163 Euro area). So anything that is not three letters is an
-- aggregate. The rule is not self-validating, which is why
-- assert_country_sum_matches_world exists: it fails if a new aggregate ever
-- arrives in a shape this rule misses.
--
-- Only codes that actually appear in the data are kept. The codelist also
-- lists territories the WEO does not publish.

with observed as (

    select distinct country_code
    from {{ ref('stg_imf__observations') }}

),

codelist as (

    select * from {{ ref('stg_imf__countries') }}

)

select
    o.country_code,
    coalesce(c.country_name, o.country_code)            as entity_name,

    case
        when regexp_like(o.country_code, '^[A-Z]{3}$') then 'COUNTRY'
        else 'AGGREGATE'
    end                                                 as entity_type,

    c.country_code is not null                          as in_codelist

from observed o
left join codelist c
    on o.country_code = c.country_code
