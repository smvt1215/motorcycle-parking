"""Import an Environment's iOS distribution identity into a temporary keychain."""
import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import subprocess

from cd_config import ROOT, private_file, required


def security(*args):
    return subprocess.check_output(["security", *args], stderr=subprocess.PIPE)


def prepare(environment):
    temp = Path(os.environ["RUNNER_TEMP"])
    keychain = temp / "cd-signing.keychain-db"
    password = secrets.token_urlsafe(32)
    print(f"::add-mask::{password}")
    original = security("list-keychains", "-d", "user").decode()
    private_file(temp / "cd-original-keychains.json", json.dumps(shlex.split(original)))
    p12 = temp / "cd-certificate.p12"
    profile_file = temp / "cd-profile.mobileprovision"
    private_file(p12, base64.b64decode(required("IOS_CERTIFICATE_BASE64"), validate=True))
    private_file(profile_file, base64.b64decode(required("IOS_PROFILE_BASE64"), validate=True))
    profile = plistlib.loads(security("cms", "-D", "-i", str(profile_file)))
    bundle = "tw.motopark.motorcycleParking" + (".staging" if environment == "staging" else "")
    team = profile["TeamIdentifier"][0]
    if profile["Entitlements"]["application-identifier"] != f"{team}.{bundle}":
        raise ValueError("Provisioning profile does not match the bundle ID")
    if profile["ExpirationDate"].replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError("Provisioning profile expired")
    if profile["Entitlements"].get("get-task-allow") or profile.get("ProvisionsAllDevices"):
        raise ValueError("A distribution profile is required")
    if bool(profile.get("ProvisionedDevices")) != (environment == "staging"):
        raise ValueError("Staging requires Ad Hoc; production requires App Store profile")
    name = profile["Name"]
    if any(character in name for character in '\n\r"'):
        raise ValueError("Profile name cannot be represented safely in xcconfig")
    destination = Path.home() / "Library/MobileDevice/Provisioning Profiles" / f"{profile['UUID']}.mobileprovision"
    private_file(destination, profile_file.read_bytes())
    private_file(temp / "cd-profile-path", str(destination))
    security("create-keychain", "-p", password, str(keychain))
    security("set-keychain-settings", "-lut", "21600", str(keychain))
    security("unlock-keychain", "-p", password, str(keychain))
    security("import", str(p12), "-k", str(keychain), "-P", required("IOS_CERTIFICATE_PASSWORD"),
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    security("list-keychains", "-d", "user", "-s", str(keychain), *shlex.split(original))
    security("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain))
    private_file(ROOT / "ios/Flutter/Signing.xcconfig",
                 f'CODE_SIGN_STYLE = Manual\nDEVELOPMENT_TEAM = {team}\n'
                 f'CODE_SIGN_IDENTITY = Apple Distribution\nPROVISIONING_PROFILE_SPECIFIER = {name}\n')
    template = ROOT / f"ios/ExportOptions-{environment}.plist"
    options = plistlib.loads(template.read_bytes())
    options.update({"teamID": team, "provisioningProfiles": {bundle: profile["UUID"]}})
    private_file(temp / "ExportOptions.plist", plistlib.dumps(options))
    if environment == "staging":
        # CFBundleVersion: four digits, two digits, two digits. A queued job
        # waits for the next ten-second slot so consecutive jobs never collide.
        import time
        now = time.time()
        time.sleep(10 - now % 10)
        seconds = int(time.time()) - 1577836800  # 2020-01-01 UTC
        day, seconds = divmod(seconds, 86400)
        if not 0 <= day < 9999:
            raise ValueError("Staging build numbering epoch is exhausted")
        slot = seconds // 10
        number = f"{day + 1}.{slot // 100}.{slot % 100}"
        with open(os.environ["GITHUB_ENV"], "a") as stream:
            stream.write(f"IOS_BUILD_NUMBER={number}\n")
    print(f"Prepared {environment} signing")


def cleanup():
    temp = Path(os.environ["RUNNER_TEMP"])
    original = temp / "cd-original-keychains.json"
    if original.exists():
        security("list-keychains", "-d", "user", "-s", *json.loads(original.read_text()))
    keychain = temp / "cd-signing.keychain-db"
    if keychain.exists():
        security("delete-keychain", str(keychain))
    profile = temp / "cd-profile-path"
    if profile.exists():
        Path(profile.read_text()).unlink(missing_ok=True)
    for path in (ROOT / "ios/Flutter/Signing.xcconfig", temp / "cd-certificate.p12",
                 temp / "cd-profile.mobileprovision", temp / "ExportOptions.plist", original, profile):
        path.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["staging", "production", "cleanup"])
    mode = parser.parse_args().mode
    try:
        cleanup() if mode == "cleanup" else prepare(mode)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError):
        raise SystemExit("iOS signing failed; verify certificate, password and provisioning profile") from None
