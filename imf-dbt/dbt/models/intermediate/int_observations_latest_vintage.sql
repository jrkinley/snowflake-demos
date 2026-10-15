{{
    config(
        materialized = 'view'
    )
}}

-- The current view of the world: only the newest vintage of each series.
--
-- Most questions want today's numbers, not the full release history. Rather than
-- repeat this filter in every mart, it lives here once. Partitioning per series
-- rather than taking one global maximum means a series dropped from the latest
-- release keeps its last published values instead of vanishing.

select *
from {{ ref('fct_indicator_observations') }}
qualify vintage_published_at = max(vintage_published_at) over (
    partition by country_code, indicator_code
)
