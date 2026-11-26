-- Transform the raw IMF SDMX rows into weo.observations and publish the table for CDC.
-- Run as snowflake_admin with psql -f, after \copy has filled weo.observations_raw.
--
-- SDMX OBS_VALUE is in full units and SCALE is a display exponent (9 = billions).
-- Dividing by 10^SCALE gives the figures people recognise, e.g. UK 2026 GDP in billions of US dollars.

INSERT INTO weo.observations (country_code, indicator_code, frequency, year, value)
SELECT country,
       indicator,
       CASE frequency WHEN 'A' THEN 'Annual' ELSE frequency END,
       time_period::SMALLINT,
       ROUND(obs_value::NUMERIC / POWER(10::NUMERIC, COALESCE(NULLIF(scale, '')::INT, 0)), 6)
FROM weo.observations_raw
WHERE obs_value ~ '^-?[0-9.eE+-]+$'
  AND time_period ~ '^[0-9]{4}$'
ON CONFLICT DO NOTHING;

DROP TABLE weo.observations_raw;
ANALYZE weo.observations;

DROP PUBLICATION IF EXISTS openflow;
CREATE PUBLICATION openflow FOR TABLE weo.observations;

SELECT count(*) AS rows_loaded,
       count(DISTINCT country_code) AS countries,
       count(DISTINCT indicator_code) AS indicators
FROM weo.observations;
