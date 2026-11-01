"""Unit tests for tool/check_exposed_schemas.py (no network)."""
import contextlib
import io
import json
import unittest
from unittest import mock
import urllib.error

import check_exposed_schemas as check


def answering(by_schema):
    """A fake urlopen answering (status, body) per Accept-Profile."""
    seen = []

    def opener(request, timeout):
        schema = request.get_header("Accept-profile")
        seen.append((request.full_url, schema, request.get_header("Apikey")))
        status, body = by_schema[schema]
        raw = body if isinstance(body, bytes) else json.dumps(body).encode()
        if status >= 400:
            raise urllib.error.HTTPError(request.full_url, status, "x", {}, io.BytesIO(raw))
        return _Response(status, raw)

    opener.seen = seen
    return opener


class _Response(io.BytesIO):
    def __init__(self, status, raw):
        super().__init__(raw)
        self.status = status


EXPOSED = (404, {"code": "PGRST205", "message": "Could not find the table"})
HIDDEN = (406, {"code": "PGRST106", "message": "Invalid schema: admin_v1",
                "hint": "Only the following schemas are exposed: public, api_v1"})


class CheckExposedSchemasTest(unittest.TestCase):
    def run_check(self, opener):
        with contextlib.redirect_stdout(io.StringIO()):
            return check.check("https://p.supabase.co/", "anon", opener)

    def test_missing_table_in_every_schema_passes(self):
        opener = answering({"api_v1": EXPOSED, "admin_v1": EXPOSED})
        self.assertEqual(self.run_check(opener), [])
        self.assertEqual(opener.seen, [
            ("https://p.supabase.co/rest/v1/__deploy_probe__?select=1", "api_v1", "anon"),
            ("https://p.supabase.co/rest/v1/__deploy_probe__?select=1", "admin_v1", "anon"),
        ])

    def test_unexposed_schema_fails_with_the_dashboard_fix(self):
        problems = self.run_check(answering({"api_v1": EXPOSED, "admin_v1": HIDDEN}))
        self.assertEqual(len(problems), 2)
        self.assertIn("admin_v1: not exposed (Only the following schemas", problems[0])
        self.assertIn("Exposed schemas: add admin_v1,", problems[1])

    def test_any_other_answer_fails(self):
        for answer in ((401, {"message": "Secret API key required"}),
                       (200, []),
                       (502, b"<html>Bad Gateway</html>")):
            with self.subTest(answer=answer):
                problems = self.run_check(answering({"api_v1": answer, "admin_v1": EXPOSED}))
                self.assertEqual(len(problems), 1)
                self.assertIn(f"api_v1: unexpected answer {answer[0]}", problems[0])

    def test_missing_settings_exit_2(self):
        with mock.patch.dict("os.environ", {}, clear=True), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(check.main(), 2)


if __name__ == "__main__":
    unittest.main()
