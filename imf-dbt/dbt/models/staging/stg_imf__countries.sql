{{
    config(
        materialized = 'view'
    )
}}

with source as (

    select * from {{ source('imf_raw', 'imf_weo_countries') }}

),

renamed as (

    select
        country_code::varchar(20)           as country_code,
        country_name::varchar(200)          as country_name,
        codelist_version::varchar(20)       as codelist_version

    from source

)

select * from renamed
