"""Check after a deploy that PostgREST exposes the unified API schemas (#195).

A hosted project's exposed schemas are a dashboard setting that
`supabase db push` does not change, so a new environment can have the
migrations without the API. Each schema is probed read-only with the anon
key by selecting a table that does not exist:

    404 PGRST205  the schema is exposed (the table is just missing)
    406 PGRST106  the schema is not exposed

`GET /rest/v1/` cannot be used: hosted projects answer it only for secret
keys. Any other answer fails too, so a broken probe never passes.

    SUPABASE_URL=... SUPABASE_ANON_KEY=... python3 tool/check_exposed_schemas.py
"""
import json
import os
import sys
import urllib.error
import urllib.request

SCHEMAS = ("api_v1", "admin_v1")
PROBE = "__deploy_probe__"
EXPOSED = (404, "PGRST205")
NOT_EXPOSED = (406, "PGRST106")
HOW_TO_FIX = ("Supabase dashboard → Project Settings → Data API → Exposed schemas: "
              "add {schemas}, save, then re-run this deploy.")


def probe(url, key, schema, opener=urllib.request.urlopen):
    """(HTTP status, PostgREST code or None, message) for one schema."""
    request = urllib.request.Request(
        f"{url.rstrip('/')}/rest/v1/{PROBE}?select=1",
        headers={"apikey": key, "Accept-Profile": schema, "Accept": "application/json"},
    )
    try:
        with opener(request, timeout=30) as response:
            status, body = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read()
    try:
        parsed = json.loads(body or b"null")
    except ValueError:
        parsed = None
    if not isinstance(parsed, dict):
        return status, None, body[:200].decode("utf-8", "replace")
    return status, parsed.get("code"), parsed.get("hint") or parsed.get("message") or ""


def check(url, key, opener=urllib.request.urlopen):
    """Messages for every schema that is not exposed; empty when all are."""
    problems = []
    missing = []
    for schema in SCHEMAS:
        status, code, message = probe(url, key, schema, opener)
        if (status, code) == EXPOSED:
            print(f"{schema}: exposed")
        elif (status, code) == NOT_EXPOSED:
            missing.append(schema)
            problems.append(f"{schema}: not exposed ({message})")
        else:
            problems.append(f"{schema}: unexpected answer {status} {code}: {message}")
    if missing:
        problems.append(HOW_TO_FIX.format(schemas=", ".join(missing)))
    return problems


def main():
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_ANON_KEY")
    if not url or not key:
        print("check_exposed_schemas: SUPABASE_URL and SUPABASE_ANON_KEY are required",
              file=sys.stderr)
        return 2
    problems = check(url, key)
    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
