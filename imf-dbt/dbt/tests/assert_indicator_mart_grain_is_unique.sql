-- country_economic_indicators pivots the long fact into one row per country and
-- year. If the latest-vintage filter upstream ever let two vintages through,
-- this is where the duplicate would surface.

select country_code, observation_year, count(*) as row_count
from {{ ref('country_economic_indicators') }}
group by 1, 2
having count(*) > 1
