"""Delete old GitHub Actions runs and stale caches without touching deployment evidence.

Kept: runs for main's latest commit (cd_gate.py reads them before deploying), runs
still in progress, every Release run (production audit trail), and anything newer
than the retention window. Caches go once their PR is closed or branch deleted.
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
import re
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

KEEP_WORKFLOWS = {"Release"}


def stale_runs(runs, head_sha, now, days):
    """Completed runs older than `days`, except main's latest commit and kept workflows."""
    cutoff = now - timedelta(days=days)
    return [run for run in runs
            if run["status"] == "completed"
            and run["head_sha"] != head_sha
            and run["name"] not in KEEP_WORKFLOWS
            and datetime.fromisoformat(run["created_at"].replace("Z", "+00:00")) < cutoff]


def stale_caches(caches, open_prs, branches):
    """Caches for closed PRs or deleted branches; tags and unknown refs are left alone."""
    stale = []
    for cache in caches:
        ref = cache["ref"]
        pr = re.fullmatch(r"refs/pull/(\d+)/merge", ref)
        if pr and int(pr[1]) not in open_prs:
            stale.append(cache)
        elif ref.startswith("refs/heads/") and ref.removeprefix("refs/heads/") not in branches:
            stale.append(cache)
    return stale


class GitHub:
    def __init__(self):
        self.repo = os.environ["GITHUB_REPOSITORY"]
        self.token = os.environ["GH_TOKEN"]
        self.base = os.environ.get("GITHUB_API_URL", "https://api.github.com")

    def call(self, method, path, **query):
        url = f"{self.base}/repos/{self.repo}/{path}" + ("?" + urlencode(query) if query else "")
        request = Request(url, method=method, headers={"Authorization": f"Bearer {self.token}",
                                                       "Accept": "application/vnd.github+json",
                                                       "X-GitHub-Api-Version": "2022-11-28"})
        with urlopen(request, timeout=30) as response:
            body = response.read()
            return json.loads(body) if body else None

    def pages(self, path, key=None, **query):
        page = 1
        while True:
            data = self.call("GET", path, per_page=100, page=page, **query)
            values = data[key] if key else data
            yield from values
            if len(values) < 100:
                return
            page += 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--days", type=int, default=7, help="keep completed runs newer than this")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    api = GitHub()
    head = api.call("GET", "commits/main")["sha"]
    runs = stale_runs(api.pages("actions/runs", "workflow_runs"), head, datetime.now(timezone.utc), args.days)
    open_prs = {pr["number"] for pr in api.pages("pulls", state="open")}
    branches = {branch["name"] for branch in api.pages("branches")}
    caches = stale_caches(api.pages("actions/caches", "actions_caches"), open_prs, branches)
    deleted = failed = 0
    for kind, items in (("run", runs), ("cache", caches)):
        for item in items:
            label = item.get("name") or item.get("key")
            if args.dry_run:
                print(f"would delete {kind} {item['id']} ({label})")
                continue
            try:
                api.call("DELETE", f"actions/{kind}s/{item['id']}")
                deleted += 1
            except HTTPError as error:  # a run may finish or vanish meanwhile; report and continue
                failed += 1
                print(f"::warning::Could not delete {kind} {item['id']}: HTTP {error.code}")
    print(f"Stale runs: {len(runs)}, stale caches: {len(caches)}, deleted: {deleted}, failed: {failed}")


if __name__ == "__main__":
    main()
