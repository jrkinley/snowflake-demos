-- Postgres source schema for the Openflow CDC demo. Run as snowflake_admin with psql -f.
-- Idempotent: drops and recreates the demo table and the raw landing table. pg-load.sql
-- recreates the publication, so always run the two together.

CREATE SCHEMA IF NOT EXISTS weo;

-- Landing table for the IMF SDMX CSV, loaded with \copy. Column order matches the CSV header.
DROP TABLE IF EXISTS weo.observations_raw;
CREATE UNLOGGED TABLE weo.observations_raw (
    structure                  TEXT,
    structure_id               TEXT,
    action                     TEXT,
    country                    TEXT,
    indicator                  TEXT,
    frequency                  TEXT,
    time_period                TEXT,
    obs_value                  TEXT,
    scale                      TEXT,
    unit                       TEXT,
    publication_date           TEXT,
    latest_actual_annual_data  TEXT
);

-- The table Openflow replicates. Composite primary key, so updates are keyed CDC events.
DROP TABLE IF EXISTS weo.observations;
CREATE TABLE weo.observations (
    country_code    VARCHAR(16)     NOT NULL,
    indicator_code  VARCHAR(64)     NOT NULL,
    frequency       VARCHAR(16)     NOT NULL,
    year            SMALLINT        NOT NULL,
    value           NUMERIC(24, 6)  NOT NULL,
    PRIMARY KEY (country_code, indicator_code, frequency, year)
);
ALTER TABLE weo.observations REPLICA IDENTITY DEFAULT;
