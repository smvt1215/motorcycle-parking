"""Regression tests for CI/staging deployment proof and release numbering."""
import unittest

from cd_gate import (APP_JOBS, CI, DEPLOY_JOB, DEPLOY_PROOF, GitHub, build_number, build_range,
                     hash_sources, promoted_candidate, release_tag, release_version)


class FakeGitHub(GitHub):
    def __init__(self, responses):
        self.responses = responses
        self.queries = []

    def get(self, path, **query):
        self.queries.append((path, query))
        return self.responses[path]


def ci_responses():
    responses = {}
    for index, (workflow, check) in enumerate(CI.items(), 1):
        responses[f"actions/workflows/{workflow}/runs"] = {"workflow_runs": [
            {"id": index, "status": "completed", "conclusion": "success", "run_attempt": 1}]}
        responses[f"actions/runs/{index}/jobs"] = {"jobs": [{"name": check, "conclusion": "success"}]}
    return responses


class DeploymentGateTest(unittest.TestCase):
    def test_requires_all_three_aggregate_jobs_on_trusted_main_push(self):
        api = FakeGitHub(ci_responses())
        self.assertTrue(api.ci_ready("sha"))
        for path, query in api.queries:
            if path.endswith("/runs"):
                self.assertEqual((query["head_sha"], query["branch"], query["event"]), ("sha", "main", "push"))

    def test_latest_failed_run_overrides_old_success(self):
        responses = ci_responses()
        responses["actions/workflows/ci.yml/runs"]["workflow_runs"].append(
            {"id": 99, "status": "completed", "conclusion": "failure", "run_attempt": 1})
        with self.assertRaisesRegex(ValueError, "failed"):
            FakeGitHub(responses).ci_ready("sha")

    def test_workflow_success_without_required_check_is_rejected(self):
        responses = ci_responses()
        responses["actions/runs/1/jobs"]["jobs"] = []
        with self.assertRaisesRegex(ValueError, "aggregate"):
            FakeGitHub(responses).ci_ready("sha")

    def test_incomplete_ci_defers_deployment(self):
        responses = ci_responses()
        responses["actions/workflows/ios.yml/runs"]["workflow_runs"][0]["status"] = "in_progress"
        self.assertFalse(FakeGitHub(responses).ci_ready("sha"))

    def test_cancelled_aggregate_is_not_success(self):
        responses = ci_responses()
        responses["actions/runs/2/jobs"]["jobs"][0]["conclusion"] = "cancelled"
        with self.assertRaises(ValueError):
            FakeGitHub(responses).ci_ready("sha")

    def staging(self, step_conclusion, job_conclusion="success", run_status="completed"):
        return FakeGitHub({
            "actions/workflows/cd-staging.yml/runs": {"workflow_runs": [{"id": 4, "status": run_status}]},
            "actions/runs/4/jobs": {"jobs": [{"name": DEPLOY_JOB, "status": "completed", "conclusion": job_conclusion,
                "steps": [{"name": DEPLOY_PROOF, "conclusion": step_conclusion}]}]},
        })

    def test_skipped_steps_in_successful_job_do_not_prove_deployment(self):
        with self.assertRaisesRegex(ValueError, "No successful staging"):
            self.staging("skipped").staging_deployed("sha")

    def test_backend_proof_suffices_while_ipa_is_pending(self):
        self.assertTrue(self.staging("success", run_status="in_progress").staging_deployed("sha"))

    def test_ipa_only_rerun_keeps_backend_proof_from_earlier_attempt(self):
        api = self.staging("success")
        self.assertTrue(api.staging_deployed("sha"))
        query = next(query for path, query in api.queries if path.endswith("/jobs"))
        self.assertEqual(query["filter"], "all")

    def test_failed_backend_does_not_prove_deployment(self):
        with self.assertRaises(ValueError):
            self.staging("success", job_conclusion="failure").staging_deployed("sha")

    def test_second_queued_event_is_deduplicated_after_first_backend_finishes(self):
        api = self.staging("skipped", run_status="in_progress")
        api.responses.update(ci_responses())
        self.assertTrue(api.staging_ready("sha"))
        self.assertTrue(api.staging_ready("sha"))
        # Both events passed before queuing. The first completes while owning
        # the fixed cd-staging lock; the second must recheck after acquiring it.
        api.responses["actions/runs/4/jobs"]["jobs"][0]["steps"][0]["conclusion"] = "success"
        self.assertFalse(api.staging_ready("sha"))

    def test_failed_deployment_can_retry_without_being_claimed_as_done(self):
        api = self.staging("skipped", job_conclusion="failure")
        api.responses.update(ci_responses())
        self.assertTrue(api.staging_ready("sha"))

    def test_missing_staging_run_waits_for_scheduling(self):
        api = FakeGitHub({"actions/workflows/cd-staging.yml/runs": {"workflow_runs": []}})
        self.assertFalse(api.staging_deployed("sha"))

    def test_current_main_comparison_is_exact(self):
        api = FakeGitHub({"commits/main": {"sha": "latest"}})
        self.assertFalse(api.latest_main("ancestor"))
        self.assertTrue(api.latest_main("latest"))

    def test_production_requires_actual_reviewers(self):
        api = FakeGitHub({"environments/production": {"protection_rules": []}})
        self.assertFalse(api.production_protected())
        api.responses["environments/production"]["protection_rules"] = [{"type": "required_reviewers", "reviewers": [{"id": 1}]}]
        self.assertTrue(api.production_protected())

    def test_stable_tag_matches_pubspec(self):
        self.assertEqual(release_version("v1.2.3", "version: 1.2.3+1\n"), "1.2.3")
        for tag in ("v1.2.2", "v01.2.3", "v1.2.3-beta", "v1.2.3-beta.0", "v1.2.3-alpha.1", "v1.2.3-rc1", "other"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_version(tag, "version: 1.2.3+1\n")

    def test_channel_tags_share_the_store_version(self):
        self.assertEqual(release_tag("v1.2.3"), ("1.2.3", "release", 0))
        self.assertEqual(release_tag("v1.2.3-beta.2"), ("1.2.3", "beta", 2))
        self.assertEqual(release_tag("v1.2.3-rc.10"), ("1.2.3", "rc", 10))
        # Stores only accept X.Y.Z, so every channel builds the pubspec version.
        self.assertEqual(release_version("v1.2.3-rc.1", "version: 1.2.3+1\n"), "1.2.3")

    def test_store_release_promotes_only_the_latest_rc_commit(self):
        tags = ["v1.2.3-beta.1", "v1.2.3-rc.1", "v1.2.3-rc.2", "v1.2.2", "v1.3.0-rc.9"]
        self.assertEqual(promoted_candidate("1.2.3", tags, ["v1.2.3-rc.2", "v1.2.3"]), "v1.2.3-rc.2")
        # Numeric, not lexical: rc.10 is newer than rc.9.
        self.assertEqual(promoted_candidate("1.2.3", ["v1.2.3-rc.9", "v1.2.3-rc.10"], ["v1.2.3-rc.10"]),
                         "v1.2.3-rc.10")
        with self.assertRaisesRegex(ValueError, "latest RC"):
            promoted_candidate("1.2.3", tags, ["v1.2.3-rc.1"])
        with self.assertRaisesRegex(ValueError, "needs an RC"):
            promoted_candidate("1.2.3", ["v1.2.3-beta.1"], ["v1.2.3-beta.1"])
        with self.assertRaisesRegex(ValueError, "needs an RC"):
            promoted_candidate("1.2.3", ["v1.3.0-rc.1"], ["v1.3.0-rc.1"])

    def test_store_release_requires_the_rc_workflow_to_have_succeeded(self):
        def runs(*items):
            return FakeGitHub({"actions/workflows/release.yml/runs": {"workflow_runs": list(items)}})

        ok = {"id": 7, "head_branch": "v1.2.3-rc.2", "status": "completed", "conclusion": "success"}
        self.assertTrue(runs(ok).release_succeeded("v1.2.3-rc.2", "sha"))
        # Another tag's success on the same commit (a beta) does not count.
        beta = dict(ok, id=8, head_branch="v1.2.3-beta.1")
        with self.assertRaisesRegex(ValueError, "No release workflow"):
            runs(beta).release_succeeded("v1.2.3-rc.2", "sha")
        for status, conclusion in (("completed", "failure"), ("in_progress", None), ("completed", "cancelled")):
            with self.subTest(status=status, conclusion=conclusion), self.assertRaisesRegex(ValueError, "not succeeded"):
                runs(dict(ok, status=status, conclusion=conclusion)).release_succeeded("v1.2.3-rc.2", "sha")
        # The newest run decides: a later failed run outranks an older success.
        with self.assertRaisesRegex(ValueError, "not succeeded"):
            runs(ok, dict(ok, id=9, conclusion="failure")).release_succeeded("v1.2.3-rc.2", "sha")
        api = runs(ok)
        api.release_succeeded("v1.2.3-rc.2", "sha")
        self.assertEqual(api.queries[0][1]["head_sha"], "sha")
        self.assertEqual(api.queries[0][1]["event"], "push")

    def test_hash_receipts_come_from_other_release_tags_on_the_commit(self):
        self.assertEqual(hash_sources("v1.2.3", ["v1.2.3", "v1.2.3-rc.1", "v1.2.3-beta.2", "note"]),
                         ["v1.2.3-beta.2", "v1.2.3-rc.1"])

    def test_retry_numbers_increase_and_next_commit_always_wins(self):
        self.assertLess(build_number(10, 1, "rc"), build_number(10, 5, "rc"))
        self.assertLess(build_number(10, 5, "rc"), build_number(11, 1, "beta"))
        for count, attempt, channel in ((10, 0, "rc"), (10, 6, "rc"), (10, 5, "beta"), (0, 1, "beta"), (1000, 1, "rc")):
            with self.subTest(count=count, attempt=attempt, channel=channel), self.assertRaises(ValueError):
                build_number(count, attempt, channel)

    def test_beta_and_rc_never_share_a_build_number(self):
        # They connect to different backends, so an RC must never reuse a beta binary.
        self.assertEqual(build_range(10, "beta"), (101, 104))
        self.assertEqual(build_range(10, "rc"), (105, 109))
        self.assertEqual(build_range(10, "release"), build_range(10, "rc"))
        beta = {build_number(10, attempt, "beta") for attempt in range(1, 5)}
        rc = {build_number(10, attempt, "rc") for attempt in range(1, 6)}
        self.assertEqual(beta, set(range(101, 105)))
        self.assertEqual(rc, set(range(105, 110)))

    def test_pagination_does_not_silently_drop_later_jobs(self):
        api = FakeGitHub({})
        calls = []

        def get(path, **query):
            calls.append(query["page"])
            return {"jobs": list(range(100)) if query["page"] == 1 else [101]}

        api.get = get
        self.assertEqual(len(list(api.pages("jobs", "jobs"))), 101)
        self.assertEqual(calls, [1, 2])


def staging_world(android="success", ios="success", ci="success", deployed=False, latest=True):
    """CI on the SHA, Android and iOS finished as given (None: still running),
    and whether an earlier CD staging run deployed the backend."""
    responses = ci_responses()
    for index, (workflow, conclusion) in enumerate(
            (("ci.yml", ci), ("android.yml", android), ("ios.yml", ios)), 1):
        run = responses[f"actions/workflows/{workflow}/runs"]["workflow_runs"][0]
        if conclusion is None:
            run["status"] = "in_progress"
        else:
            run["conclusion"] = conclusion
    responses["actions/workflows/cd-staging.yml/runs"] = {"workflow_runs": [{"id": 4, "status": "completed"}]}
    responses["actions/runs/4/jobs"] = {"jobs": [
        {"name": DEPLOY_JOB, "status": "completed", "conclusion": "success",
         "steps": [{"name": DEPLOY_PROOF, "conclusion": "success" if deployed else "skipped"}]}]}
    responses["commits/main"] = {"sha": "sha" if latest else "newer"}
    return FakeGitHub(responses)


class StagingSplitTest(unittest.TestCase):
    """The backend and admin site wait for CI only; the App builds wait for
    CI, Android and iOS (user decision 2026-11-05). Release gates unchanged."""

    def test_ci_alone_deploys_the_backend_without_app_builds(self):
        for running in ({"ios": None}, {"android": None}, {"android": None, "ios": None}):
            with self.subTest(running=running):
                outputs = staging_world(**running).staging_outputs("sha")
                self.assertEqual(outputs, {"deploy": "true", "apps": "false"})

    def test_all_three_deploy_the_backend_and_build_the_apps(self):
        self.assertEqual(staging_world().staging_outputs("sha"), {"deploy": "true", "apps": "true"})

    def test_apps_follow_a_backend_an_earlier_run_deployed(self):
        # CI finished first and deployed; iOS finishing later builds the Apps only.
        self.assertEqual(staging_world(deployed=True).staging_outputs("sha"),
                         {"deploy": "false", "apps": "true"})

    def test_older_than_latest_main_skips_both(self):
        api = staging_world(latest=False)
        self.assertEqual(api.staging_outputs("sha"), {"deploy": "false", "apps": "false"})
        self.assertEqual([path for path, _ in api.queries], ["commits/main"])

    def test_failed_ios_stops_only_the_app_builds(self):
        for failed in ({"ios": "failure"}, {"android": "cancelled"}):
            with self.subTest(failed=failed):
                self.assertEqual(staging_world(**failed).staging_outputs("sha"),
                                 {"deploy": "true", "apps": "false"})

    def test_failed_ci_stops_everything(self):
        with self.assertRaisesRegex(ValueError, "ci.yml failed"):
            staging_world(ci="failure").staging_outputs("sha")

    def test_backend_reads_only_ci(self):
        api = staging_world(ios=None)
        api.staging_ready("sha")
        workflows = {path for path, _ in api.queries if path.startswith("actions/workflows/")}
        self.assertNotIn("actions/workflows/ios.yml/runs", workflows)
        self.assertNotIn("actions/workflows/android.yml/runs", workflows)

    def test_release_still_requires_all_three(self):
        with self.assertRaises(ValueError):
            staging_world(ios="failure").ci_ready("sha")
        self.assertFalse(staging_world(android=None).ci_ready("sha"))

    def distributed(self, conclusion, run_id=7):
        job, proof = APP_JOBS["ios"]
        return FakeGitHub({
            "actions/workflows/cd-staging.yml/runs": {"workflow_runs": [{"id": run_id}]},
            f"actions/runs/{run_id}/jobs": {"jobs": [
                {"name": job, "steps": [{"name": proof, "conclusion": conclusion}]}]},
        })

    def test_an_app_build_reaches_testers_once_per_sha(self):
        self.assertTrue(self.distributed("success").app_distributed("sha", "ios", current_run=9))
        self.assertFalse(self.distributed("skipped").app_distributed("sha", "ios", current_run=9))
        self.assertFalse(self.distributed("success").app_distributed("sha", "android", current_run=9))

    def app_world(self, deployed=True, latest=True, distributed=False):
        job, proof = APP_JOBS["ios"]
        return FakeGitHub({
            "commits/main": {"sha": "sha" if latest else "newer"},
            "actions/workflows/cd-staging.yml/runs": {"workflow_runs": [
                {"id": 4, "status": "completed"}, {"id": 9, "status": "in_progress"}]},
            "actions/runs/4/jobs": {"jobs": [
                {"name": DEPLOY_JOB, "status": "completed", "conclusion": "success",
                 "steps": [{"name": DEPLOY_PROOF, "conclusion": "success" if deployed else "skipped"}]},
                {"name": job, "steps": [{"name": proof, "conclusion": "success" if distributed else "skipped"}]}]},
            "actions/runs/9/jobs": {"jobs": []},
        })

    def test_app_job_builds_after_a_backend_any_run_deployed(self):
        # This run's deploy may have found the backend already done (another
        # run held the cd-staging lock): the App still builds.
        self.assertTrue(self.app_world().app_ready("sha", "ios", current_run=9))

    def test_app_job_skips_without_a_deployed_backend_or_when_superseded(self):
        self.assertFalse(self.app_world(deployed=False).app_ready("sha", "ios", current_run=9))
        self.assertFalse(self.app_world(latest=False).app_ready("sha", "ios", current_run=9))
        self.assertFalse(self.app_world(distributed=True).app_ready("sha", "ios", current_run=9))

    def test_the_current_run_does_not_count_as_already_distributed(self):
        self.assertFalse(self.distributed("success", run_id=9).app_distributed("sha", "ios", current_run=9))


if __name__ == "__main__":
    unittest.main()
