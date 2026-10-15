-- The test that actually protects the grain.
--
-- Nothing in a not_null or unique test would catch the bug this guards against.
-- If an aggregate is misclassified as a country, the data is still complete,
-- unique and correctly typed. World GDP just silently comes out several times
-- too large, and every structural test passes while the number is nonsense.
--
-- This asserts a business invariant instead: the countries should add up to the
-- IMF's own World total (G001), in every vintage. A 2% tolerance covers rounding
-- and the handful of economies the IMF does not publish. If an aggregate arrives
-- in a shape dim_entity does not recognise, the sum jumps and this fails.
--
-- That is the shape of test most revenue metrics need: a control total, not a
-- column check.

with countries as (

    select f.vintage_published_at, sum(f.observation_value) as country_total
    from {{ ref('fct_indicator_observations') }} f
    join {{ ref('dim_entity') }} e
        on f.country_code = e.country_code
    where f.indicator_code = 'NGDPD'
      and f.observation_year = 2024
      and e.entity_type = 'COUNTRY'
    group by 1

),

control as (

    select vintage_published_at, observation_value as world_total
    from {{ ref('fct_indicator_observations') }}
    where indicator_code = 'NGDPD'
      and observation_year = 2024
      and country_code = 'G001'

)

select
    c.vintage_published_at,
    c.country_total,
    w.world_total,
    round(abs(c.country_total - w.world_total) / w.world_total * 100, 2) as pct_variance
from countries c
join control w
    on c.vintage_published_at = w.vintage_published_at
where abs(c.country_total - w.world_total) / w.world_total > 0.02
