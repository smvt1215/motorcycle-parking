"""Gate deployments using trusted, latest GitHub workflow runs for one SHA."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import urlencode
from urllib.request import Request, urlopen

CI = {"ci.yml": "CI 全部通過", "android.yml": "Android 全部通過", "ios.yml": "iOS 全部通過"}
DEPLOY_JOB = "Staging backend deploy"
DEPLOY_PROOF = "Record staging deployment"


class GitHub:
    def __init__(self):
        self.repo = os.environ["GITHUB_REPOSITORY"]
        self.token = os.environ["GH_TOKEN"]
        self.base = os.environ.get("GITHUB_API_URL", "https://api.github.com")

    def get(self, path, **query):
        url = f"{self.base}/repos/{self.repo}/{path}"
        if query:
            url += "?" + urlencode(query)
        request = Request(url, headers={"Authorization": f"Bearer {self.token}",
                                       "Accept": "application/vnd.github+json",
                                       "X-GitHub-Api-Version": "2022-11-28"})
        with urlopen(request, timeout=30) as response:
            return json.load(response)

    def pages(self, path, key, **query):
        page = 1
        while True:
            values = self.get(path, per_page=100, page=page, **query)[key]
            yield from values
            if len(values) < 100:
                return
            page += 1

    def latest_main(self, sha):
        return self.get("commits/main")["sha"] == sha

    def ci_ready(self, sha):
        for workflow, check in CI.items():
            runs = list(self.pages(f"actions/workflows/{workflow}/runs", "workflow_runs",
                                   head_sha=sha, branch="main", event="push"))
            if not runs:
                print(f"Waiting for {workflow} on {sha}")
                return False
            run = max(runs, key=lambda item: item["id"])
            if run["status"] != "completed":
                print(f"Waiting for {workflow} attempt {run['run_attempt']}")
                return False
            if run["conclusion"] != "success":
                raise ValueError(f"{workflow} failed on {sha}; fix CI before deployment")
            jobs = list(self.pages(f"actions/runs/{run['id']}/jobs", "jobs", filter="latest"))
            matches = [job for job in jobs if job["name"] == check]
            if len(matches) != 1 or matches[0]["conclusion"] != "success":
                raise ValueError(f"Required aggregate check {check} did not pass")
        return True

    def staging_deployed(self, sha, fail_if_missing=True):
        # A workflow_run workflow uses main's SHA. The staging gate checks that
        # it equals the source SHA before and after queuing; require a real step,
        # since an outdated deployment can have a successful job with skipped steps.
        runs = self.pages("actions/workflows/cd-staging.yml/runs", "workflow_runs", head_sha=sha)
        pending = False
        found = False
        for run in runs:
            found = True
            # A rerun of only the failed IPA job must not erase the successful
            # backend proof from a preceding attempt of this same workflow run.
            jobs = self.pages(f"actions/runs/{run['id']}/jobs", "jobs", filter="all")
            for job in jobs:
                if job["name"] != DEPLOY_JOB:
                    continue
                if job["conclusion"] == "success" and any(
                    step["name"] == DEPLOY_PROOF and step["conclusion"] == "success"
                    for step in job.get("steps", [])
                ):
                    return True
                pending |= job["status"] != "completed"
            pending |= run["status"] != "completed"
        if fail_if_missing and found and not pending:
            raise ValueError("No successful staging backend deployment for this SHA; fix or rerun staging")
        return False

    def staging_ready(self, sha):
        if not self.ci_ready(sha):
            return False
        if self.staging_deployed(sha, fail_if_missing=False):
            print("Skipped: this SHA already has a successful staging backend deployment")
            return False
        return True

    def production_protected(self):
        environment = self.get("environments/production")
        return any(rule["type"] == "required_reviewers" and rule.get("reviewers")
                   for rule in environment.get("protection_rules", []))


def output(key, value):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        stream.write(f"{key}={value}\n")


def release_version(tag, text):
    if not re.fullmatch(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", tag):
        raise ValueError("Release tag must be vX.Y.Z")
    match = re.search(r"^version:\s*(\S+)", text, re.M)
    if not match or match[1].split("+")[0] != tag[1:]:
        raise ValueError("Release tag must match pubspec.yaml version")
    return tag[1:]


def build_number(count, attempt):
    if count < 1 or not 1 <= attempt <= 9:
        raise ValueError("Release attempt must be 1–9; handle further retries manually")
    number = count * 10 + attempt
    if number > 9999:
        raise ValueError("Build number exceeds the iOS four-digit limit; revise numbering before release")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["staging", "latest", "deployed", "release"])
    parser.add_argument("--sha", required=True)
    parser.add_argument("--wait", type=int, default=0)
    args = parser.parse_args()
    api = GitHub()
    deadline = time.monotonic() + args.wait
    release_outputs = {}
    if args.mode == "staging":
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        run = event["workflow_run"]
        if (run["event"] != "push" or run["head_branch"] != "main"
                or run["head_repository"]["full_name"] != api.repo or run["head_sha"] != args.sha):
            raise ValueError("Staging requires a trusted main push workflow")
    if args.mode == "release":
        version = release_version(os.environ["GITHUB_REF_NAME"], Path("pubspec.yaml").read_text())
        if subprocess.check_output(["git", "rev-parse", "--is-shallow-repository"], text=True).strip() != "false":
            raise ValueError("Full Git history is required for build numbering")
        count = int(subprocess.check_output(["git", "rev-list", "--count", "HEAD"], text=True))
        number = build_number(count, int(os.environ["GITHUB_RUN_ATTEMPT"]))
        if not api.production_protected():
            raise ValueError("Configure required reviewers on the production Environment before release")
        release_outputs = {"version": version, "build_number": number, "build_base": count * 10}
    while True:
        current = api.latest_main(args.sha)
        if not current:
            if args.mode == "release":
                raise ValueError("Tag must point to the latest main; move the tag after validation")
            output("deploy", "false")
            print("Skipped: source SHA is no longer the latest main")
            return
        if args.mode == "latest":
            ready = True
        elif args.mode == "staging":
            ready = api.staging_ready(args.sha)
        elif args.mode == "deployed":
            # Out-of-band rebuilds (new tester devices) wait for this SHA's backend.
            ready = api.staging_deployed(args.sha, fail_if_missing=False)
        else:
            ready = api.ci_ready(args.sha)
        if ready and args.mode == "release":
            ready = api.staging_deployed(args.sha)
        if ready:
            output("deploy", "true")
            for key, value in release_outputs.items():
                output(key, value)
            return
        if time.monotonic() >= deadline:
            if args.mode == "release":
                raise ValueError("Timed out waiting for CI and staging (60 minute limit)")
            output("deploy", "false")
            return
        time.sleep(min(30, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from None
