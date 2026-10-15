-- A singular test: any SQL that returns rows is a failure.
--
-- This is the grain assertion for the fact table. dbt_utils has a generic version
-- of this (unique_combination_of_columns), but writing it by hand avoids pulling a
-- package in, and singular tests are where most real-world business assertions end
-- up anyway.
--
-- If the merge key is ever wrong, this is the test that catches it.

select
    country_code,
    indicator_code,
    observation_year,
    vintage_published_at,
    count(*) as row_count

from {{ ref('fct_indicator_observations') }}

group by 1, 2, 3, 4
having count(*) > 1
