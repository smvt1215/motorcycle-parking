"""Cleanup must never remove deployment evidence, running work or release history."""
from datetime import datetime, timezone
import unittest

from actions_cleanup import stale_caches, stale_runs

NOW = datetime(2026, 10, 21, tzinfo=timezone.utc)
HEAD = "a" * 40


def run(name="CI", sha="b" * 40, created="2026-10-01T00:00:00Z", status="completed"):
    return {"id": 1, "name": name, "head_sha": sha, "created_at": created, "status": status}


class StaleRunsTest(unittest.TestCase):
    def test_old_completed_runs_are_stale(self):
        self.assertEqual(len(stale_runs([run(), run(name="CD staging")], HEAD, NOW, 7)), 2)

    def test_recent_runs_are_kept(self):
        self.assertEqual(stale_runs([run(created="2026-10-18T00:00:00Z")], HEAD, NOW, 7), [])

    def test_latest_main_commit_is_kept_however_old(self):
        # cd_gate.py reads CI and staging deployment runs for this SHA.
        self.assertEqual(stale_runs([run(sha=HEAD), run(name="CD staging", sha=HEAD)], HEAD, NOW, 7), [])

    def test_running_and_release_runs_are_kept(self):
        self.assertEqual(stale_runs([run(status="in_progress"), run(status="queued"), run(name="Release")],
                                    HEAD, NOW, 7), [])


class StaleCachesTest(unittest.TestCase):
    def cache(self, ref):
        return {"id": 1, "key": "k", "ref": ref}

    def test_closed_pr_and_deleted_branch_caches_are_stale(self):
        caches = [self.cache("refs/pull/25/merge"), self.cache("refs/heads/gone")]
        self.assertEqual(stale_caches(caches, open_prs={33}, branches={"main"}), caches)

    def test_open_pr_existing_branch_and_tag_caches_are_kept(self):
        caches = [self.cache("refs/pull/33/merge"), self.cache("refs/heads/main"), self.cache("refs/tags/v1.0.0")]
        self.assertEqual(stale_caches(caches, open_prs={33}, branches={"main"}), [])


if __name__ == "__main__":
    unittest.main()
