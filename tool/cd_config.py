"""Prepare private application build configuration from Environment settings."""
import argparse
import base64
import json
import os
from pathlib import Path
import re

from configure_maps import configure

ROOT = Path(__file__).resolve().parent.parent


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"Missing Environment setting: {name}")
    return value


def private_file(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch(mode=0o600, exist_ok=True)
    path.chmod(0o600)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())


def configure_build(environment, platform):
    ref = required("SUPABASE_PROJECT_REF")
    url = required("SUPABASE_URL")
    if not re.fullmatch(r"[a-z]{20}", ref) or url.rstrip("/") != f"https://{ref}.supabase.co":
        raise ValueError("SUPABASE_URL must match this Environment's SUPABASE_PROJECT_REF")
    if platform == "backend":
        return
    values = {"SUPABASE_URL": url, "SUPABASE_ANON_KEY": required("SUPABASE_ANON_KEY"),
              "OAUTH_REDIRECT_URL": "tw.motopark.motorcycleparking"
              + (".staging" if environment == "staging" else "") + "://login-callback"}
    if platform == "web":
        # Admin OAuth always returns to the current web URL, never a mobile scheme.
        values.pop("OAUTH_REDIRECT_URL")
        values["GOOGLE_MAPS_WEB_API_KEY"] = required("GOOGLE_MAPS_API_KEY")
        private_file(ROOT / f"config/{environment}.json", json.dumps(values))
        return
    maps = ROOT / "config/maps.local.json"
    private_file(maps, json.dumps({platform: required("GOOGLE_MAPS_API_KEY")}))
    configure(maps, ROOT)
    values.update(json.loads((ROOT / "config/maps.generated.json").read_text()))
    private_file(ROOT / f"config/{environment}.json", json.dumps(values))
    if platform == "android":
        keystore = Path(os.environ["RUNNER_TEMP"]) / "upload.jks"
        private_file(keystore, base64.b64decode(required("ANDROID_KEYSTORE_BASE64"), validate=True))
        # Gradle uses environment variables directly, avoiding Java Properties
        # escaping bugs in passwords containing backslashes or separators.
        for name in ("ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD", "ANDROID_STORE_PASSWORD"):
            required(name)
        with open(os.environ["GITHUB_ENV"], "a") as stream:
            stream.write(f"ANDROID_KEYSTORE_PATH={keystore}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("environment", choices=["staging", "production"])
    parser.add_argument("platform", choices=["android", "ios", "web", "backend"])
    args = parser.parse_args()
    configure_build(args.environment, args.platform)
    print(f"Prepared {args.environment} {args.platform} configuration")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        # Do not include decoder/parser errors that can contain credential data.
        raise SystemExit("Invalid or missing CD configuration; verify Environment settings") from None
