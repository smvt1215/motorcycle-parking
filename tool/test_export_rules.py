import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from export_rules import RULES, RuleError, dumps, export, main


def as_rows(rules):
    """The bundled rules as the database returns them: every column set."""
    return [{"district_space_types": {}, "restriction": None, **r} for r in rules]


class ExportRulesTest(unittest.TestCase):
    def setUp(self):
        self.text = RULES.read_text()
        self.bundled = json.loads(self.text)

    def test_round_trip_reproduces_the_bundled_file(self):
        # The file was seeded into the database, so exporting it back must not
        # change a byte; any drift in key order or defaults would show here.
        rows = list(reversed(as_rows(self.bundled)))
        self.assertEqual(dumps(export(rows, self.bundled)), self.text)

    def test_a_published_version_replaces_its_row_in_place(self):
        rows = as_rows(self.bundled)
        taipei = next(r for r in rows if r["city"] == "臺北市" and r["vehicle"] == "heavy")
        taipei.update(version=2, conditional_space_types=["offStreet", "freeMotorcycle"], restriction="signage")
        result = export(rows, self.bundled)
        index = next(i for i, r in enumerate(self.bundled) if r["city"] == "臺北市" and r["vehicle"] == "heavy")
        self.assertEqual(result[index]["version"], 2)
        self.assertEqual(result[index]["restriction"], "signage")
        self.assertEqual(list(result[index])[-1], "restriction")
        self.assertEqual(len(result), len(self.bundled))

    def test_new_rules_follow_in_city_order(self):
        new = [{**as_rows(self.bundled)[0], "city": city, "vehicle": vehicle}
               for city, vehicle in [("連江縣", "scooter"), ("基隆市", "heavy"), ("基隆市", "scooter")]]
        result = export(as_rows(self.bundled) + new, self.bundled)
        self.assertEqual([(r["city"], r["vehicle"]) for r in result[-3:]],
                         [("基隆市", "scooter"), ("基隆市", "heavy"), ("連江縣", "scooter")])

    def test_empty_defaults_stay_out_of_the_file(self):
        row = {**as_rows(self.bundled)[0], "effective_date": "2026-10-11T00:00:00"}
        rule = export([row], [])[0]
        self.assertNotIn("district_space_types", rule)
        self.assertNotIn("restriction", rule)
        self.assertNotIn("expires_on", rule)
        self.assertEqual(rule["effective_date"], "2026-10-11")

    def test_an_end_date_is_kept(self):
        row = {**as_rows(self.bundled)[0], "expires_on": "2026-12-31"}
        self.assertEqual(export([row], [])[0]["expires_on"], "2026-12-31")

    def test_a_rule_missing_from_the_database_stops_the_export(self):
        with self.assertRaisesRegex(RuleError, "not in the database"):
            export(as_rows(self.bundled)[1:], self.bundled)

    def test_an_older_database_version_stops_the_export(self):
        rows = as_rows(self.bundled)
        rows[0]["version"] = 1
        bundled = [dict(self.bundled[0], version=3), *self.bundled[1:]]
        with self.assertRaisesRegex(RuleError, "version 3 in the app file"):
            export(rows, bundled)

    def test_kinds_older_builds_cannot_read_are_refused(self):
        rows = as_rows(self.bundled)
        rows[0]["allowed_space_types"] = ["evMotorcycle"]
        with self.assertRaisesRegex(RuleError, "evMotorcycle"):
            export(rows, self.bundled)

    def test_check_reports_a_stale_file_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            output, rows = Path(directory, "rules.json"), Path(directory, "rows.json")
            output.write_text(self.text)
            changed = as_rows(self.bundled)
            changed[0]["version"] = 2
            rows.write_text(json.dumps(changed))
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main(["--input", str(rows), "--output", str(output), "--check"]), 1)
            self.assertEqual(output.read_text(), self.text)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(["--input", str(rows), "--output", str(output)]), 0)
            self.assertEqual(json.loads(output.read_text())[0]["version"], 2)
            self.assertEqual(main(["--input", str(rows), "--output", str(output), "--check"]), 0)


if __name__ == "__main__":
    unittest.main()
