{{
    config(
        materialized = 'view'
    )
}}

-- Staging does one job: rename, cast, and nothing else.
-- No filtering, no business logic, no joins. Anything interpretive belongs in silver.

with source as (

    select * from {{ source('imf_raw', 'imf_weo_observations') }}

),

renamed as (

    select
        country_code::varchar(20)                       as country_code,
        indicator_code::varchar(40)                     as indicator_code,
        frequency::varchar(1)                           as frequency,
        try_to_number(time_period)::integer             as observation_year,
        obs_value::float                                as observation_value,
        scale::integer                                  as display_scale,
        nullif(unit, '')::varchar(20)                   as unit_code,

        -- The IMF publishes the last year of actual data per series, as text.
        -- Calendar-year series say '2025'; fiscal-year series say 'FY2024/25'.
        -- We keep the first year in either form, so a fiscal year that started
        -- in 2024 counts 2024 as its last actual.
        try_to_number(regexp_substr(latest_actual_annual_data, '[0-9]{4}'))::integer
                                                        as latest_actual_year,

        publication_date::timestamp_ntz                 as vintage_published_at,
        ingestion_timestamp::timestamp_ntz              as batch_loaded_at

    from source

)

select * from renamed
