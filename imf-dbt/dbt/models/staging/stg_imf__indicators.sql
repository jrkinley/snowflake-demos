{{
    config(
        materialized = 'view'
    )
}}

with source as (

    select * from {{ source('imf_raw', 'imf_weo_indicators') }}

),

renamed as (

    select
        indicator_code::varchar(40)         as indicator_code,
        indicator_name::varchar(300)        as indicator_name,
        indicator_description::varchar      as indicator_description,
        codelist_version::varchar(20)       as codelist_version

    from source

)

select * from renamed
