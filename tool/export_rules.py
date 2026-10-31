"""Export city_rules from the database into the app's bundled rule file.

The app ships assets/rules/parking_rules.json as its offline fallback and
merges the database rows over it (lib/data/repositories.dart). Rules are
published in the admin web (/rules), so run this before each release:

    python3 tool/export_rules.py                 # write the file from staging
    python3 tool/export_rules.py --check         # fail if the file is behind
    python3 tool/export_rules.py --input rows.json

The database is read with the public anon key through city_rules_v2(), which
returns the stored rows with their end dates; the city_rules view would give
expired rows as the projection older builds read. URL and key come from
SUPABASE_URL / SUPABASE_ANON_KEY, else from --config.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
RULES = ROOT / "assets/rules/parking_rules.json"
CITIES = ["全國", "臺北市", "新北市", "基隆市", "桃園市", "新竹市", "新竹縣", "苗栗縣", "臺中市",
          "彰化縣", "南投縣", "雲林縣", "嘉義市", "嘉義縣", "臺南市", "高雄市", "屏東縣", "宜蘭縣",
          "花蓮縣", "臺東縣", "澎湖縣", "金門縣", "連江縣"]
VEHICLES = ["scooter", "heavy"]
# Builds before the four newer space kinds cannot parse them in a rule.
SPACE_TYPES = {"paidMotorcycle", "freeMotorcycle", "heavyOnly", "car", "offStreet"}
RESTRICTIONS = {None, "pilot_area", "signage", "unverified"}


class RuleError(ValueError):
    pass


def key(rule):
    return (rule["city"], rule["vehicle"])


def normalize(row):
    """One database row in the bundled file's shape and key order."""
    name = f"{row.get('city')}:{row.get('vehicle')}"
    if row.get("city") not in CITIES or row.get("vehicle") not in VEHICLES:
        raise RuleError(f"{name}: unknown city or vehicle")
    types = [*row["allowed_space_types"], *row.get("conditional_space_types", [])]
    types += list(row.get("district_space_types") or {})
    unknown = sorted(set(types) - SPACE_TYPES)
    if unknown:
        raise RuleError(f"{name}: space types older builds cannot read: {', '.join(unknown)}")
    if row.get("restriction") not in RESTRICTIONS:
        raise RuleError(f"{name}: unknown restriction {row.get('restriction')}")
    if not isinstance(row.get("version"), int) or row["version"] < 1:
        raise RuleError(f"{name}: invalid version")
    rule = {
        "city": row["city"],
        "vehicle": row["vehicle"],
        "allowed_space_types": list(row["allowed_space_types"]),
        "conditional_space_types": list(row.get("conditional_space_types", [])),
        "fee_note": row["fee_note"],
        "exceptions": row["exceptions"],
        "effective_date": str(row["effective_date"])[:10],
        "source_url": row["source_url"],
        "version": row["version"],
        "can_use_two_spaces": bool(row.get("can_use_two_spaces", False)),
        "districts": list(row.get("districts", [])),
    }
    # Absent keys read as empty in the app; keep the file free of defaults.
    if row.get("district_space_types"):
        rule["district_space_types"] = {k: list(v) for k, v in row["district_space_types"].items()}
    if row.get("restriction") is not None:
        rule["restriction"] = row["restriction"]
    if row.get("expires_on"):
        rule["expires_on"] = str(row["expires_on"])[:10]
    return rule


def same_rule(a, b):
    """Two rules that say the same thing, whatever their version numbers."""
    def body(rule):
        return {k: v for k, v in normalize({"district_space_types": {}, "restriction": None, **rule}).items()
                if k != "version"}
    return body(a) == body(b)


def export(rows, bundled):
    """The bundled rules replaced by the database rows.

    Existing rows keep their place in the file so a diff shows only what
    changed; new rules follow in city order. A bundled rule missing from the
    database, or newer than it and saying something else, means the two
    diverged the other way: the database must be fixed first, so both raise.
    A newer bundled rule that says the same thing takes the database's lower
    version (the file follows the database, so the app then reads the remote
    row; installed builds keep their own same-content copy).
    """
    current = {key(r): r for r in (normalize(r) for r in rows)}
    if len(current) != len(rows):
        raise RuleError("duplicate city and vehicle in the database rows")
    problems = []
    for old in bundled:
        new = current.get(key(old))
        if new is None:
            problems.append(f"{old['city']}:{old['vehicle']} is in the app file but not in the database")
        elif new["version"] < old["version"] and not same_rule(new, old):
            # An older database version with the same rule only restarted its
            # count (staging was seeded from this file at version 1); one that
            # says something else is a rollback and must be fixed first.
            problems.append(f"{old['city']}:{old['vehicle']} is version {old['version']} in the app file "
                            f"but {new['version']} in the database")
    if problems:
        raise RuleError("; ".join(problems))
    order = [key(r) for r in bundled]
    order += sorted((k for k in current if k not in order),
                    key=lambda k: (CITIES.index(k[0]), VEHICLES.index(k[1])))
    return [current[k] for k in order]


def dumps(rules):
    return json.dumps(rules, ensure_ascii=False, indent=2) + "\n"


def fetch(url, anon_key):
    request = urllib.request.Request(
        f"{url.rstrip('/')}/rest/v1/rpc/city_rules_v2",
        headers={"apikey": anon_key, "Authorization": f"Bearer {anon_key}"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def credentials(config):
    url, anon_key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_ANON_KEY")
    if (not url or not anon_key) and config.exists():
        values = json.loads(config.read_text())
        url, anon_key = url or values.get("SUPABASE_URL"), anon_key or values.get("SUPABASE_ANON_KEY")
    if not url or not anon_key:
        raise RuleError(f"set SUPABASE_URL and SUPABASE_ANON_KEY, or provide {config}")
    return url, anon_key


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input", type=Path, help="city_rules rows as JSON instead of the database")
    parser.add_argument("--config", type=Path, default=ROOT / "config/staging.json")
    parser.add_argument("--output", type=Path, default=RULES)
    parser.add_argument("--check", action="store_true", help="only report whether the file is up to date")
    args = parser.parse_args(argv)
    try:
        rows = json.loads(args.input.read_text()) if args.input else fetch(*credentials(args.config))
        bundled = json.loads(args.output.read_text()) if args.output.exists() else []
        text = dumps(export(rows, bundled))
    except RuleError as error:
        print(f"export_rules: {error}", file=sys.stderr)
        return 2
    current = args.output.read_text() if args.output.exists() else ""
    if args.check:
        if text != current:
            print(f"export_rules: {args.output} differs from the database; run tool/export_rules.py", file=sys.stderr)
            return 1
        return 0
    if text != current:
        args.output.write_text(text)
        print(f"updated {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
