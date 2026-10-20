# The WEO data

The demo needs a source dataset with enough rows to look real and a natural key the
CDC connector can merge on. The IMF World Economic Outlook gives both, it is public,
and it is published on a known cadence, so the demo can be refreshed rather than
going stale.

Nothing is committed. The export is 5.3 MB, reproducible in a minute, and specific to
one vintage, so it lives in `~/.cache/openflow-weo-demo/` and the loader tells you how to fill it.

## Getting the file

Open [the WEO dataset page](https://data.imf.org/en/datasets/IMF.RES:WEO) and take the
full-database file linked from it. In April 2026 that is `WEOApr2026all.xlsx`, and the
filename always carries the vintage. Save it into `~/.cache/openflow-weo-demo/`.

The wide CSV from the page's `DOWNLOAD` action also works, provided it has a
`SERIES_CODE` column and one column per year.

Do not filter to particular countries in the portal. The country filter is not applied
on export, so the file arrives complete either way, and the loader wants all of it.

WEO publishes twice a year, April and October. The same page links a release calendar.

## Running the loader

```bash
./scripts/load-weo-data.py
```

It writes `~/.cache/openflow-weo-demo/weo-observations.csv`, a headerless file of
`country_code, indicator_code, frequency, year, value` ready for `\copy`. Exit 2 means
nothing to load and it has printed the download steps; exit 3 means it found a file but
could not recognise its shape, and it prints what it expected.

Against the April 2026 file, expect roughly this:

```
observations  361,733
countries     210
indicators    145
years         1980-2031 (52)
empty cells   128,731 skipped
```

## What the file actually looks like

Verified against `WEOApr2026all.xlsx`, because several of these differ from what you
would reasonably assume.

**The data is not on the first sheet.** Sheet one is a vintage-named cover sheet,
`April 2026 WEO`. The observations live in `Countries` (8,668 series),
`Country Groups` (764) and `Commodity Prices` (75). The loader picks sheets by testing
for a `SERIES_CODE` column, which skips the cover sheet and the group-composition
lookup without depending on either name. Both names change between vintages.

**81 columns: 29 of metadata, then 52 years.** Years run 1980 to 2031, the last five
being projections. `COUNTRY.ID` and `INDICATOR.ID` give the codes directly, so there is
no need to split `SERIES_CODE`.

**Missing values are empty strings, not `n/a`.** Around a quarter of the value cells in
`Countries` are empty, because not every indicator exists for every country and year.
The loader skips them rather than writing NULL, which keeps the loaded table to one
clean fact per row and lets `value` stay `NOT NULL`.

**`SCALE` is a label, not a multiplier.** It reads `Billions` or `Units`, and the values
are already expressed in it: UK GDP in US dollars comes through as `4264.794`, meaning
billions. So nothing is rescaled on load. The SDMX API is different here, returning
values in units with a `SCALE=9` attribute, which is one reason this uses the published
file instead.

**`FREQUENCY` is the word `Annual`**, not the letter `A`. The wide CSV encodes it as `A`
inside `SERIES_CODE`, so the loader normalises that to `Annual` and both sources agree.

## Two things that drove schema decisions

`country_code` is `VARCHAR(16)` rather than `CHAR(3)` because aggregates and commodity
series use four-character codes such as `G001` for World. A three-character column
rejects roughly 21,000 observations, and the failure arrives as a load error rather than
anything explanatory.

`frequency` is `VARCHAR(16)` for the same reason: `Annual` does not fit `CHAR(1)`.

The primary key `(country_code, indicator_code, frequency, year)` is unique across all
three sheets, verified on the April 2026 file. That matters because it is what the
connector merges on, so a collision would surface as a `\copy` failure at load time.

## Refreshing to a new vintage

Drop the new file in `~/.cache/openflow-weo-demo/`, delete the old one and the generated
`weo-observations.csv`, and re-run. Nothing else changes: the loader discovers years and
sheets rather than assuming them.

One caution. The demo's change step uses UK 2026 GDP, which is a projection and moves
between vintages. It happened to be unchanged at `4264.794` in April 2026, matching an
earlier build, but the skill reads the current value at provision time rather
than carrying it as a constant, so a revision cannot leave the narration quoting a
figure that is not in the database.
