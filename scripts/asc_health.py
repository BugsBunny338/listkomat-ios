#!/usr/bin/env python3
"""
Post-release health check — the Xcode Organizer data, without the GUI.

Usage:
    python3 scripts/asc_health.py              # metrics + diagnostics + crashes
    python3 scripts/asc_health.py --probe      # just check which keys can do what
    python3 scripts/asc_health.py --setup      # create the analytics report requests

Run this a day or two after every release (see docs/release-checklist.md).

TWO KEYS, DELIBERATELY
----------------------
App Store Connect API keys are immutable: "Keys don't expire, but can't be
modified to access more services once created." So the roles are split:

    ASC_KEY_ID            J6LV34D5S8  App Manager  build submission (asc_submit.py)
    ASC_ANALYTICS_KEY_ID  FNJQ483TF7  Admin        analytics reports (this script)

Analytics needs Admin — App Manager and Marketing both return
403 FORBIDDEN_ERROR "The API key in use does not allow this request"
(both tested 2026-08-30; don't waste time re-testing them).

WHAT THIS CAN AND CANNOT SEE
----------------------------
- Power & Performance metrics: Apple only aggregates these above a minimum
  device count, so a small install base legitimately returns `productData: []`.
  Empty is not an error.
- Diagnostic signatures (hangs / disk writes / launches): per build, exact.
- Crash counts: via the Analytics Reports API, which is asynchronous — after
  --setup creates the report requests, Apple takes ~a day to generate the first
  instances. Zero instances on a fresh request means "not ready yet", not "no
  crashes".
- Crash *logs* (symbolicated stacks) have no API at all. Those still need the
  Xcode Organizer GUI.
"""
import gzip, json, os, sys, time, urllib.request, urllib.error
import jwt  # PyJWT

ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "69a6de8d-d1d6-47e3-e053-5b8c7c11a4d1")
APP_ID    = os.environ.get("ASC_APP_ID", "6780662652")  # Lístkomat
SUBMIT_KEY    = os.environ.get("ASC_KEY_ID", "J6LV34D5S8")
ANALYTICS_KEY = os.environ.get("ASC_ANALYTICS_KEY_ID", "FNJQ483TF7")
BASE = "https://api.appstoreconnect.apple.com"
METRICS_ACCEPT = "application/vnd.apple.xcode-metrics+json"


def _key_path(key_id):
    return os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")


def token(key_id):
    now = int(time.time())
    with open(_key_path(key_id)) as f:
        key = f.read()
    return jwt.encode({"iss": ISSUER_ID, "iat": now, "exp": now + 1200,
                       "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def call(method, path, key_id, body=None, accept=None, raw=False):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token(key_id))
    if data:   req.add_header("Content-Type", "application/json")
    if accept: req.add_header("Accept", accept)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, (r.read() if raw else json.loads(r.read() or b"{}"))
    except urllib.error.HTTPError as e:
        payload = e.read().decode()
        try: payload = json.loads(payload)
        except Exception: pass
        return e.code, payload


def _detail(payload):
    try: return payload["errors"][0].get("detail", "")
    except Exception: return str(payload)[:160]


# --------------------------------------------------------------- metrics ----
def metrics():
    print("\n== Power & Performance metrics ==")
    s, r = call("GET", f"/v1/apps/{APP_ID}/perfPowerMetrics?filter[platform]=IOS",
                SUBMIT_KEY, accept=METRICS_ACCEPT)
    if s != 200:
        print(f"  HTTP {s}: {_detail(r)}")
        return
    data = r.get("productData", [])
    if not data:
        print("  no data — below Apple's aggregation threshold (expected at this scale)")
        return
    for prod in data:
        for cat in prod.get("metricCategories", []):
            print(f"  · {cat.get('identifier')}")
            for m in cat.get("metrics", []):
                print(f"      {m.get('identifier')} ({m.get('unit')})")
    ins = r.get("insights") or {}
    for kind in ("regressions", "trendingUp"):
        for i in ins.get(kind, []):
            print(f"  !! {kind}: {i.get('metric')} {i.get('summaryString', '')}")


# ----------------------------------------------------------- diagnostics ----
def diagnostics(limit=3):
    print("\n== Diagnostic signatures ==")
    # This endpoint returns builds unordered and rejects `sort` outright
    # ("The parameter 'sort' can not be used with this request"), so page wide
    # and pick the newest here. Old builds 404 on diagnosticSignatures once
    # Apple stops retaining their diagnostics, which is why order matters.
    s, r = call("GET", f"/v1/apps/{APP_ID}/builds?limit=50", SUBMIT_KEY)
    if s != 200:
        print(f"  cannot list builds: HTTP {s}")
        return
    newest = sorted(r.get("data", []),
                    key=lambda b: b["attributes"].get("uploadedDate") or "",
                    reverse=True)[:limit]
    for b in newest:
        ver = b["attributes"].get("version")
        for dtype in ("HANGS", "DISK_WRITES", "LAUNCHES"):
            s2, r2 = call("GET", f"/v1/builds/{b['id']}/diagnosticSignatures"
                                 f"?filter[diagnosticType]={dtype}&limit=20", SUBMIT_KEY)
            if s2 == 404:
                print(f"     build {ver} {dtype}: no diagnostics retained")
                continue
            if s2 != 200:
                print(f"  build {ver} {dtype}: HTTP {s2}")
                continue
            sigs = r2.get("data", [])
            flag = "  " if not sigs else "!!"
            print(f"  {flag} build {ver} {dtype}: {len(sigs)} signature(s)")
            for d in sigs:
                print(f"       weight={d['attributes'].get('weight')} "
                      f"{d['attributes'].get('signature')}")


# --------------------------------------------------------------- crashes ----
def report_requests():
    """-> ({accessType: id}, None) on success, (None, (status, payload)) on failure."""
    s, r = call("GET", f"/v1/apps/{APP_ID}/analyticsReportRequests?limit=50",
                ANALYTICS_KEY)
    if s != 200:
        return None, (s, r)
    return {x["attributes"]["accessType"]: x["id"] for x in r.get("data", [])}, None


def setup():
    print("\n== Creating analytics report requests ==")
    existing, err = report_requests()
    if err:
        print(f"  HTTP {err[0]}: {_detail(err[1])}")
        return
    for access in ("ONE_TIME_SNAPSHOT", "ONGOING"):
        if access in existing:
            print(f"  {access}: already exists ({existing[access]})")
            continue
        s, r = call("POST", "/v1/analyticsReportRequests", ANALYTICS_KEY, {
            "data": {"type": "analyticsReportRequests",
                     "attributes": {"accessType": access},
                     "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
        ok = s in (200, 201)
        print(f"  {access}: {'created ' + r['data']['id'] if ok else f'HTTP {s} ' + _detail(r)}")
    print("  Apple generates the first instances asynchronously — allow ~a day.")


CRASH_REPORTS = ("App Crashes", "App Crashes Expanded")


def crashes():
    print("\n== Crash counts (Analytics Reports) ==")
    existing, err = report_requests()
    if err:
        s, payload = err
        print(f"  HTTP {s}: {_detail(payload)}")
        if s == 403:
            print("  -> the analytics key lacks Admin access (see module docstring)")
        return
    if not existing:
        print("  no report requests yet — run with --setup")
        return
    for access, rid in sorted(existing.items()):
        s, r = call("GET", f"/v1/analyticsReportRequests/{rid}/reports?limit=200",
                    ANALYTICS_KEY)
        if s != 200:
            print(f"  {access}: HTTP {s}")
            continue
        wanted = [x for x in r.get("data", [])
                  if x["attributes"].get("name") in CRASH_REPORTS]
        print(f"  {access}: {len(r.get('data', []))} report types, "
              f"{len(wanted)} crash-related")
        for rep in wanted:
            _dump(rep["id"], rep["attributes"]["name"])


def _dump(report_id, name, max_instances=3):
    s, r = call("GET", f"/v1/analyticsReports/{report_id}/instances"
                       f"?filter[granularity]=DAILY&limit=10", ANALYTICS_KEY)
    if s != 200:
        print(f"    {name}: instances HTTP {s}")
        return
    insts = r.get("data", [])
    if not insts:
        print(f"    {name}: no instances yet (Apple still generating)")
        return
    print(f"    {name}: {len(insts)} daily instance(s)")
    for inst in insts[:max_instances]:
        date = inst["attributes"].get("processingDate")
        s2, r2 = call("GET", f"/v1/analyticsReportInstances/{inst['id']}/segments",
                      ANALYTICS_KEY)
        if s2 != 200:
            print(f"      {date}: segments HTTP {s2}")
            continue
        for seg in r2.get("data", []):
            url = seg["attributes"].get("url")
            if not url:
                continue
            s3, blob = call("GET", url, ANALYTICS_KEY, raw=True)
            try: text = gzip.decompress(blob).decode()
            except Exception: text = blob.decode(errors="replace")
            rows = [l for l in text.splitlines() if l.strip()]
            print(f"      {date}: {len(rows) - 1} row(s)")
            for line in rows[:10]:
                print("         ", line[:200])


# ----------------------------------------------------------------- probe ----
def probe():
    print("== Key capabilities ==")
    for label, key in (("submit   ", SUBMIT_KEY), ("analytics", ANALYTICS_KEY)):
        if not os.path.exists(_key_path(key)):
            print(f"  {label} {key}: .p8 MISSING at {_key_path(key)}")
            continue
        s, _ = call("GET", "/v1/apps?limit=1", key)
        s2, r2 = call("GET", f"/v1/apps/{APP_ID}/analyticsReportRequests?limit=1", key)
        extra = "" if s2 == 200 else " (" + _detail(r2)[:60] + ")"
        print(f"  {label} {key}: auth HTTP {s}, analytics HTTP {s2}{extra}")


if __name__ == "__main__":
    if "--probe" in sys.argv:
        probe()
    elif "--setup" in sys.argv:
        setup()
    else:
        probe()
        metrics()
        diagnostics()
        crashes()
