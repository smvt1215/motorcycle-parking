"""National holidays for the fee and schedule judgments (decision 61, #120).

Source: 政府資料開放平臺「中華民國政府行政機關辦公日曆表」
(https://data.gov.tw/dataset/14718), 行政院人事行政總處, 政府資料開放授權條款第 1 版.
One CSV per ROC year with 西元日期, 星期, 是否放假 (0 上班, 2 放假), 備註.
Most years are UTF-8 with a BOM; some updates (114 年 1141020 更新) are Big5.

    python3 tool/holidays.py fetch 114 115 116   # download into data/holidays/
    python3 tool/holidays.py build               # write the SQL and the app's fallback
    python3 tool/holidays.py build --check       # fail if the outputs are behind

`fetch` reads the dataset's file list from the data.gov.tw API, keeps the
latest file of each year (an 更新 or 修正 file over the original) and saves it
as UTF-8 in data/holidays/<roc>.csv, with its URL and date in sources.json.
`build` writes supabase/holidays/holidays.sql (the rows every holidays
migration upserts) and lib/models/holidays_builtin.g.dart: the current and
the next year the app falls back on when the backend cannot be read.

A year changes mid-year sometimes (114 年 was revised on 2025-10-20), so fetch
again before each release and when the next year is published, then put the
new SQL in a migration.
"""
import argparse
import csv
import datetime as dt
import io
import json
from pathlib import Path
import re
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data/holidays"
SQL = ROOT / "supabase/holidays/holidays.sql"
DART = ROOT / "lib/models/holidays_builtin.g.dart"
DATASET = "https://data.gov.tw/dataset/14718"
API = "https://data.gov.tw/api/v2/rest/dataset/14718"
HEADER = ["西元日期", "星期", "是否放假", "備註"]
WEEKDAYS = "一二三四五六日"


class HolidayError(ValueError):
    pass


def decode(raw):
    """The CSV's text: UTF-8 (with or without BOM), else Big5 (cp950)."""
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("cp950")


def parse(text, roc_year):
    """[(date, is_off, note)] of one year's CSV, every day exactly once."""
    rows = list(csv.reader(io.StringIO(text)))
    if not rows or [c.strip() for c in rows[0]][:4] != HEADER:
        raise HolidayError(f"{roc_year} 年：欄位不是 {'、'.join(HEADER)}")
    year = roc_year + 1911
    out = []
    for n, row in enumerate(rows[1:], start=2):
        if not any(c.strip() for c in row):
            continue
        if len(row) < 3:
            raise HolidayError(f"{roc_year} 年第 {n} 列欄位不足")
        try:
            day = dt.datetime.strptime(row[0].strip(), "%Y%m%d").date()
        except ValueError:
            raise HolidayError(f"{roc_year} 年第 {n} 列日期無法解讀：{row[0]}") from None
        if day.year != year:
            raise HolidayError(f"{roc_year} 年第 {n} 列日期不在 {year} 年：{row[0]}")
        if row[1].strip() != WEEKDAYS[day.weekday()]:
            raise HolidayError(f"{roc_year} 年第 {n} 列星期與日期不符：{row[0]} {row[1]}")
        flag = row[2].strip()
        if flag not in ("0", "2"):
            raise HolidayError(f"{roc_year} 年第 {n} 列是否放假不是 0 或 2：{flag}")
        note = row[3].strip() if len(row) > 3 else ""
        out.append((day, flag == "2", note))
    days = [d for d, _, _ in out]
    expected = (dt.date(year + 1, 1, 1) - dt.date(year, 1, 1)).days
    if len(set(days)) != len(days) or len(days) != expected:
        raise HolidayError(f"{roc_year} 年應有 {expected} 天，讀到 {len(set(days))} 天")
    return sorted(out)


def exceptions(rows):
    """Days that differ from 週六日放假: weekdays off and weekend workdays."""
    off = [d for d, is_off, _ in rows if is_off and d.weekday() < 5]
    work = [d for d, is_off, _ in rows if not is_off and d.weekday() >= 5]
    return off, work


def latest_files(dataset):
    """{roc_year: (url, description)} of the newest file per year, skipping
    the Google Calendar copies."""
    files = {}
    for res in dataset["result"]["distribution"]:
        name = res.get("resourceDescription", "")
        m = re.match(r"(\d{3})年中華民國政府行政機關辦公日曆表(.*)$", name)
        if not m or "Google" in m.group(2):
            continue
        year = int(m.group(1))
        # A later entry (更新, 修正) replaces the original.
        if year not in files or m.group(2):
            files[year] = (res["resourceDownloadUrl"], name)
    return files


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "motorcycle-parking"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def fetch(years, data=DATA, today=None):
    data.mkdir(parents=True, exist_ok=True)
    files = latest_files(json.loads(_get(API)))
    sources_path = data / "sources.json"
    sources = json.loads(sources_path.read_text()) if sources_path.exists() else {}
    for year in years:
        if year not in files:
            raise HolidayError(f"資料集還沒有 {year} 年的日曆表")
        url, name = files[year]
        text = decode(_get(url))
        rows = parse(text, year)
        out = io.StringIO()
        w = csv.writer(out, lineterminator="\n")
        w.writerow(HEADER)
        for d, is_off, note in rows:
            w.writerow([d.strftime("%Y%m%d"), WEEKDAYS[d.weekday()], "2" if is_off else "0", note])
        (data / f"{year}.csv").write_text(out.getvalue(), encoding="utf-8")
        sources[str(year)] = {
            "name": name,
            "url": url,
            "fetched_on": (today or dt.date.today()).isoformat(),
        }
        print(f"{year} 年：{name}，{len(rows)} 天", file=sys.stderr)
    sources_path.write_text(json.dumps(dict(sorted(sources.items())), ensure_ascii=False, indent=2) + "\n")


def load(data=DATA):
    """({roc_year: rows}, sources) from data/holidays."""
    sources = json.loads((data / "sources.json").read_text())
    years = {}
    for path in sorted(data.glob("*.csv")):
        year = int(path.stem)
        if str(year) not in sources:
            raise HolidayError(f"sources.json 沒有 {year} 年的來源")
        years[year] = parse(path.read_text(encoding="utf-8"), year)
    return years, sources


def _q(s):
    return "'" + s.replace("'", "''") + "'"


def sql(years, sources):
    lines = [
        "-- Generated by tool/holidays.py from data/holidays (data.gov.tw 14718);",
        "-- do not edit by hand.",
        "insert into public.holiday_sources (year,name,source_url,fetched_on) values",
        ",\n".join(
            f"  ({y + 1911},{_q(sources[str(y)]['name'])},{_q(sources[str(y)]['url'])},"
            f"'{sources[str(y)]['fetched_on']}')"
            for y in sorted(years)
        ),
        "on conflict (year) do update set name=excluded.name,source_url=excluded.source_url,",
        "  fetched_on=excluded.fetched_on;",
    ]
    for y in sorted(years):
        lines += [
            f"-- {y} 年（{y + 1911}）",
            "insert into public.holidays (date,is_off,note) values",
            ",\n".join(
                f"  ('{d.isoformat()}',{'true' if off else 'false'},{_q(note)})"
                for d, off, note in years[y]
            ),
            "on conflict (date) do update set is_off=excluded.is_off,note=excluded.note;",
        ]
    return "\n".join(lines) + "\n"


def dart(years, sources, builtin):
    def dates(ds):
        # As dart format writes a set literal.
        return "{" + "".join(f"\n    '{d.isoformat()}'," for d in ds) + ("\n  }" if ds else "}")

    off, work = [], []
    for y in builtin:
        if y not in years:
            raise HolidayError(f"內建備援要 {y} 年，但 data/holidays 沒有")
        o, w = exceptions(years[y])
        off += o
        work += w
    years_text = ", ".join(str(y + 1911) for y in builtin)
    return (
        "// Generated by tool/holidays.py from data/holidays (data.gov.tw 14718);\n"
        "// do not edit by hand.\n"
        "part of 'holiday_calendar.dart';\n\n"
        "/// The app's fallback when the backend's holidays cannot be read: the\n"
        "/// current and the next year at release time.\n"
        "final builtinHolidays = HolidayCalendar(\n"
        f"  years: const {{{years_text}}},\n"
        f"  off: const {dates(off)},\n"
        f"  work: const {dates(work)},\n"
        ");\n"
    )


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch", help="download years (ROC) into data/holidays")
    f.add_argument("years", nargs="+", type=int)
    b = sub.add_parser("build", help="write the SQL and the app's fallback")
    b.add_argument("--builtin", nargs="+", type=int,
                   help="ROC years the app ships (default: the latest two)")
    b.add_argument("--check", action="store_true", help="fail if an output is behind")
    args = p.parse_args(argv)
    try:
        if args.cmd == "fetch":
            fetch(args.years)
            return 0
        years, sources = load()
        builtin = args.builtin or sorted(years)[-2:]
        outputs = {SQL: sql(years, sources), DART: dart(years, sources, builtin)}
        stale = [path for path, text in outputs.items()
                 if not path.exists() or path.read_text(encoding="utf-8") != text]
        if args.check:
            for path in stale:
                print(f"{path.relative_to(ROOT)} 未更新，請執行 python3 tool/holidays.py build", file=sys.stderr)
            return 1 if stale else 0
        for path in stale:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(outputs[path], encoding="utf-8")
        return 0
    except HolidayError as e:
        print(e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
