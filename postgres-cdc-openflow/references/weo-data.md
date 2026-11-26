# The WEO data

The source is the IMF World Economic Outlook: public, no key, about 360,000 observations, with a
natural composite key the CDC connector can merge on. It is published twice a year, in April
and October.

## Where it comes from

The IMF SDMX 3.0 API returns the whole vintage as one CSV, about 32 MB, in seconds:

```
GET https://api.imf.org/external/sdmx/3.0/data/dataflow/IMF.RES/WEO/+/*
    ?attributes=SCALE,UNIT,PUBLICATION_DATE,LATEST_ACTUAL_ANNUAL_DATA
Accept: application/vnd.sdmx.data+csv;version=2.0.0
```

Part 1 step 6 downloads it with `curl` to `~/.cache/openflow-weo-demo/weo.csv`, outside the skill,
so the skill stays small enough to publish.

Two API traps, both silent: `startPeriod`/`endPeriod` are ignored, and
`dimensionAtObservation=AllDimensions` returns zero rows for multi-series queries. Hence the
whole-vintage CSV.

## Shape

CSV header, in order: `STRUCTURE, STRUCTURE_ID, ACTION, COUNTRY, INDICATOR, FREQUENCY,
TIME_PERIOD, OBS_VALUE, SCALE, UNIT, PUBLICATION_DATE, LATEST_ACTUAL_ANNUAL_DATA`.
`assets/pg-schema.sql` lands it verbatim as text in `weo.observations_raw`.

`assets/pg-load.sql` then builds `weo.observations`:

| Column | From | Note |
|---|---|---|
| `country_code` | `COUNTRY` | ISO3, plus 4-character aggregates such as `G001` (World) |
| `indicator_code` | `INDICATOR` | e.g. `NGDPD`, GDP in current US dollars |
| `frequency` | `FREQUENCY` | `A` mapped to `Annual` |
| `year` | `TIME_PERIOD` | 1980 to five years ahead; the later years are projections |
| `value` | `OBS_VALUE / 10^SCALE` | SDMX values are full units; `SCALE` 9 means billions |

The primary key is `(country_code, indicator_code, frequency, year)`.

## Vintages

Every vintage changes the counts and most values, including the demo row (GBR, NGDPD, 2026:
4264.794 in April 2026, 4268.446 in October 2026). That is why nothing in the skill hard-codes a
figure: Part 1 reports what loaded, and Part 2 reads the original value live before changing it.

Oct 2026 vintage: 361,508 observations, 210 countries and aggregates, 145 indicators.
