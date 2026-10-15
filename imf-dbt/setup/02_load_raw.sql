-- Loads the latest IMF World Economic Outlook vintage into RAW.
--
-- Run as IMF_DBT_ROLE after 01_admin.sql. Pulls three things from the public
-- IMF SDMX 3.0 API (no API key needed):
--
--   IMF_WEO_OBSERVATIONS  every indicator x country x year in the vintage,
--                         about 360,000 rows and 32 MB
--   IMF_WEO_INDICATORS    the CL_WEO_INDICATOR codelist: names and definitions
--   IMF_WEO_COUNTRIES     the CL_WEO_COUNTRY codelist: country and aggregate names
--
-- Observations are kept per vintage. Re-running for a vintage already held
-- replaces it, so the call is idempotent, but a new vintage is appended and the
-- previous one stays. That history is what the dbt snapshot and the
-- vintage-aware fact table are built on.
--
-- Two API traps this avoids, both of which fail silently:
--   * dimensionAtObservation=AllDimensions returns zero rows for multi-series
--     queries, so we use SDMX-CSV instead
--   * startPeriod and endPeriod are ignored, so we fetch the whole vintage

USE ROLE IMF_DBT_ROLE;

CREATE TABLE IF NOT EXISTS IMF_DBT_DB.RAW.IMF_WEO_OBSERVATIONS (
    country_code                varchar,
    indicator_code              varchar,
    frequency                   varchar,
    time_period                 varchar,
    obs_value                   float,
    scale                       integer,
    unit                        varchar,
    latest_actual_annual_data   varchar,
    publication_date            timestamp_ntz,
    ingestion_timestamp         timestamp_ntz
)
COMMENT = 'IMF WEO observations as published, one row per country, indicator, year and vintage';

CREATE TABLE IF NOT EXISTS IMF_DBT_DB.RAW.IMF_WEO_INDICATORS (
    indicator_code              varchar,
    indicator_name              varchar,
    indicator_description       varchar,
    codelist_version            varchar,
    ingestion_timestamp         timestamp_ntz
)
COMMENT = 'IMF CL_WEO_INDICATOR codelist';

CREATE TABLE IF NOT EXISTS IMF_DBT_DB.RAW.IMF_WEO_COUNTRIES (
    country_code                varchar,
    country_name                varchar,
    codelist_version            varchar,
    ingestion_timestamp         timestamp_ntz
)
COMMENT = 'IMF CL_WEO_COUNTRY codelist: countries and IMF aggregates';

CREATE OR REPLACE PROCEDURE IMF_DBT_DB.DBT_PROJECTS.LOAD_IMF_WEO()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('snowflake-snowpark-python', 'requests', 'pandas')
EXTERNAL_ACCESS_INTEGRATIONS = (IMF_DBT_API_ACCESS)
HANDLER = 'main'
COMMENT = 'Loads the latest IMF WEO vintage and codelists into IMF_DBT_DB.RAW'
EXECUTE AS OWNER
AS
$$
import io
from datetime import datetime, timezone

import pandas as pd
import requests
from snowflake.snowpark import Session

BASE = "https://api.imf.org/external/sdmx/3.0"
RAW = "IMF_DBT_DB.RAW"
CSV = {"Accept": "application/vnd.sdmx.data+csv;version=2.0.0"}
ATTRS = "SCALE,UNIT,PUBLICATION_DATE,LATEST_ACTUAL_ANNUAL_DATA"


def fetch_codelist(codelist_id: str) -> tuple[str, list[dict]]:
    r = requests.get(f"{BASE}/structure/codelist/IMF.RES/{codelist_id}/+", timeout=120)
    r.raise_for_status()
    cl = r.json()["data"]["codelists"][0]
    return cl["version"], cl["codes"]


def replace_table(session: Session, table: str, df: pd.DataFrame, where: str = None) -> None:
    session.sql(f"delete from {RAW}.{table}" + (f" where {where}" if where else "")).collect()
    session.write_pandas(df, table, database="IMF_DBT_DB", schema="RAW",
                         quote_identifiers=False, auto_create_table=False,
                         use_logical_type=True)


def main(session: Session) -> str:
    loaded_at = datetime.now(timezone.utc).replace(tzinfo=None)

    r = requests.get(f"{BASE}/data/dataflow/IMF.RES/WEO/+/*",
                     params={"attributes": ATTRS}, headers=CSV, timeout=600)
    r.raise_for_status()
    obs = pd.read_csv(io.StringIO(r.text), dtype=str, keep_default_na=False)

    obs = pd.DataFrame({
        "COUNTRY_CODE": obs["COUNTRY"],
        "INDICATOR_CODE": obs["INDICATOR"],
        "FREQUENCY": obs["FREQUENCY"],
        "TIME_PERIOD": obs["TIME_PERIOD"],
        "OBS_VALUE": pd.to_numeric(obs["OBS_VALUE"], errors="coerce"),
        "SCALE": pd.to_numeric(obs["SCALE"], errors="coerce").astype("Int64"),
        "UNIT": obs["UNIT"].replace("", None),
        "LATEST_ACTUAL_ANNUAL_DATA": obs["LATEST_ACTUAL_ANNUAL_DATA"].replace("", None),
        "PUBLICATION_DATE": pd.to_datetime(obs["PUBLICATION_DATE"].replace("", None), utc=True)
                              .dt.tz_localize(None),
        "INGESTION_TIMESTAMP": loaded_at,
    })

    # A handful of rows arrive without a publication date. They belong to the
    # same release, so give them the vintage the rest of the file carries.
    vintage = obs["PUBLICATION_DATE"].dropna().mode()
    if vintage.empty:
        raise ValueError("No PUBLICATION_DATE in the WEO response, cannot identify the vintage")
    vintage = vintage.iloc[0]
    obs["PUBLICATION_DATE"] = obs["PUBLICATION_DATE"].fillna(vintage)

    replace_table(session, "IMF_WEO_OBSERVATIONS", obs,
                  f"publication_date = '{vintage:%Y-%m-%d %H:%M:%S}'::timestamp_ntz")

    ind_version, ind_codes = fetch_codelist("CL_WEO_INDICATOR")
    replace_table(session, "IMF_WEO_INDICATORS", pd.DataFrame([{
        "INDICATOR_CODE": c["id"],
        "INDICATOR_NAME": c.get("name"),
        "INDICATOR_DESCRIPTION": c.get("description"),
        "CODELIST_VERSION": ind_version,
        "INGESTION_TIMESTAMP": loaded_at,
    } for c in ind_codes]))

    cty_version, cty_codes = fetch_codelist("CL_WEO_COUNTRY")
    replace_table(session, "IMF_WEO_COUNTRIES", pd.DataFrame([{
        "COUNTRY_CODE": c["id"],
        "COUNTRY_NAME": c.get("name"),
        "CODELIST_VERSION": cty_version,
        "INGESTION_TIMESTAMP": loaded_at,
    } for c in cty_codes]))

    return (f"Loaded WEO vintage {vintage:%Y-%m-%d}: {len(obs)} observations, "
            f"{len(ind_codes)} indicators, {len(cty_codes)} countries and aggregates")
$$;

CALL IMF_DBT_DB.DBT_PROJECTS.LOAD_IMF_WEO();
