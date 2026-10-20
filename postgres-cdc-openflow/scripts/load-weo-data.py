#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["openpyxl>=3.1"]
# ///
"""Turn an IMF World Economic Outlook export into a flat load file for Postgres.

The entire dataset is loaded, countries and aggregates alike. No filtering.

Two export shapes are accepted and detected from the header rather than from the
file extension, because the portal offers both and they are easy to mix up:

  xlsx   the full-database file, currently WEOApr2026all.xlsx. Data lives in
         every sheet carrying a SERIES_CODE column, which is how the
         vintage-named cover sheet gets skipped without hardcoding its name.
  csv    the wide portal export: a SERIES_CODE column plus one column per year.

Output is a headerless CSV of
(country_code, indicator_code, frequency, year, value), ready for \\copy.

Usage:
    load-weo-data.py [--data-dir DIR] [--out FILE] [--quiet]

Exit codes:
    0  wrote the load file
    2  nothing to load, instructions printed
    3  found a file but could not recognise its shape
"""

import argparse
import csv
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Outside the skill directory on purpose. The WEO xlsx is over 5 MB, past the
# 2 MB per-file limit on a Cortex Extension stage, so keeping it inside the skill
# would break publishing the skill to the catalog.
DEFAULT_DATA_DIR = Path.home() / ".cache" / "openflow-weo-demo"
YEAR_RE = re.compile(r"^\d{4}$")

DOWNLOAD_INSTRUCTIONS = """
No World Economic Outlook export found in {data_dir}

Download the current vintage, then run this again.

  1. Open https://data.imf.org/en/datasets/IMF.RES:WEO
  2. Take the full-database file linked from that page. In April 2026 it is
     WEOApr2026all.xlsx, and the filename always carries the vintage.
     The wide CSV from the DOWNLOAD action works too, as long as it has a
     SERIES_CODE column and one column per year.
  3. Save it into {data_dir}

Do not filter to particular countries in the portal. The country filter is not
applied on export, so the file arrives complete either way, and this loads all
of it by design.

WEO is published twice a year, in April and October. The same page links a
release calendar if you need to know what is current.
"""


def year_columns(header):
    """Indices of the year columns, keyed by the year they hold."""
    out = {}
    for i, cell in enumerate(header):
        if isinstance(cell, int) and 1900 < cell < 2200:
            out[i] = cell
        elif isinstance(cell, str) and YEAR_RE.match(cell.strip()):
            out[i] = int(cell.strip())
    return out


def emit(rows_iter, header, country_idx, indicator_idx, frequency_idx, writer, stats):
    """Unpivot one sheet or file into observation rows.

    Observations with no value are skipped rather than written as NULL. The
    published dataset is sparse: roughly a quarter of the cells in the Countries
    sheet are empty, because not every indicator exists for every country and
    year. An observation without a value is not an observation, so the loaded
    table stays one clean fact per row.
    """
    years = year_columns(header)
    if not years:
        return False

    for row in rows_iter:
        country = row[country_idx]
        indicator = row[indicator_idx]
        frequency = row[frequency_idx] if frequency_idx is not None else "Annual"
        if not country or not indicator:
            continue
        country = str(country).strip()
        indicator = str(indicator).strip()
        frequency = str(frequency).strip() or "Annual"
        stats["countries"].add(country)
        stats["indicators"].add(indicator)

        for idx, year in years.items():
            value = row[idx] if idx < len(row) else None
            if value is None:
                stats["skipped"] += 1
                continue
            if isinstance(value, str):
                value = value.strip()
                if not value or value in {"n/a", "N/A", "--", "-"}:
                    stats["skipped"] += 1
                    continue
                try:
                    value = float(value.replace(",", ""))
                except ValueError:
                    stats["unparsed"] += 1
                    continue
            writer.writerow([country, indicator, frequency, year, value])
            stats["written"] += 1
            stats["years"].add(year)
    return True


def load_xlsx(path, writer, stats, log):
    import openpyxl

    workbook = openpyxl.load_workbook(path, read_only=False, data_only=True)
    used = 0
    for name in workbook.sheetnames:
        sheet = workbook[name]
        rows = sheet.iter_rows(values_only=True)
        try:
            header = list(next(rows))
        except StopIteration:
            continue

        # A data sheet is one that carries SERIES_CODE. This skips the
        # vintage-named cover sheet ('April 2026 WEO') and the group-composition
        # lookup without depending on either name, both of which change.
        if "SERIES_CODE" not in header:
            log(f"  skip sheet {name!r}: no SERIES_CODE column")
            continue

        try:
            country_idx = header.index("COUNTRY.ID")
            indicator_idx = header.index("INDICATOR.ID")
        except ValueError:
            log(f"  skip sheet {name!r}: no COUNTRY.ID or INDICATOR.ID column")
            continue
        frequency_idx = header.index("FREQUENCY") if "FREQUENCY" in header else None

        before = stats["written"]
        if emit(rows, header, country_idx, indicator_idx, frequency_idx, writer, stats):
            log(f"  sheet {name!r}: {stats['written'] - before:,} observations")
            used += 1
        else:
            log(f"  skip sheet {name!r}: no year columns")
    return used > 0


def load_csv(path, writer, stats, log):
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.reader(handle)
        try:
            header = next(reader)
        except StopIteration:
            return False

        if "COUNTRY.ID" in header and "INDICATOR.ID" in header:
            country_idx = header.index("COUNTRY.ID")
            indicator_idx = header.index("INDICATOR.ID")
            frequency_idx = header.index("FREQUENCY") if "FREQUENCY" in header else None
        elif "SERIES_CODE" in header:
            # The wide portal export identifies a series only by SERIES_CODE, in
            # the form COUNTRY.INDICATOR.FREQUENCY, so split it.
            series_idx = header.index("SERIES_CODE")
            years = year_columns(header)
            if not years:
                return False
            for row in reader:
                parts = (row[series_idx] or "").split(".")
                if len(parts) < 2:
                    continue
                country, indicator = parts[0].strip(), parts[1].strip()
                frequency = "Annual" if len(parts) < 3 else {"A": "Annual"}.get(
                    parts[2].strip(), parts[2].strip()
                )
                if not country or not indicator:
                    continue
                stats["countries"].add(country)
                stats["indicators"].add(indicator)
                for idx, year in years.items():
                    raw = row[idx] if idx < len(row) else ""
                    raw = (raw or "").strip()
                    if not raw or raw in {"n/a", "N/A", "--", "-"}:
                        stats["skipped"] += 1
                        continue
                    try:
                        value = float(raw.replace(",", ""))
                    except ValueError:
                        stats["unparsed"] += 1
                        continue
                    writer.writerow([country, indicator, frequency, year, value])
                    stats["written"] += 1
                    stats["years"].add(year)
            log(f"  {path.name}: {stats['written']:,} observations")
            return True
        else:
            return False

        ok = emit(reader, header, country_idx, indicator_idx, frequency_idx, writer, stats)
        if ok:
            log(f"  {path.name}: {stats['written']:,} observations")
        return ok


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", default=str(DEFAULT_DATA_DIR))
    parser.add_argument("--out")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    data_dir = Path(args.data_dir).expanduser()
    # Created rather than shipped as an empty folder: publishing a Cortex
    # Extension drops dotfiles at any depth, so a .gitkeep would not survive.
    data_dir.mkdir(parents=True, exist_ok=True)

    def log(message):
        if not args.quiet:
            print(message)

    candidates = sorted(
        path
        for path in data_dir.iterdir()
        if path.is_file()
        and path.suffix.lower() in {".xlsx", ".csv"}
        and not path.name.startswith("~$")
        and path.name != "weo-observations.csv"
    )
    if not candidates:
        print(DOWNLOAD_INSTRUCTIONS.format(data_dir=data_dir), file=sys.stderr)
        return 2

    source = candidates[0]
    if len(candidates) > 1:
        log(f"note: {len(candidates)} exports present, using {source.name}")

    out_path = Path(args.out) if args.out else data_dir / "weo-observations.csv"
    stats = {
        "written": 0,
        "skipped": 0,
        "unparsed": 0,
        "countries": set(),
        "indicators": set(),
        "years": set(),
    }

    log(f"reading {source.name}")
    with out_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        if source.suffix.lower() == ".xlsx":
            recognised = load_xlsx(source, writer, stats, log)
        else:
            recognised = load_csv(source, writer, stats, log)

    if not recognised or stats["written"] == 0:
        out_path.unlink(missing_ok=True)
        print(
            f"error: could not read {source.name}.\n"
            "Expected either the full-database xlsx, which has a SERIES_CODE\n"
            "column plus COUNTRY.ID and INDICATOR.ID on each data sheet, or the\n"
            "wide portal CSV, which has SERIES_CODE plus one column per year.\n"
            "Re-download from https://data.imf.org/en/datasets/IMF.RES:WEO",
            file=sys.stderr,
        )
        return 3

    years = sorted(stats["years"])
    log("")
    log(f"wrote {out_path}")
    log(f"  observations  {stats['written']:,}")
    log(f"  countries     {len(stats['countries']):,}")
    log(f"  indicators    {len(stats['indicators']):,}")
    log(f"  years         {years[0]}-{years[-1]} ({len(years)})")
    log(f"  empty cells   {stats['skipped']:,} skipped")
    if stats["unparsed"]:
        log(f"  unparsed      {stats['unparsed']:,} values were not numeric")
    return 0


if __name__ == "__main__":
    sys.exit(main())
