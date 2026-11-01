"""Unit tests for tool/raise_min_app_version.py (no network)."""
import contextlib
import io
import json
import unittest
from unittest import mock
import urllib.error

import raise_min_app_version as raiser


class _Response(io.BytesIO):
    def __init__(self, status, raw):
        super().__init__(raw)
        self.status = status


def answering(routes):
    """A fake urlopen: routes maps a URL prefix to (status, body)."""
    seen = []

    def opener(request, timeout):
        seen.append(request)
        for prefix, (status, body) in routes.items():
            if request.full_url.startswith(prefix):
                raw = json.dumps(body).encode()
                if status >= 400:
                    raise urllib.error.HTTPError(request.full_url, status, "x", {}, io.BytesIO(raw))
                return _Response(status, raw)
        raise AssertionError(f"unexpected call {request.full_url}")

    opener.seen = seen
    return opener


ENV = {"SUPABASE_URL": "https://p.supabase.co", "SUPABASE_SERVICE_KEY": "service",
       "RUN_URL": "https://github.com/x/actions/runs/9"}
RPC = "https://p.supabase.co/rest/v1/rpc/set_min_supported_app_version"


class RaiseMinAppVersionTest(unittest.TestCase):
    def run_main(self, opener, argv=(), mark="1.2.0"):
        with mock.patch.dict("os.environ", ENV, clear=True), \
                mock.patch.object(raiser, "compat_version", return_value=mark), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            code = raiser.main(list(argv), opener)
        return code, out.getvalue()

    def test_raises_through_the_audited_function_as_cd(self):
        opener = answering({RPC: (200, {"min_supported_app_version": "1.2.0", "changed": True})})
        code, out = self.run_main(opener)
        self.assertEqual(code, 0)
        self.assertIn("raised to 1.2.0", out)
        request = opener.seen[0]
        self.assertEqual(request.get_header("Content-profile"), "admin_v1")
        self.assertEqual(request.get_header("Authorization"), "Bearer service")
        self.assertEqual(json.loads(request.data),
                         {"p_version": "1.2.0", "p_reason": "https://github.com/x/actions/runs/9"})

    def test_an_unchanged_mark_is_reported_not_failed(self):
        opener = answering({RPC: (200, {"min_supported_app_version": "1.3.0", "changed": False})})
        code, out = self.run_main(opener)
        self.assertEqual(code, 0)
        self.assertIn("unchanged at 1.3.0", out)

    def test_a_refusal_fails_the_step(self):
        opener = answering({RPC: (403, {"code": "PT403", "message": "auth.aal2_required"})})
        code, out = self.run_main(opener)
        self.assertEqual(code, 1)
        self.assertIn("answered 403", out)

    def test_production_waits_for_the_app_store(self):
        store = raiser.APP_STORE_LOOKUP
        for listed, expected in (("1.1.0", 1), ("1.2.0", 0), ("1.10.0", 0)):
            with self.subTest(listed=listed):
                opener = answering({
                    store: (200, {"results": [{"version": listed}]}),
                    RPC: (200, {"min_supported_app_version": "1.2.0", "changed": True}),
                })
                code, out = self.run_main(opener, ["--require-app-store", "tw.x"])
                self.assertEqual(code, expected, out)
                if expected:
                    self.assertEqual(len(opener.seen), 1, "nothing is written before the store has it")
        opener = answering({store: (200, {"resultCount": 0, "results": []})})
        code, _ = self.run_main(opener, ["--require-app-store", "tw.x"])
        self.assertEqual(code, 1)

    def play_run(self, track, env_extra=None, code=7):
        play = raiser.PLAY_API + "tw.x/edits"
        routes = {
            f"{play}/e1/tracks/production": (200, track),
            f"{play}/e1": (204, None),
            play: (200, {"id": "e1"}),
            RPC: (200, {"min_supported_app_version": "1.2.0", "changed": True}),
        }
        opener = answering(routes)
        env = {**ENV, **(env_extra or {})}
        with mock.patch.dict("os.environ", env, clear=True), \
                mock.patch.object(raiser, "compat_version", return_value="1.2.0"), \
                mock.patch.object(raiser, "release_version_code", return_value=code), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            result = raiser.main(["--require-play", "tw.x"], opener, token=lambda _: "tok")
        return result, out.getvalue(), opener

    def test_play_is_checked_through_a_discarded_edit(self):
        sa = {"GOOGLE_PLAY_SERVICE_ACCOUNT_JSON": "{}"}
        code, out, opener = self.play_run(
            {"releases": [{"versionCodes": ["7"], "status": "completed"}]}, sa)
        self.assertEqual(code, 0, out)
        self.assertIn("checked by the Play Developer API", out)
        methods = [(r.get_method(), r.full_url.rsplit("/", 1)[-1]) for r in opener.seen]
        self.assertIn(("DELETE", "e1"), methods, "the edit is deleted, never committed")
        self.assertNotIn("e1:commit", [r.full_url.rsplit("/", 1)[-1] for r in opener.seen])

    def test_play_waits_for_a_full_rollout(self):
        sa = {"GOOGLE_PLAY_SERVICE_ACCOUNT_JSON": "{}"}
        for release, expected, text in (
            ({"versionCodes": [7], "status": "inProgress", "userFraction": 1}, 0, "inProgress"),
            ({"versionCodes": [7], "status": "inProgress", "userFraction": 0.2}, 1, "rollout at 20%"),
            ({"versionCodes": [7], "status": "halted"}, 1, "production halted"),
            ({"versionCodes": [6], "status": "completed"}, 1, "not on the production track"),
        ):
            with self.subTest(release=release):
                code, out, opener = self.play_run({"releases": [release]}, sa)
                self.assertEqual(code, expected, out)
                self.assertIn(text, out)
                if expected:
                    self.assertNotIn(RPC, [r.full_url for r in opener.seen],
                                     "nothing is written before Play has it")

    def test_without_a_service_account_the_approver_confirms(self):
        code, out, _ = self.play_run({}, {"PLAY_CONFIRMED": "true"})
        self.assertEqual(code, 0, out)
        self.assertIn("confirmed by the approver", out)
        code, out, _ = self.play_run({})
        self.assertEqual(code, 1)
        self.assertIn("Google Play is unchecked", out)

    def test_the_published_android_build_comes_from_the_release(self):
        self.assertEqual(raiser.android_build(
            ["sha256-android-4321.txt", "sha256-ios-4321.txt", "app.aab"]), 4321)
        self.assertIsNone(raiser.android_build(["sha256-ios-9.txt"]), "no Android build")
        self.assertIsNone(raiser.android_build(
            ["sha256-android-1.txt", "sha256-android-2.txt"]), "ambiguous builds are refused")

    def test_missing_settings_exit_2(self):
        with mock.patch.dict("os.environ", {}, clear=True), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(raiser.main([], answering({})), 2)


if __name__ == "__main__":
    unittest.main()
