-- Guards the business rule the rest of the project depends on.
--
-- The projection flag comes from each series' latest-actual marker, with the
-- last_actual_year variable as a fallback. If the IMF stops publishing the
-- marker and the variable drifts past the end of the data, or the marker is
-- misparsed, the flag becomes wrong everywhere downstream and nothing else
-- would notice.
--
-- Fails if the latest vintage has no projected rows at all, or if any latest
-- actual year sits outside a believable window.

with latest as (

    select * from {{ ref('int_observations_latest_vintage') }}

)

select 'no projected rows in the latest vintage' as failure, count(*) as rows_affected
from latest
having count_if(is_projection) = 0

union all

select 'latest actual year out of range', count(*)
from latest
where latest_actual_year not between 2000 and year(current_date())
having count(*) > 0
