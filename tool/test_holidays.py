"""tool/holidays.py: the office calendar CSV, its SQL and the app's fallback."""
import datetime as dt
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import holidays as h  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def year_csv(year, off=(), work=(), notes=None, header="西元日期,星期,是否放假,備註"):
    notes = notes or {}
    lines = [header]
    d = dt.date(year, 1, 1)
    while d.year == year:
        weekend = d.weekday() >= 5
        is_off = (weekend and d not in work) or d in off
        lines.append(f"{d:%Y%m%d},{h.WEEKDAYS[d.weekday()]},{2 if is_off else 0},{notes.get(d, '')}")
        d += dt.timedelta(days=1)
    return "\r\n".join(lines) + "\r\n"


class ParseTest(unittest.TestCase):
    def test_utf8_bom_and_big5(self):
        text = year_csv(2026, off={dt.date(2026, 6, 19)}, notes={dt.date(2026, 6, 19): "端午節"})
        for raw in ("﻿" + text).encode("utf-8"), text.encode("cp950"):
            rows = h.parse(h.decode(raw), 115)
            self.assertEqual(len(rows), 365)
            self.assertIn((dt.date(2026, 6, 19), True, "端午節"), rows)

    def test_exceptions_are_weekdays_off_and_weekend_workdays(self):
        rows = h.parse(year_csv(2025, off={dt.date(2025, 1, 1)}, work={dt.date(2025, 2, 8)}), 114)
        self.assertEqual(h.exceptions(rows), ([dt.date(2025, 1, 1)], [dt.date(2025, 2, 8)]))

    def test_refuses_bad_files(self):
        good = year_csv(2026)
        cases = {
            "header": good.replace("是否放假", "放假"),
            "flag": good.replace("20260102,五,0", "20260102,五,1"),
            "weekday": good.replace("20260102,五", "20260102,六"),
            "missing day": good.replace("20260102,五,0,\r\n", ""),
            "wrong year": good.replace("20260102,五", "20250102,五"),
            "date": good.replace("20260102", "2026-01-02"),
        }
        for name, text in cases.items():
            with self.subTest(name), self.assertRaises(h.HolidayError):
                h.parse(text, 115)

    def test_leap_year_has_366_days(self):
        self.assertEqual(len(h.parse(year_csv(2028), 117)), 366)


class FilesTest(unittest.TestCase):
    def test_latest_file_per_year_skips_google_copies(self):
        def res(name, url):
            return {"resourceDescription": name, "resourceDownloadUrl": url}
        dataset = {"result": {"distribution": [
            res("114年中華民國政府行政機關辦公日曆表", "https://a/114"),
            res("114年中華民國政府行政機關辦公日曆表_Google行事曆專用", "https://a/g"),
            res("114年中華民國政府行政機關辦公日曆表(1141020更新)", "https://a/114u"),
            res("115年中華民國政府行政機關辦公日曆表", "https://a/115"),
        ]}}
        self.assertEqual(h.latest_files(dataset), {
            114: ("https://a/114u", "114年中華民國政府行政機關辦公日曆表(1141020更新)"),
            115: ("https://a/115", "115年中華民國政府行政機關辦公日曆表"),
        })

    def test_fetch_writes_utf8_and_sources(self):
        dataset = {"result": {"distribution": [
            {"resourceDescription": "114年中華民國政府行政機關辦公日曆表(1141020更新)",
             "resourceDownloadUrl": "https://example.test/114.csv"},
        ]}}
        big5 = year_csv(2025, notes={dt.date(2025, 1, 4): "週六"}).encode("cp950")

        def get(url):
            return json.dumps(dataset).encode() if url == h.API else big5

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(h, "_get", get), \
                mock.patch("sys.stderr", io.StringIO()):
            data = Path(tmp)
            h.fetch([114], data=data, today=dt.date(2026, 10, 27))
            self.assertTrue((data / "114.csv").read_text(encoding="utf-8").startswith("西元日期"))
            sources = json.loads((data / "sources.json").read_text())
            self.assertEqual(sources["114"]["url"], "https://example.test/114.csv")
            self.assertEqual(sources["114"]["fetched_on"], "2026-10-27")
            years, _ = h.load(data)
            self.assertEqual(len(years[114]), 365)
            with self.assertRaises(h.HolidayError):
                h.fetch([116], data=data)


class OutputTest(unittest.TestCase):
    def test_outputs_are_current(self):
        """data/holidays, the SQL and the app's fallback agree."""
        self.assertEqual(h.main(["build", "--check"]), 0)

    def test_a_migration_carries_the_sql(self):
        sql = h.SQL.read_text(encoding="utf-8")
        migrations = [p.read_text(encoding="utf-8") for p in (ROOT / "supabase/migrations").glob("*.sql")]
        self.assertTrue(any(sql in m for m in migrations))

    def test_sql_quotes_notes(self):
        rows = {115: h.parse(year_csv(2026, notes={dt.date(2026, 1, 3): "O'Neil"}), 115)}
        sources = {"115": {"name": "x", "url": "https://x", "fetched_on": "2026-10-27"}}
        sql = h.sql(rows, sources)
        self.assertIn("('2026-01-03',true,'O''Neil')", sql)
        self.assertIn("(2026,'x','https://x','2026-10-27')", sql)

    def test_dart_lists_only_exceptions_of_the_builtin_years(self):
        rows = {
            114: h.parse(year_csv(2025, work={dt.date(2025, 2, 8)}), 114),
            115: h.parse(year_csv(2026, off={dt.date(2026, 6, 19)}), 115),
        }
        out = h.dart(rows, {}, [115])
        self.assertIn("years: const {2026}", out)
        self.assertIn("'2026-06-19',", out)
        self.assertIn("work: const {}", out)
        self.assertNotIn("2025-02-08", out)
        with self.assertRaises(h.HolidayError):
            h.dart(rows, {}, [116])


if __name__ == "__main__":
    unittest.main()
