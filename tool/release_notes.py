"""Keep release hashes recoverable across store upload retries."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def validate_receipt(platform, number, digest):
    extension = "aab" if platform == "android" else "ipa"
    filename = re.escape(f"{platform}-{number}.{extension}")
    if not re.fullmatch(r"[a-f0-9]{64}  " + filename, digest):
        raise ValueError("Invalid binary hash receipt")


def prepare(tag):
    # List rather than interpreting a failed view (network/permission failure)
    # as proof that the release is missing.
    repo = os.environ["GITHUB_REPOSITORY"]
    releases = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"))
    if any(release["tag_name"] == tag for page in releases for release in page):
        return
    # TestFlight and Play testing builds are prereleases; only vX.Y.Z is the
    # store release GitHub marks as latest.
    channel = ["--prerelease"] if "-" in tag else []
    gh("release", "create", tag, "--draft", "--verify-tag", "--generate-notes", "--title", tag, *channel)


def publish(tag):
    release = json.loads(gh("release", "view", tag, "--json", "body,isDraft"))
    with TemporaryDirectory() as directory:
        digests = []
        for platform, variable in (("android", "ANDROID_BUILD"), ("ios", "IOS_BUILD")):
            number = os.environ[variable]
            if not number.isdigit():
                raise ValueError("Missing selected store build number")
            filename = f"sha256-{platform}-{number}.txt"
            gh("release", "download", tag, "--pattern", filename, "--dir", directory)
            digest = (Path(directory) / filename).read_text().strip()
            validate_receipt(platform, number, digest)
            digests.append(digest)
        # Replace our own block on retry; preserve GitHub's generated notes.
        body = release["body"].split("\n<!-- cd-binary-hashes -->", 1)[0]
        body += "\n<!-- cd-binary-hashes -->\n\n商店建置 SHA-256：\n\n```text\n" + "\n".join(digests) + "\n```\n"
        notes = Path(directory) / "notes.md"
        notes.write_text(body)
        gh("release", "edit", tag, "--notes-file", str(notes), "--draft=false")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["prepare", "publish"])
    parser.add_argument("tag")
    args = parser.parse_args()
    if not re.fullmatch(r"v\d+\.\d+\.\d+(-(beta|rc)\.[1-9]\d*)?", args.tag):
        raise SystemExit("Expected a vX.Y.Z, vX.Y.Z-beta.N or vX.Y.Z-rc.N tag")
    try:
        prepare(args.tag) if args.mode == "prepare" else publish(args.tag)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from None
