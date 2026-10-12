"""Regression tests for CI/staging deployment proof and release numbering."""
import unittest

from cd_gate import CI, DEPLOY_JOB, DEPLOY_PROOF, GitHub, build_number, release_version


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
        for tag in ("v1.2.2", "v01.2.3", "v1.2.3-beta", "other"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release_version(tag, "version: 1.2.3+1\n")

    def test_retry_numbers_increase_and_next_commit_always_wins(self):
        self.assertLess(build_number(10, 1), build_number(10, 9))
        self.assertLess(build_number(10, 9), build_number(11, 1))
        for count, attempt in ((10, 0), (10, 10), (0, 1), (1000, 1)):
            with self.subTest(count=count, attempt=attempt), self.assertRaises(ValueError):
                build_number(count, attempt)

    def test_pagination_does_not_silently_drop_later_jobs(self):
        api = FakeGitHub({})
        calls = []

        def get(path, **query):
            calls.append(query["page"])
            return {"jobs": list(range(100)) if query["page"] == 1 else [101]}

        api.get = get
        self.assertEqual(len(list(api.pages("jobs", "jobs"))), 101)
        self.assertEqual(calls, [1, 2])


if __name__ == "__main__":
    unittest.main()
