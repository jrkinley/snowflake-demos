{% snapshot snap_gdp_growth_projections %}

{{
    config(
        schema = 'snapshots',
        strategy = 'check',
        unique_key = 'projection_key',
        check_cols = ['real_gdp_growth_pct']
    )
}}

-- Tracks how the IMF's forward projections move as new WEO vintages land.
--
-- Snapshots are the dbt answer to slowly changing dimensions. Each run compares
-- the current value against the stored one and writes a new row with validity
-- dates when it has changed.
--
-- The fact table already keeps every vintage, so why both? Because they answer
-- different questions. The fact table knows what each published release said.
-- The snapshot knows what this pipeline believed, and when. If a vintage is
-- reloaded, corrected or never loaded at all, only the snapshot records that.
-- The same problem appears in any backfilled history: data that changes after
-- the fact, and a need to know what it used to say.

select
    country_code || '|' || observation_year::varchar as projection_key,
    country_code,
    observation_year,
    real_gdp_growth_pct,
    vintage_label
from {{ ref('gdp_growth_by_country') }}
where is_projection

{% endsnapshot %}
