"""Sample official parking availability sources and summarize their coverage for docs/availability-coverage.md.

Two steps, so the slow, rate-limited downloads are separate from the analysis:

  fetch   download TDX parking endpoints and city open data into a raw directory (one sub-directory per round)
  analyze read every round back and print a JSON summary: totals, motorcycle / heavy motorcycle field shares,
          special values, timestamp ages, duplicates, coordinate quality and round-to-round changes

TDX allows 5 requests per minute per key, so requests are spaced TDX_INTERVAL seconds apart and a 429 waits for
Retry-After. Credentials come from the environment or the gitignored Edge Function env file and are sent only to
the token endpoint; nothing written to disk or stdout contains them. Raw responses belong in a scratch directory
outside version control.
"""
import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import re
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TDX_TOKEN = "https://tdx.transportdata.tw/auth/realms/TDXConnect/protocol/openid-connect/token"
TDX_BASE = "https://tdx.transportdata.tw/api/basic/v1/Parking/"
TDX_PAGE = 5000
TDX_INTERVAL = 13  # seconds; 5 requests per minute per key
TDX_STATIC = ["OffStreet/CarPark", "OffStreet/ParkingSpace", "OnStreet/ParkingSegment", "OnStreet/ParkingSegmentSpace",
              "OnStreet/ParkingSpot"]
TDX_DYNAMIC = ["OffStreet/ParkingAvailability", "OnStreet/ParkingSegmentAvailability", "OnStreet/ParkingSpotAvailability"]
CITIES = ["Taipei", "NewTaipei", "Taichung", "Taoyuan", "Kaohsiung", "Tainan", "Hsinchu", "TaitungCounty"]

# TDX SpaceType codes (Swagger, 停車資訊 v1): 2 機車位, 3 重型機車位, 10 身心障礙機車車位, 12 電動機車車位,
# 14/16/18/20/22 月／季／半年／年租、租賃機車位. Only 2 and 3 describe spaces a rider can use on the spot.
SCOOTER, HEAVY = 2, 3
RENTAL_SCOOTER = {14, 16, 18, 20, 22}
TAIWAN = timezone(timedelta(hours=8))
# No-data codes: TDX "-1: 未知/以現場為主(含非營業時段)"; Taipei and New Taipei use -9 ("尚無提供即時車位").
UNKNOWN_AVAILABLE = {-1, -9}

# City-run sources listed in docs/PLAN.md (second layer). No credentials; fetched once per round.
CITY_SOURCES = {
    "taipei_alldesc": "https://tcgbusfs.blob.core.windows.net/blobtcmsv/TCMSV_alldesc.json",
    "taipei_allavailable_json": "https://tcgbusfs.blob.core.windows.net/blobtcmsv/TCMSV_allavailable.json",
    "taipei_allavailable_xml": "https://tcgbusfs.blob.core.windows.net/blobtcmsv/TCMSV_allavailable.xml",
    "newtaipei_offstreet": "https://data.ntpc.gov.tw/api/datasets/b1464ef0-9c7c-4a6f-abf7-6bdf32847e68/json?page={page}&size=1000",
    "newtaipei_available": "https://data.ntpc.gov.tw/api/datasets/e09b35a5-a738-48cc-b0f5-570b67ad9c78/json?page={page}&size=1000",
    "taichung_offstreet": "https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=4f9c4d26-d826-4277-8f8a-6d2469fe9653",
    "taichung_onstreet": "https://newdatacenter.taichung.gov.tw/api/v1/no-auth/resource.download?rid=1744bc00-cd16-48f3-9632-309f364662bb",
    "taoyuan_offstreet": "https://opendata.tycg.gov.tw/api/dataset/f4cc0b12-86ac-40f9-8745-885bddc18f79/resource/0daad6e6-0632-44f5-bd25-5e1de1e9146f/download",
    "taoyuan_rate": "https://opendata.tycg.gov.tw/api/dataset/d8a0dbc5-42fc-49ba-a280-1700ff78427a/resource/552ed03e-8daf-4b5f-8c6a-b466d378833b/download",
    "kaohsiung_public": "https://openapi.kcg.gov.tw/Api/Service/Get/30c58c88-4f53-45a0-8393-e655feaaa65b",
    "tainan_parkweb": "https://parkweb.tainan.gov.tw/api/parking.php",
    "tainan_parkweb_mode0": "https://parkweb.tainan.gov.tw/api/parking.php?mode=0",
    "hsinchu_hispark": "https://hispark.hccg.gov.tw/OpenData/GetParkInfo",
}
SECRET_PARAMS = re.compile(r"(?i)^(client_id|client_secret|access_token|token|key|apikey|api_key|authorization)$")


def safe_url(url):
    """The URL with credential-like query parameters removed, for anything written to disk or printed."""
    parts = urllib.parse.urlsplit(url)
    query = [(k, v) for k, v in urllib.parse.parse_qsl(parts.query, keep_blank_values=True) if not SECRET_PARAMS.match(k)]
    return urllib.parse.urlunsplit(parts._replace(query=urllib.parse.urlencode(query, safe="$,")))


def credentials(env_file):
    """Environment first, then the env file; values are returned, never printed."""
    values = {}
    if env_file and Path(env_file).exists():
        for line in Path(env_file).read_text().splitlines():
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip('"')
    pick = lambda key: os.environ.get(key) or values.get(key)
    client_id, secret = pick("TDX_CLIENT_ID"), pick("TDX_CLIENT_SECRET")
    return (client_id, secret) if client_id and secret else None


def rows_of(wrapper):
    """TDX v1 wraps rows ({"UpdateTime": …, "ParkingAvailabilities": [...]}); older or other sources return a list."""
    if isinstance(wrapper, list):
        return wrapper
    if isinstance(wrapper, dict):
        return next((v for v in wrapper.values() if isinstance(v, list)), [])
    return []


def tdx_url(kind, city, skip):
    return f"{TDX_BASE}{kind}/City/{city}?$format=JSON&$top={TDX_PAGE}&$skip={skip}"


class Throttle:
    def __init__(self, interval, sleep=time.sleep, clock=time.monotonic):
        self.interval, self.sleep, self.clock, self.last = interval, sleep, clock, None

    def wait(self):
        if self.last is not None:
            remaining = self.interval - (self.clock() - self.last)
            if remaining > 0:
                self.sleep(remaining)
        self.last = self.clock()


def tdx_get(url, token, throttle, opener=urllib.request.urlopen):
    """(status, body or None, elapsed seconds); retries 429 after Retry-After."""
    for attempt in range(4):
        throttle.wait()
        started = time.monotonic()
        try:
            with opener(urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept-Encoding": "identity"}),
                        timeout=120) as response:
                return response.status, json.loads(response.read()), time.monotonic() - started
        except urllib.error.HTTPError as error:
            if error.code == 429 and attempt < 3:
                time.sleep(int(error.headers.get("Retry-After") or 60))
                continue
            return error.code, None, time.monotonic() - started
        except (OSError, ValueError) as error:
            return type(error).__name__, None, time.monotonic() - started
    return 429, None, 0.0


def fetch_tdx(out, cities, kinds, env_file, log=print):
    creds = credentials(env_file)
    if not creds:
        raise SystemExit("TDX_CLIENT_ID / TDX_CLIENT_SECRET not set")
    body = urllib.parse.urlencode({"grant_type": "client_credentials", "client_id": creds[0], "client_secret": creds[1]}).encode()
    with urllib.request.urlopen(urllib.request.Request(TDX_TOKEN, data=body), timeout=30) as response:
        token = json.loads(response.read())["access_token"]
    throttle = Throttle(TDX_INTERVAL)
    (out / "tdx").mkdir(parents=True, exist_ok=True)
    for city in cities:
        for kind in kinds:
            pages, meta, skip = [], [], 0
            while True:
                url = tdx_url(kind, city, skip)
                fetched = datetime.now(timezone.utc).isoformat()
                status, data, elapsed = tdx_get(url, token, throttle)
                meta.append({"url": safe_url(url), "status": status, "fetched_at": fetched, "elapsed_s": round(elapsed, 2)})
                if data is None:
                    break
                pages.append(data)
                if len(rows_of(data)) < TDX_PAGE:
                    break
                skip += TDX_PAGE
            rows = sum(len(rows_of(p)) for p in pages)
            log(f"{city} {kind}: HTTP {meta[-1]['status']} rows={rows}")
            path = out / "tdx" / f"{city}__{kind.replace('/', '_')}.json"
            path.write_text(json.dumps({"meta": meta, "pages": pages}, ensure_ascii=False))


def city_get(url, opener=urllib.request.urlopen):
    """(body, status); a URL with {page} is fetched page by page (JSON arrays) until a page comes back empty."""
    pages, page = [], 0
    while True:
        try:
            with opener(urllib.request.Request(url.format(page=page), headers={"User-Agent": "availability-audit"}), timeout=120) as response:
                raw, status = response.read(), response.status
        except urllib.error.HTTPError as error:
            return b"", error.code
        except OSError as error:
            return b"", type(error).__name__
        if "{page}" not in url:
            return raw, status
        rows = json.loads(raw.decode("utf-8-sig"))
        if not rows or page >= 50:
            return json.dumps(pages, ensure_ascii=False).encode(), status
        pages += rows
        page += 1


def prefer_ipv4():
    """Try IPv4 addresses first: some city hosts publish AAAA records that never answer, and urllib waits out the full
    timeout on each before falling back."""
    import socket
    original = socket.getaddrinfo

    def ordered(*args, **kwargs):
        return sorted(original(*args, **kwargs), key=lambda info: info[0] != socket.AF_INET)

    socket.getaddrinfo = ordered


def fetch_city(out, names=None, log=print):
    (out / "city").mkdir(parents=True, exist_ok=True)
    for name, url in CITY_SOURCES.items():
        if names and name not in names:
            continue
        fetched = datetime.now(timezone.utc).isoformat()
        started = time.monotonic()
        raw, status = city_get(url)
        meta = {"url": safe_url(url), "status": status, "fetched_at": fetched, "elapsed_s": round(time.monotonic() - started, 2)}
        (out / "city" / f"{name}.raw").write_bytes(raw)
        (out / "city" / f"{name}.meta.json").write_text(json.dumps(meta))
        log(f"{name}: {status} {len(raw)} bytes")


# ---------- analysis helpers (pure; covered by test_availability_audit.py) ----------

def parse_time(value):
    """ISO 8601 with offset, or the 'YYYY-MM-DD HH:MM:SS' / 'YYYY/MM/DD HH:MM:SS' local (UTC+8) forms city data uses."""
    if not value or not isinstance(value, str):
        return None
    text = value.strip().replace("/", "-")
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=TAIWAN)


def age_minutes(collected, fetched):
    a, b = parse_time(collected), parse_time(fetched)
    return None if a is None or b is None else (b - a).total_seconds() / 60


def age_buckets(ages):
    """Counts per freshness bucket in minutes; negative ages (future timestamps) are their own bucket."""
    edges = [(0, 3, "0-3"), (3, 10, "3-10"), (10, 30, "10-30"), (30, 60, "30-60"), (60, 1440, "1h-1d"), (1440, math.inf, ">1d")]
    counts = Counter()
    for age in ages:
        if age is None:
            counts["missing"] += 1
        elif age < -1:
            counts["future"] += 1
        else:
            counts[next(label for lo, hi, label in edges if max(age, 0) < hi)] += 1
    return dict(counts)


def summarize_ages(ages):
    valid = sorted(a for a in ages if a is not None)
    if not valid:
        return {"n": 0}
    return {"n": len(valid), "min": round(valid[0], 1), "median": round(statistics.median(valid), 1),
            "p90": round(valid[int(0.9 * (len(valid) - 1))], 1), "max": round(valid[-1], 1), "buckets": age_buckets(ages)}


def space_entry(entries, space_type):
    return next((e for e in entries or [] if e.get("SpaceType") == space_type), None)


def type_sum_mismatch(row):
    """True when every per-type AvailableSpaces is 0 although the row's AvailableSpaces is positive.

    New Taipei's on-street feed fills every per-type count with 0 while the segment total is positive, so a 0 there is a
    placeholder, not "full". A row total that merely differs from the per-type sum is not flagged: Taipei's row total
    counts cars only while its per-type list also carries motorcycles."""
    total, entries = row.get("AvailableSpaces"), row.get("Availabilities") or []
    counts = [e.get("AvailableSpaces") for e in entries]
    return isinstance(total, int) and total > 0 and bool(counts) and all(c == 0 for c in counts)


def classify_available(total, available):
    """Plan §2 semantics for one count: unknown / invalid / full / free."""
    if available is None:
        return "missing"
    if available < 0:
        return "unknown" if available in UNKNOWN_AVAILABLE else "invalid"
    if total is not None and total >= 0 and available > total:
        return "invalid"
    return "full" if available == 0 else "free"


def coordinate_quality(lat, lon):
    """ok / missing / zero / outside (not within Taiwan, Penghu, Kinmen, Matsu bounds)."""
    if lat in (None, "") or lon in (None, ""):
        return "missing"
    try:
        lat, lon = float(lat), float(lon)
    except (TypeError, ValueError):
        return "missing"
    if lat == 0 and lon == 0:
        return "zero"
    return "ok" if 21.8 <= lat <= 26.5 and 118.0 <= lon <= 122.1 else "outside"


def duplicates(ids):
    counts = Counter(i for i in ids if i not in (None, ""))
    return {"distinct": len(counts), "duplicated_ids": sum(1 for c in counts.values() if c > 1)}


def changes(previous, current, jump_ratio=0.5, min_jump=20):
    """Compare two rounds of {id: (collected_at, available, total)}: same time with other value, time going back, large jumps."""
    result = Counter()
    for key, (time_now, avail_now, total_now) in current.items():
        if key not in previous:
            continue
        time_before, avail_before, _ = previous[key]
        result["compared"] += 1
        t0, t1 = parse_time(time_before), parse_time(time_now)
        if t0 and t1:
            if t1 < t0:
                result["time_regressed"] += 1
            elif t1 == t0:
                result["time_unchanged"] += 1
                if avail_now != avail_before:
                    result["value_changed_same_time"] += 1
            else:
                result["time_advanced"] += 1
        if isinstance(avail_now, int) and isinstance(avail_before, int) and avail_now >= 0 and avail_before >= 0:
            if avail_now != avail_before:
                result["value_changed"] += 1
            delta = abs(avail_now - avail_before)
            if delta >= min_jump and total_now and delta >= jump_ratio * total_now:
                result["large_jump"] += 1
    return dict(result)


def persistent_zero(snapshots):
    """IDs with spaces whose count is 0 in every round: genuinely full all along, or a placeholder for missing data."""
    if len(snapshots) < 2:
        return {}
    common = set.intersection(*(set(snap) for snap in snapshots))
    with_capacity = [key for key in common if all((snap[key][2] or 0) > 0 for snap in snapshots)]
    zero = [key for key in with_capacity if all(snap[key][1] == 0 for snap in snapshots)]
    changed = [key for key in with_capacity if len({snap[key][1] for snap in snapshots}) > 1]
    return {"rounds": len(snapshots), "with_capacity": len(with_capacity), "always_zero": len(zero), "value_changed": len(changed)}


# ---------- per-source analysis ----------

def load_tdx(path):
    data = json.loads(path.read_text())
    pages = data["pages"]
    rows = [r for p in pages for r in rows_of(p)]
    head = pages[0] if pages and isinstance(pages[0], dict) else {}
    meta = data["meta"]
    return rows, {k: head.get(k) for k in ("UpdateTime", "UpdateInterval", "SrcUpdateTime", "SrcUpdateInterval")}, meta


def tdx_offstreet_availability(rows, fetched):
    out = Counter()
    ages, scooter_states, heavy_states, service, snapshot = [], Counter(), Counter(), Counter(), {}
    capacity_states = {"scooter": Counter(), "heavy": Counter()}
    for row in rows:
        out["rows"] += 1
        ages.append(age_minutes(row.get("DataCollectTime"), fetched))
        service[row.get("ServiceStatus")] += 1
        entries = row.get("Availabilities") or []
        if not entries:
            out["no_availabilities_array"] += 1
        mismatch = type_sum_mismatch(row)
        out["type_sum_mismatch"] += mismatch
        scooter, heavy = space_entry(entries, SCOOTER), space_entry(entries, HEAVY)
        if scooter and mismatch:
            out["scooter_entry_in_mismatch_row"] += 1
        if scooter:
            out["has_scooter_entry"] += 1
            scooter_states[classify_available(scooter.get("NumberOfSpaces"), scooter.get("AvailableSpaces"))] += 1
            if (scooter.get("NumberOfSpaces") or 0) > 0:
                capacity_states["scooter"]["mismatch_row" if mismatch else classify_available(scooter.get("NumberOfSpaces"), scooter.get("AvailableSpaces"))] += 1
            snapshot[row.get("CarParkID")] = (row.get("DataCollectTime"), scooter.get("AvailableSpaces"), scooter.get("NumberOfSpaces"))
        if heavy:
            out["has_heavy_entry"] += 1
            heavy_states[classify_available(heavy.get("NumberOfSpaces"), heavy.get("AvailableSpaces"))] += 1
            if (heavy.get("NumberOfSpaces") or 0) > 0:
                capacity_states["heavy"]["mismatch_row" if mismatch else classify_available(heavy.get("NumberOfSpaces"), heavy.get("AvailableSpaces"))] += 1
        if any(e.get("SpaceType") in RENTAL_SCOOTER for e in entries):
            out["has_rental_scooter_entry"] += 1
        if row.get("AreaAvailabilities"):
            out["has_area_availabilities"] += 1
    return {"counts": dict(out), "scooter_states": dict(scooter_states), "heavy_states": dict(heavy_states),
            "states_where_capacity_gt0": {k: dict(v) for k, v in capacity_states.items()},
            "service_status": {str(k): v for k, v in service.items()}, "ages": summarize_ages(ages),
            "ids": duplicates([r.get("CarParkID") for r in rows])}, snapshot


def tdx_segment_availability(rows, fetched):
    out = Counter()
    ages, scooter_states, heavy_states, service, snapshot = [], Counter(), Counter(), Counter(), {}
    capacity_states = {"scooter": Counter(), "heavy": Counter()}
    for row in rows:
        out["rows"] += 1
        ages.append(age_minutes(row.get("DataCollectTime"), fetched))
        service[row.get("ServiceStatus")] += 1
        entries = row.get("Availabilities") or []
        mismatch = type_sum_mismatch(row)
        out["type_sum_mismatch"] += mismatch
        scooter, heavy = space_entry(entries, SCOOTER), space_entry(entries, HEAVY)
        if scooter and mismatch:
            out["scooter_entry_in_mismatch_row"] += 1
        if scooter:
            out["has_scooter_entry"] += 1
            scooter_states[classify_available(scooter.get("NumberOfSpaces"), scooter.get("AvailableSpaces"))] += 1
            if (scooter.get("NumberOfSpaces") or 0) > 0:
                capacity_states["scooter"]["mismatch_row" if mismatch else classify_available(scooter.get("NumberOfSpaces"), scooter.get("AvailableSpaces"))] += 1
            snapshot[row.get("ParkingSegmentID")] = (row.get("DataCollectTime"), scooter.get("AvailableSpaces"), scooter.get("NumberOfSpaces"))
        if heavy:
            out["has_heavy_entry"] += 1
            heavy_states[classify_available(heavy.get("NumberOfSpaces"), heavy.get("AvailableSpaces"))] += 1
            if (heavy.get("NumberOfSpaces") or 0) > 0:
                capacity_states["heavy"]["mismatch_row" if mismatch else classify_available(heavy.get("NumberOfSpaces"), heavy.get("AvailableSpaces"))] += 1
    return {"counts": dict(out), "scooter_states": dict(scooter_states), "heavy_states": dict(heavy_states),
            "states_where_capacity_gt0": {k: dict(v) for k, v in capacity_states.items()},
            "service_status": {str(k): v for k, v in service.items()}, "ages": summarize_ages(ages),
            "ids": duplicates([r.get("ParkingSegmentID") for r in rows])}, snapshot


def tdx_spot_availability(rows, fetched):
    status, device, ages = Counter(), Counter(), []
    for row in rows:
        status[row.get("SpotStatus")] += 1
        device[row.get("DeviceStatus")] += 1
        ages.append(age_minutes(row.get("DataCollectTime"), fetched))
    return {"counts": {"rows": len(rows)}, "spot_status": {str(k): v for k, v in status.items()},
            "device_status": {str(k): v for k, v in device.items()}, "ages": summarize_ages(ages),
            "ids": duplicates([r.get("ParkingSpotID") for r in rows])}, {}


def tdx_static(kind, rows):
    out = Counter()
    if kind == "OffStreet/CarPark":
        coords = Counter(coordinate_quality((r.get("CarParkPosition") or {}).get("PositionLat"),
                                            (r.get("CarParkPosition") or {}).get("PositionLon")) for r in rows)
        return {"rows": len(rows), "coords": dict(coords), "ids": duplicates([r.get("CarParkID") for r in rows])}
    if kind in ("OffStreet/ParkingSpace", "OnStreet/ParkingSegmentSpace"):
        for r in rows:
            types = {s.get("SpaceType") for s in (r.get("Spaces") or [])}
            out["rows"] += 1
            out["scooter"] += SCOOTER in types
            out["heavy"] += HEAVY in types
            out["scooter_spaces"] += sum(s.get("NumberOfSpaces") or 0 for s in r.get("Spaces") or [] if s.get("SpaceType") == SCOOTER)
            out["heavy_spaces"] += sum(s.get("NumberOfSpaces") or 0 for s in r.get("Spaces") or [] if s.get("SpaceType") == HEAVY)
        key = "CarParkID" if kind.startswith("OffStreet") else "ParkingSegmentID"
        return dict(out) | {"ids": duplicates([r.get(key) for r in rows])}
    if kind == "OnStreet/ParkingSegment":
        coords = Counter(coordinate_quality((r.get("ParkingSegmentPosition") or {}).get("PositionLat"),
                                            (r.get("ParkingSegmentPosition") or {}).get("PositionLon")) for r in rows)
        geometry = Counter(geometry_kind(r.get("Geometry")) for r in rows)
        return {"rows": len(rows), "coords": dict(coords), "geometry": dict(geometry),
                "ids": duplicates([r.get("ParkingSegmentID") for r in rows])}
    if kind == "OnStreet/ParkingSpot":
        types = Counter(r.get("SpaceType") for r in rows)
        coords = Counter(coordinate_quality((r.get("Position") or {}).get("PositionLat"), (r.get("Position") or {}).get("PositionLon"))
                         for r in rows)
        return {"rows": len(rows), "space_types": {str(k): v for k, v in types.most_common(8)}, "coords": dict(coords),
                "geometry": dict(Counter(geometry_kind(r.get("Geometry")) for r in rows)),
                "ids": duplicates([r.get("ParkingSpotID") for r in rows])}
    return {"rows": len(rows)}


def geometry_kind(value):
    """WKT type of a geometry string ('LINESTRING', 'POLYGON', 'POINT', …) or 'missing'."""
    if not value or not isinstance(value, str):
        return "missing"
    match = re.match(r"\s*([A-Za-z]+)", value)
    return match.group(1).upper() if match else "unparsed"


def analyze_tdx(rounds):
    result, snapshots = {}, {}
    for round_dir in rounds:
        for path in sorted((round_dir / "tdx").glob("*.json")) if (round_dir / "tdx").exists() else []:
            city, kind = path.stem.split("__")
            kind = kind.replace("_", "/", 1)
            rows, wrapper, meta = load_tdx(path)
            fetched = meta[0]["fetched_at"] if meta else None
            entry = {"round": round_dir.name, "http": [m["status"] for m in meta], "elapsed_s": [m["elapsed_s"] for m in meta],
                     "wrapper": wrapper, "wrapper_age_min": age_minutes(wrapper.get("SrcUpdateTime"), fetched)}
            if kind == "OffStreet/ParkingAvailability":
                stats, snap = tdx_offstreet_availability(rows, fetched)
            elif kind == "OnStreet/ParkingSegmentAvailability":
                stats, snap = tdx_segment_availability(rows, fetched)
            elif kind == "OnStreet/ParkingSpotAvailability":
                stats, snap = tdx_spot_availability(rows, fetched)
            else:
                stats, snap = tdx_static(kind, rows), None
            entry["stats"] = stats
            result.setdefault(city, {}).setdefault(kind, []).append(entry)
            if snap is not None:
                snapshots.setdefault((city, kind), []).append(snap)
    for (city, kind), snaps in snapshots.items():
        result[city][kind].append({"changes": [changes(a, b) for a, b in zip(snaps, snaps[1:])], "persistent": persistent_zero(snaps)})
    return result


# ---------- city sources ----------

def num(value):
    """int for numeric strings/ints, else None ('-', '', None stay missing)."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return value
    try:
        return int(float(str(value).strip()))
    except ValueError:
        return None


def xml_rows(raw, tag):
    import xml.etree.ElementTree as ET
    root = ET.fromstring(raw.decode("utf-8-sig").encode())
    return root, [{child.tag: (child.text or "").strip() for child in node} for node in root.iter(tag)]


def parse_taipei_time(text):
    """'Mon Oct 26 15:30:00 CST 2026' (CST here is UTC+8)."""
    try:
        return datetime.strptime(text.replace("CST ", ""), "%a %b %d %H:%M:%S %Y").replace(tzinfo=TAIWAN)
    except (AttributeError, ValueError):
        return None


def lot(id_, lat=None, lon=None, scooter_total=None, scooter_avail=None, heavy_total=None, heavy_avail=None,
        car_avail=None, total=None, avail=None, updated=None, kind=None):
    return {"id": id_, "lat": lat, "lon": lon, "scooter_total": scooter_total, "scooter_avail": scooter_avail,
            "heavy_total": heavy_total, "heavy_avail": heavy_avail, "car_avail": car_avail, "total": total,
            "avail": avail, "updated": updated, "kind": kind}


def city_lots(name, raw, related):
    """(feed_time, [lot]) for one city source; `related` holds the same round's other raw files for joins."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from import_mymaps import tm2_to_wgs84
    if name == "taipei_allavailable_xml" or name == "taipei_allavailable_json":
        if name.endswith("xml"):
            root, parks = xml_rows(raw, "PARK")
            feed = parse_taipei_time(root.findtext("UPDATETIME"))
            parks = [{k.lower(): v for k, v in p.items()} for p in parks]
        else:
            data = json.loads(raw.decode("utf-8-sig"))["data"]
            feed, parks = parse_taipei_time(data.get("UPDATETIME")), data.get("park") or []
        desc = {p["id"]: p for p in json.loads(related["taipei_alldesc"].decode("utf-8-sig"))["data"]["park"]} if "taipei_alldesc" in related else {}
        out = []
        for p in parks:
            d = desc.get(p.get("id"), {})
            coord = ((d.get("EntranceCoord") or {}).get("EntrancecoordInfo") or [{}])[0]
            out.append(lot(p.get("id"), coord.get("Xcod"), coord.get("Ycod"), num(d.get("totalmotor")), num(p.get("availablemotor")),
                           num(d.get("totallargemotor")), num(p.get("availableheavymotor")), num(p.get("availablecar")), kind=d.get("type2")))
        return feed, out
    if name == "taipei_alldesc":
        data = json.loads(raw.decode("utf-8-sig"))["data"]
        return parse_taipei_time(data.get("UPDATETIME")), [
            lot(p["id"], *(((p.get("EntranceCoord") or {}).get("EntrancecoordInfo") or [{}])[0].get(k) for k in ("Xcod", "Ycod")),
                scooter_total=num(p.get("totalmotor")), heavy_total=num(p.get("totallargemotor")), kind=p.get("type2"))
            for p in data["park"]]
    if name == "newtaipei_offstreet":
        out = []
        for p in json.loads(raw):
            x, y = num(p.get("TW97X")), num(p.get("TW97Y"))
            lat, lon = tm2_to_wgs84(x, y) if x and y else (None, None)
            out.append(lot(p["ID"], lat, lon, scooter_total=num(p.get("TOTALMOTOR")), total=num(p.get("TOTALCAR"))))
        return None, out
    if name == "newtaipei_available":
        return None, [lot(p["ID"], car_avail=num(p.get("AVAILABLECAR"))) for p in json.loads(raw)]
    if name == "taichung_offstreet":
        rows = json.loads(raw.decode("utf-8-sig"))
        return None, [lot(p.get("ID"), p.get("Lat"), p.get("Lng"), scooter_total=num(p.get("TotalMotor")),
                          scooter_avail=None, kind=f"lamp:{p.get('AvailableMotorRGB')}") for p in rows]
    if name == "taichung_onstreet":
        rows = json.loads(raw.decode("utf-8-sig"))
        return None, [lot(f"{p.get('Section_ID')}-{p.get('PS_ID')}", p.get("Lat"), p.get("Lng"),
                          kind=f"type:{p.get('PS_type')} status:{p.get('status')}") for p in rows]
    if name == "taoyuan_offstreet":
        root, parks = xml_rows(raw, "parkingLot")
        feed = parse_time(root.attrib.get("updatetime"))
        # The feed swaps the names: wgsX carries latitude and wgsY longitude.
        return feed, [lot(p.get("parkId"), p.get("wgsX"), p.get("wgsY"), total=num(p.get("totalSpace")), avail=num(p.get("surplusSpace")))
                      for p in parks]
    if name == "taoyuan_rate":
        import csv
        import io
        rows = list(csv.DictReader(io.StringIO(raw.decode("utf-8-sig"))))
        return None, [lot(f"{r.get('類別')}|{r.get('場域名稱')}", r.get("緯度"), r.get("經度"), total=num(r.get("總車位數")),
                          avail=num(r.get("剩餘車位數")), kind=r.get("類別")) for r in rows]
    if name == "kaohsiung_public":
        rows = json.loads(raw.decode("utf-8-sig"))["data"]
        return None, [lot(r.get("場名"), r.get("緯度"), r.get("經度"), scooter_total=num(r.get("機車"))) for r in rows]
    if name.startswith("tainan_parkweb"):
        rows = json.loads(raw.decode("utf-8-sig"))
        out = []
        for r in rows:
            lat, _, lon = (r.get("lnglat") or "").replace("，", ",").partition(",")
            out.append(lot(r.get("code") or r.get("id"), lat, lon, scooter_total=num(r.get("moto_total")), scooter_avail=num(r.get("moto")),
                           car_avail=num(r.get("car")), updated=r.get("update_time"), kind=r.get("typeName")))
        return None, out
    if name == "hsinchu_hispark":
        rows = json.loads(raw.decode("utf-8-sig"))
        return None, [lot(r.get("PARKNO"), r.get("LATITUDE"), r.get("LONGITUDE"), scooter_total=num(r.get("TOTALQUANTITYMOT")),
                          scooter_avail=num(r.get("FREEQUANTITYMOT")), car_avail=num(r.get("FREEQUANTITY")), updated=r.get("UPDATETIME"))
                      for r in rows]
    raise KeyError(name)


def city_stats(lots, feed_time, fetched):
    """Counts the coverage document needs for one city source round."""
    scooter_static = [l for l in lots if (l["scooter_total"] or 0) > 0]
    scooter_live = [l for l in lots if l["scooter_avail"] is not None]
    heavy_static = [l for l in lots if (l["heavy_total"] or 0) > 0]
    heavy_live = [l for l in lots if l["heavy_avail"] is not None]
    return {
        "rows": len(lots),
        "ids": duplicates([l["id"] for l in lots]),
        "coords": dict(Counter(coordinate_quality(l["lat"], l["lon"]) for l in lots)),
        "scooter_total_gt0": len(scooter_static),
        "scooter_avail_field": len(scooter_live),
        "scooter_states": dict(Counter(classify_available(l["scooter_total"], l["scooter_avail"]) for l in scooter_live)),
        "scooter_states_where_total_gt0": dict(Counter(classify_available(l["scooter_total"], l["scooter_avail"]) for l in scooter_static)),
        "scooter_avail_values_negative": dict(Counter(l["scooter_avail"] for l in scooter_live if l["scooter_avail"] < 0)),
        "heavy_total_gt0": len(heavy_static),
        "heavy_avail_field": len(heavy_live),
        "heavy_states": dict(Counter(classify_available(l["heavy_total"], l["heavy_avail"]) for l in heavy_live)),
        "heavy_states_where_total_gt0": dict(Counter(classify_available(l["heavy_total"], l["heavy_avail"]) for l in heavy_static)),
        "car_avail_negative": dict(Counter(l["car_avail"] for l in lots if l["car_avail"] is not None and l["car_avail"] < 0)),
        "mixed_avail_states": dict(Counter(classify_available(l["total"], l["avail"]) for l in lots if l["avail"] is not None or l["total"] is not None)),
        "kinds": dict(Counter(l["kind"] for l in lots).most_common(8)),
        "feed_age_min": None if feed_time is None else round((parse_time(fetched) - feed_time).total_seconds() / 60, 1),
        "row_ages": summarize_ages([age_minutes(l["updated"], fetched) for l in lots if l["updated"]]),
    }


def analyze_city(rounds):
    result, snapshots = {}, {}
    for round_dir in rounds:
        city_dir = round_dir / "city"
        if not city_dir.exists():
            continue
        related = {p.stem: p.read_bytes() for p in city_dir.glob("*.raw")}
        for path in sorted(city_dir.glob("*.raw")):
            meta = json.loads(path.with_suffix(".meta.json").read_text())
            entry = {"round": round_dir.name, "http": meta["status"], "elapsed_s": meta["elapsed_s"], "bytes": len(related[path.stem])}
            try:
                feed, lots = city_lots(path.stem, related[path.stem], related)
            except (KeyError, ValueError, TypeError) as error:
                entry["error"] = f"{type(error).__name__}: {error}"[:200]
                result.setdefault(path.stem, []).append(entry)
                continue
            entry["stats"] = city_stats(lots, feed, meta["fetched_at"])
            result.setdefault(path.stem, []).append(entry)
            snapshots.setdefault(path.stem, []).append(
                {l["id"]: (l["updated"], l["scooter_avail"] if l["scooter_avail"] is not None else l["avail"], l["scooter_total"] or l["total"])
                 for l in lots})
    for name, snaps in snapshots.items():
        result[name].append({"changes": [changes(a, b) for a, b in zip(snaps, snaps[1:])], "persistent": persistent_zero(snaps)})
    return result


# ---------- staging ID mapping ----------

CITY_NAMES = {"Taipei": "臺北市", "NewTaipei": "新北市", "Taichung": "臺中市", "Taoyuan": "桃園市", "Kaohsiung": "高雄市",
              "Tainan": "臺南市", "Hsinchu": "新竹市", "TaitungCounty": "臺東縣"}
# City feeds whose IDs are the same strings import_mymaps stores as source_id (others are row ordinals, see the doc).
CITY_FEED_IDS = {"臺北市": ("taipei_allavailable_xml", ""), "新北市": ("newtaipei_available", ""),
                 "臺中市": ("taichung_offstreet", "TXG"), "臺南市": ("tainan_parkweb", "")}


def usable(total, available):
    """A count the UI could show: the lot has spaces of that kind and the value is free or full (not unknown/invalid)."""
    return (total or 0) > 0 and classify_available(total, available) in ("free", "full")


def match_staging(staging, round_dir):
    """Per city: how many staging official spots (source_id) a live feed row can be joined to, and with a usable scooter count."""
    tdx_live = {}
    for path in (round_dir / "tdx").glob("*__OffStreet_ParkingAvailability.json"):
        city = CITY_NAMES.get(path.stem.split("__")[0])
        rows, _, _ = load_tdx(path)
        tdx_live[city] = {r.get("CarParkID"): r for r in rows}
    related = {p.stem: p.read_bytes() for p in (round_dir / "city").glob("*.raw")} if (round_dir / "city").exists() else {}
    city_live = {}
    for city, (name, prefix) in CITY_FEED_IDS.items():
        if name in related:
            _, lots = city_lots(name, related[name], related)
            city_live[city] = {prefix + str(l["id"]): l for l in lots}
    out = {}
    for spot in staging:
        city, source_id = spot.get("city"), spot.get("source_id") or ""
        c = out.setdefault(city, Counter())
        c["spots"] += 1
        raw_id = source_id[4:] if source_id.startswith("TDX-") else source_id
        c["tdx_prefixed"] += source_id.startswith("TDX-")
        tdx_row = tdx_live.get(city, {}).get(raw_id)
        if tdx_row is not None:
            c["in_tdx_availability"] += 1
            scooter = space_entry(tdx_row.get("Availabilities"), SCOOTER)
            heavy = space_entry(tdx_row.get("Availabilities"), HEAVY)
            placeholder = type_sum_mismatch(tdx_row)
            c["tdx_usable_scooter"] += bool(scooter) and not placeholder and usable(scooter.get("NumberOfSpaces"), scooter.get("AvailableSpaces"))
            c["tdx_usable_heavy"] += bool(heavy) and not placeholder and usable(heavy.get("NumberOfSpaces"), heavy.get("AvailableSpaces"))
        feed = city_live.get(city)
        if feed is not None and source_id in feed:
            c["in_city_feed"] += 1
            row = feed[source_id]
            c["city_usable_scooter"] += usable(row["scooter_total"], row["scooter_avail"])
            c["city_usable_heavy"] += usable(row["heavy_total"], row["heavy_avail"])
    return {city: dict(c) for city, c in out.items()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    fetch = sub.add_parser("fetch")
    fetch.add_argument("--out", type=Path, required=True, help="round directory, e.g. scratch/availability-audit/raw/r1")
    fetch.add_argument("--cities", default=",".join(CITIES))
    fetch.add_argument("--kinds", default=",".join(TDX_STATIC + TDX_DYNAMIC), help="TDX kinds; 'none' skips TDX")
    fetch.add_argument("--city-sources", default="all", help="comma list of CITY_SOURCES keys, 'all' or 'none'")
    fetch.add_argument("--tdx-env", type=Path, default=Path("supabase/functions/.env"))
    analyze = sub.add_parser("analyze")
    analyze.add_argument("rounds", type=Path, nargs="+", help="round directories in fetch order")
    analyze.add_argument("--staging", type=Path, help="JSON list of official spots (id, source_id, city) read from staging; joined against the last round")
    args = parser.parse_args(argv)
    if args.command == "fetch":
        prefer_ipv4()
        if args.city_sources != "none":
            fetch_city(args.out, None if args.city_sources == "all" else set(args.city_sources.split(",")))
        if args.kinds != "none":
            fetch_tdx(args.out, args.cities.split(","), args.kinds.split(","), args.tdx_env)
    else:
        summary = {"tdx": analyze_tdx(args.rounds), "city": analyze_city(args.rounds)}
        if args.staging:
            summary["staging_mapping"] = match_staging(json.loads(args.staging.read_text()), args.rounds[-1])
        json.dump(summary, sys.stdout, ensure_ascii=False, indent=1, default=str)


if __name__ == "__main__":
    main()
