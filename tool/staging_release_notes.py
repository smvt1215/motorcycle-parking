#!/usr/bin/env python3
"""Release notes for the staging builds on Firebase App Distribution.

Usage: python3 tool/staging_release_notes.py <output file>

Writes what cd-staging.yml always wrote (`git log -1` with the Alpha label,
the SHA and the subject). When `.github/staging-release-notice.txt` exists
and is not blank, its text follows after one empty line: a notice the
testers should read with this build, such as a privacy policy update
(#475). Without it the notes are byte for byte what they were before.

Firebase documents no length limit for release notes, so the notice is
kept to NOTICE_LIMIT characters: the unit test checks the committed notice
on every PR, and an oversized notice fails the step here rather than
reaching testers cut short.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
NOTICE = ROOT / ".github" / "staging-release-notice.txt"
NOTICE_LIMIT = 1000
HEAD_FORMAT = "Alpha（內部預覽）%n%H%n%s"


def read_notice(path=NOTICE):
    """The notice, trimmed; empty when the file is missing or blank."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""
    return text.strip()


def compose(head, notice):
    if not notice:
        return head
    if len(notice) > NOTICE_LIMIT:
        raise SystemExit(f"{NOTICE.name} has {len(notice)} characters; keep it within {NOTICE_LIMIT}")
    return head.rstrip("\n") + "\n\n" + notice + "\n"


def main(argv):
    if len(argv) != 2:
        raise SystemExit("Usage: python3 tool/staging_release_notes.py <output file>")
    head = subprocess.run(
        ["git", "log", "-1", f"--format={HEAD_FORMAT}"],
        check=True,
        capture_output=True,
        encoding="utf-8",
    ).stdout
    pathlib.Path(argv[1]).write_text(compose(head, read_notice()), encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv)
