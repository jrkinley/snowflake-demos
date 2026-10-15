{{ config(severity = 'warn') }}

-- A test that is meant to find something.
--
-- Most tests here guard against our own bugs and should always pass. This one
-- flags a real-world condition worth a human look: hyperinflation, defined as
-- consumer prices rising more than 100% in a year, from 2020 onwards. In the
-- October 2026 vintage it catches Argentina, Lebanon, Sudan, Venezuela and
-- Zimbabwe.
--
-- Severity is warn, so the build still succeeds. With store_failures on, the
-- rows it finds land in <ENV>_AUDIT.WARN_HYPERINFLATION_SINCE_2020, where they
-- can be queried, monitored and alerted on like any other table.

select
    country_code,
    country_name,
    observation_year,
    inflation_pct,
    is_projection,
    vintage_label
from {{ ref('country_economic_indicators') }}
where inflation_pct > 100
  and observation_year >= 2020
