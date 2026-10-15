{{
    config(
        materialized = 'view'
    )
}}

select
    unit_code::varchar(20)      as unit_code,
    unit_label::varchar(100)    as unit_label,
    is_rate::boolean            as is_rate

from {{ ref('imf_unit_dictionary') }}
