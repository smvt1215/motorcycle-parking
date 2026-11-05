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
# The staging backend and admin site wait for CI only (its backend tests
# included); the App builds also wait for Android and iOS, so an iOS run of
# 30–60 minutes no longer holds back the backend (user decision 2026-11-05).
BACKEND_CI = {"ci.yml": CI["ci.yml"]}
DEPLOY_JOB = "Staging backend deploy"
DEPLOY_PROOF = "Record staging deployment"
# Each App job and the step whose success means its build reached testers.
APP_JOBS = {
    "android": ("Staging Android APK", "Distribute APK to invited testers"),
    "ios": ("Staging iOS IPA", "Distribute IPA to invited testers"),
}


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

    def ci_ready(self, sha, workflows=CI):
        for workflow, check in workflows.items():
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
        """Whether to deploy the staging backend (and admin site) now: CI has
        passed and no earlier run has deployed this SHA."""
        if not self.ci_ready(sha, BACKEND_CI):
            return False
        if self.staging_deployed(sha, fail_if_missing=False):
            print("Skipped: this SHA already has a successful staging backend deployment")
            return False
        return True

    def apps_ready(self, sha):
        """Whether CI, Android and iOS have all passed for the App builds. A
        failed Android or iOS run stops only the App builds (it is red on main
        already), not the backend."""
        try:
            return self.ci_ready(sha)
        except ValueError as error:
            print(f"No staging App builds: {error}")
            return False

    def staging_decision(self, sha):
        """(backend, apps) for a staging run of this SHA, the latest main.
        Apps follow a backend deployed earlier or by this same run."""
        backend = self.staging_ready(sha)
        apps = self.apps_ready(sha) and (backend or self.staging_deployed(sha, fail_if_missing=False))
        return backend, apps

    def staging_outputs(self, sha):
        """The gate's outputs: `deploy` for the backend and admin site, `apps`
        for the App builds; neither unless this SHA is the latest main."""
        if not self.latest_main(sha):
            print("Skipped: source SHA is no longer the latest main")
            return {"deploy": "false", "apps": "false"}
        backend, apps = self.staging_decision(sha)
        return {"deploy": str(backend).lower(), "apps": str(apps).lower()}

    def app_ready(self, sha, platform, current_run):
        """Inside an App job, after its platform queue: still the latest main,
        the backend of this SHA actually deployed (by this run or an earlier
        one: a run whose own deploy found it done must still build), and no
        other run has distributed this build yet."""
        if not self.latest_main(sha):
            print("Skipped: source SHA is no longer the latest main")
            return False
        if not self.staging_deployed(sha, fail_if_missing=False):
            print("Skipped: this SHA has no successful staging backend deployment")
            return False
        if self.app_distributed(sha, platform, current_run):
            print(f"Skipped: this SHA's {platform} build was already distributed")
            return False
        return True

    def app_distributed(self, sha, platform, current_run):
        """Whether another CD staging run already sent this SHA's build for
        the platform to testers (each finished workflow can start a run)."""
        job_name, proof = APP_JOBS[platform]
        for run in self.pages("actions/workflows/cd-staging.yml/runs", "workflow_runs", head_sha=sha):
            if run["id"] == current_run:
                continue
            for job in self.pages(f"actions/runs/{run['id']}/jobs", "jobs", filter="all"):
                if job["name"] == job_name and any(
                    step["name"] == proof and step["conclusion"] == "success"
                    for step in job.get("steps", [])
                ):
                    return True
        return False

    def release_succeeded(self, tag, sha):
        """The tag's own release.yml run (its latest attempt) must have
        succeeded, so a store release only promotes a distributed RC."""
        runs = [run for run in self.pages("actions/workflows/release.yml/runs", "workflow_runs",
                                          head_sha=sha, event="push")
                if run["head_branch"] == tag]
        if not runs:
            raise ValueError(f"No release workflow ran for {tag}; push the RC tag and let it finish")
        run = max(runs, key=lambda item: item["id"])
        if run["status"] != "completed" or run["conclusion"] != "success":
            raise ValueError(f"The {tag} release workflow has not succeeded; finish or rerun the RC first")
        return True

    def production_protected(self):
        environment = self.get("environments/production")
        return any(rule["type"] == "required_reviewers" and rule.get("reviewers")
                   for rule in environment.get("protection_rules", []))


def output(key, value):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        stream.write(f"{key}={value}\n")


RELEASE_TAG = re.compile(r"v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(?:-(beta|rc)\.([1-9]\d*))?")


def release_tag(tag):
    """Split vX.Y.Z, vX.Y.Z-beta.N or vX.Y.Z-rc.N into (version, channel, N)."""
    match = RELEASE_TAG.fullmatch(tag)
    if not match:
        raise ValueError("Release tag must be vX.Y.Z, vX.Y.Z-beta.N or vX.Y.Z-rc.N")
    version, channel, sequence = match.groups()
    return version, channel or "release", int(sequence or 0)


def release_version(tag, text):
    version = release_tag(tag)[0]
    match = re.search(r"^version:\s*(\S+)", text, re.M)
    if not match or match[1].split("+")[0] != version:
        raise ValueError("Release tag must match pubspec.yaml version")
    return version


def promoted_candidate(version, tags, at_head):
    """A store release promotes the newest RC's build, never a new binary,
    so vX.Y.Z must sit on the commit of that version's latest RC tag."""
    candidates = []
    for tag in tags:
        match = RELEASE_TAG.fullmatch(tag)
        if match and match[1] == version and match[2] == "rc":
            candidates.append((int(match[3]), tag))
    if not candidates:
        raise ValueError(f"v{version} needs an RC first; push v{version}-rc.1 and test it")
    latest = max(candidates)[1]
    if latest not in at_head:
        raise ValueError(f"v{version} must be tagged on the latest RC commit ({latest})")
    return latest


def hash_sources(tag, at_head):
    """Other release tags on this commit, whose releases may already hold the
    SHA-256 receipt of a store build this run reuses."""
    return sorted(other for other in at_head if other != tag and RELEASE_TAG.fullmatch(other))


# Each commit owns build numbers count×10+1..9. Beta and RC builds connect to
# different backends, so they never share a number: beta takes digits 1–4 and
# RC 5–9 (a store release promotes from the RC digits).
CHANNEL_DIGITS = {"beta": range(1, 5), "rc": range(5, 10), "release": range(5, 10)}


def build_range(count, channel):
    digits = CHANNEL_DIGITS[channel]
    return count * 10 + digits[0], count * 10 + digits[-1]


def build_number(count, attempt, channel="rc"):
    digits = CHANNEL_DIGITS[channel]
    if count < 1 or not 1 <= attempt <= len(digits):
        raise ValueError(f"{channel} attempt must be 1–{len(digits)}; handle further retries manually")
    number = count * 10 + digits[attempt - 1]
    if number > 9999:
        raise ValueError("Build number exceeds the iOS four-digit limit; revise numbering before release")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["staging", "app", "latest", "release"])
    parser.add_argument("--sha", required=True)
    parser.add_argument("--platform", choices=sorted(APP_JOBS), help="app mode: android or ios")
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
        tag = os.environ["GITHUB_REF_NAME"]
        version = release_version(tag, Path("pubspec.yaml").read_text())
        channel = release_tag(tag)[1]
        if subprocess.check_output(["git", "rev-parse", "--is-shallow-repository"], text=True).strip() != "false":
            raise ValueError("Full Git history is required for build numbering")
        count = int(subprocess.check_output(["git", "rev-list", "--count", "HEAD"], text=True))
        # A store release builds nothing, so its attempt count is irrelevant.
        attempt = 1 if channel == "release" else int(os.environ["GITHUB_RUN_ATTEMPT"])
        number = build_number(count, attempt, channel)
        first, last = build_range(count, channel)
        if not api.production_protected():
            raise ValueError("Configure required reviewers on the production Environment before release")
        at_head = subprocess.check_output(["git", "tag", "--points-at", "HEAD"], text=True).split()
        release_outputs = {"version": version, "channel": channel, "build_number": number,
                           "build_first": first, "build_last": last,
                           "hash_sources": " ".join(hash_sources(tag, at_head))}
        if channel == "release":
            # The RC already passed the main, CI and staging checks; main may
            # have moved on since, and no new binary is built.
            tags = subprocess.check_output(["git", "tag", "--list", "v*"], text=True).split()
            candidate = promoted_candidate(version, tags, at_head)
            api.release_succeeded(candidate, args.sha)
            print(f"Promoting {candidate}")
            output("deploy", "true")
            for key, value in release_outputs.items():
                output(key, value)
            return
    if args.mode == "staging":
        for key, value in api.staging_outputs(args.sha).items():
            output(key, value)
        return
    if args.mode == "app":
        # Inside an App job, after its platform queue: still the latest main,
        # and no other run has distributed this build yet.
        if not args.platform:
            raise ValueError("app mode needs --platform")
        ready = api.app_ready(args.sha, args.platform, int(os.environ["GITHUB_RUN_ID"]))
        output("deploy", str(ready).lower())
        return
    while True:
        current = api.latest_main(args.sha)
        if not current:
            if args.mode == "release":
                raise ValueError("Tag must point to the latest main; move the tag after validation")
            output("deploy", "false")
            print("Skipped: source SHA is no longer the latest main")
            return
        ready = args.mode == "latest" or api.ci_ready(args.sha)
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
