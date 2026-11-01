"""Raise client_config's minimum App version to config/app_compat.json (#195 P2).

CD calls this after a deploy; it goes through the audited write path
admin_v1.set_min_supported_app_version() as service_role, which only ever
raises (an equal or lower mark changes nothing). The reason names the run.

    SUPABASE_URL=... SUPABASE_SERVICE_KEY=... RUN_URL=... \\
      python3 tool/raise_min_app_version.py [--require-app-store <bundle id>]

--require-app-store (production): refuse unless the App Store already lists
that bundle at the marked version or later. Google Play has no public
lookup; the production workflow's approver confirms it instead.
"""
import argparse
import json
import re
import subprocess
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tool"))
from check_app_compat import COMPAT, compat_version, semver  # noqa: E402

APP_STORE_LOOKUP = "https://itunes.apple.com/lookup?country=tw&bundleId="


def read_json(request, opener):
    try:
        with opener(request, timeout=30) as response:
            return response.status, json.loads(response.read() or b"null")
    except urllib.error.HTTPError as error:
        body = error.read()
        try:
            return error.code, json.loads(body or b"null")
        except ValueError:
            return error.code, body[:200].decode("utf-8", "replace")


def app_store_version(bundle_id, opener=urllib.request.urlopen):
    """The version the App Store lists for the bundle, or None."""
    request = urllib.request.Request(APP_STORE_LOOKUP + urllib.parse.quote(bundle_id))
    status, body = read_json(request, opener)
    if status != 200 or not isinstance(body, dict) or not body.get("results"):
        return None
    return body["results"][0].get("version")


def raise_minimum(url, key, version, reason, opener=urllib.request.urlopen):
    """The function's answer: {min_supported_app_version, changed}."""
    request = urllib.request.Request(
        f"{url.rstrip('/')}/rest/v1/rpc/set_min_supported_app_version",
        data=json.dumps({"p_version": version, "p_reason": reason}).encode(),
        method="POST",
        headers={
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Content-Profile": "admin_v1",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    status, body = read_json(request, opener)
    if status != 200 or not isinstance(body, dict) or "changed" not in body:
        raise RuntimeError(f"set_min_supported_app_version answered {status}: {body}")
    return body


PLAY_API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"


def release_version_code(version):
    """The versionCode of release vX.Y.Z: the build number in its tagged pubspec."""
    result = subprocess.run(["git", "show", f"v{version}:pubspec.yaml"], cwd=ROOT,
                            capture_output=True, text=True)
    match = re.search(r"^version:\s*\d+\.\d+\.\d+\+(\d+)", result.stdout, re.M)
    return int(match[1]) if result.returncode == 0 and match else None


def play_token(service_account_json):
    """An OAuth token for the Android Publisher API (read only is enough)."""
    from google.auth.transport.requests import Request
    from google.oauth2 import service_account
    credentials = service_account.Credentials.from_service_account_info(
        json.loads(service_account_json),
        scopes=["https://www.googleapis.com/auth/androidpublisher"])
    credentials.refresh(Request())
    return credentials.token


def play_rollout(package, version_code, token, opener=urllib.request.urlopen):
    """(fully live, what the production track shows) for that versionCode.

    Reads through a temporary edit that is always deleted, never committed,
    so nothing on the store changes.
    """
    base = f"{PLAY_API}{urllib.parse.quote(package)}/edits"
    auth = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    status, edit = read_json(urllib.request.Request(base, data=b"{}", method="POST",
                                                    headers={**auth, "Content-Type": "application/json"}),
                             opener)
    if status != 200 or not isinstance(edit, dict) or "id" not in edit:
        raise RuntimeError(f"Play edits.insert answered {status}: {edit}")
    try:
        status, track = read_json(urllib.request.Request(
            f"{base}/{edit['id']}/tracks/production", headers=auth), opener)
    finally:
        read_json(urllib.request.Request(f"{base}/{edit['id']}", method="DELETE", headers=auth),
                  opener)
    if status != 200 or not isinstance(track, dict):
        raise RuntimeError(f"Play tracks.get answered {status}: {track}")
    for release in track.get("releases", []):
        if str(version_code) not in [str(code) for code in release.get("versionCodes", [])]:
            continue
        state = release.get("status")
        fraction = release.get("userFraction")
        if state == "completed" or (state == "inProgress" and fraction == 1):
            return True, f"production {state}"
        if state == "inProgress":
            return False, f"production rollout at {fraction:.0%}" if fraction else "production inProgress"
        return False, f"production {state}"
    return False, "not on the production track"


def main(argv=None, opener=urllib.request.urlopen, token=play_token):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--require-app-store", metavar="BUNDLE_ID")
    parser.add_argument("--require-play", metavar="PACKAGE",
                        help="check the production track with GOOGLE_PLAY_SERVICE_ACCOUNT_JSON; "
                             "without it, PLAY_CONFIRMED=true (the approver's word) is required")
    args = parser.parse_args(argv)
    url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_KEY")
    reason = os.environ.get("RUN_URL") or ""
    if not url or not key or not reason:
        print("raise_min_app_version: SUPABASE_URL, SUPABASE_SERVICE_KEY and RUN_URL are required",
              file=sys.stderr)
        return 2
    version = compat_version((ROOT / COMPAT).read_text())
    if semver(version) is None:
        print(f"::error file={COMPAT}::not x.y.z: {version!r}")
        return 1
    if args.require_app_store:
        listed = app_store_version(args.require_app_store, opener)
        if semver(listed) is None or semver(listed) < semver(version):
            print(f"::error::the App Store lists {args.require_app_store} at {listed!r}, "
                  f"not {version} or later; raise after the release is live")
            return 1
        print(f"App Store: {args.require_app_store} is live at {listed} (checked by the lookup API)")
    if args.require_play:
        account = os.environ.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON")
        if account:
            code = release_version_code(version)
            if code is None:
                print(f"::error::no release tag v{version} with a pubspec build number")
                return 1
            try:
                live, shown = play_rollout(args.require_play, code, token(account), opener)
            except RuntimeError as error:
                print(f"::error::{error}")
                return 1
            if not live:
                print(f"::error::Google Play: {args.require_play} versionCode {code} is {shown}; "
                      "raise once it is out to 100%")
                return 1
            print(f"Google Play: versionCode {code} is {shown} (checked by the Play Developer API)")
        elif os.environ.get("PLAY_CONFIRMED") == "true":
            print("Google Play: confirmed by the approver (no service account is set up yet)")
        else:
            print("::error::Google Play is unchecked: set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON, "
                  "or have the approver confirm Play lists the release")
            return 1
    try:
        answer = raise_minimum(url, key, version, reason, opener)
    except RuntimeError as error:
        print(f"::error::{error}")
        return 1
    state = "raised to" if answer["changed"] else "unchanged at"
    print(f"Minimum App version {state} {answer['min_supported_app_version']} (mark {version})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
