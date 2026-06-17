#!/usr/bin/env python3
"""
Attach the latest processed build to the current App Store version and submit it
for review — the App Store Connect REST steps that `altool` can't do.

Usage:
    python3 scripts/asc_submit.py                 # attach latest build + submit
    python3 scripts/asc_submit.py --dry-run       # print current state, change nothing
    python3 scripts/asc_submit.py --notes FILE    # also set App Review notes from FILE
    python3 scripts/asc_submit.py --notes 'text'  # ...or inline text

The notes go in the App Store version's "App Review > Notes" field — the only
reviewer-facing message channel the ASC API exposes (there is no API for the
Resolution Center reply thread). Use it to tell the reviewer what changed.

Prerequisites (one-time):
    - App Store Connect API key (.p8) at ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
    - PyJWT + cryptography (pip install pyjwt cryptography)

The .p8 is the only secret and stays local (never commit it). Key ID and Issuer ID
are not secret. Override any of the constants below via environment variables.

Full release flow (see docs/plans/.../...-design.md "App Store submission log"):
    bump CURRENT_PROJECT_VERSION in project.yml  ->  xcodegen generate
    xcodebuild ... archive  ->  xcodebuild -exportArchive  ->  xcrun altool --upload-app
    python3 scripts/asc_submit.py        # <-- this script
"""
import json, os, sys, time, urllib.request, urllib.error
import jwt  # PyJWT

KEY_ID    = os.environ.get("ASC_KEY_ID", "J6LV34D5S8")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "69a6de8d-d1d6-47e3-e053-5b8c7c11a4d1")
KEY_PATH  = os.environ.get("ASC_KEY_PATH",
                           os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"))
APP_ID    = os.environ.get("ASC_APP_ID", "6780662652")  # Lístkomat
BASE      = "https://api.appstoreconnect.apple.com"

# Version states from which a new build can be attached / a submission created.
EDITABLE = {"PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED",
            "METADATA_REJECTED", "INVALID_BINARY", "WAITING_FOR_REVIEW"}
SUB_CLOSED = {"COMPLETE", "CANCELED"}


def _token():
    with open(KEY_PATH) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode({"iss": ISSUER_ID, "iat": now, "exp": now + 1200,
                       "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


TOK = _token()


def call(method, path, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOK)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw}


def die(msg, payload=None):
    print("ERROR:", msg)
    if payload is not None:
        print(json.dumps(payload, indent=2))
    sys.exit(1)


def latest_version():
    s, r = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?limit=1&include=build")
    if s != 200 or not r.get("data"):
        die("could not fetch app store versions", r)
    v = r["data"][0]
    a = v["attributes"]
    return v["id"], a["versionString"], (a.get("appStoreState") or a.get("appVersionState"))


def latest_valid_build():
    s, r = call("GET", f"/v1/builds?filter[app]={APP_ID}&limit=10&sort=-version")
    if s != 200:
        die("could not fetch builds", r)
    for b in r.get("data", []):
        if b["attributes"]["processingState"] == "VALID" and not b["attributes"].get("expired"):
            return b["id"], b["attributes"]["version"]
    die("no VALID (processed, non-expired) build found — wait for processing or upload one")


def open_submissions():
    s, r = call("GET", f"/v1/apps/{APP_ID}/reviewSubmissions?limit=20")
    return [sub for sub in r.get("data", []) if sub["attributes"]["state"] not in SUB_CLOSED]


def set_notes(ver_id, notes):
    s, r = call("GET", f"/v1/appStoreVersions/{ver_id}/appStoreReviewDetail")
    detail = r.get("data")
    if detail:
        did = detail["id"]
        s, r = call("PATCH", f"/v1/appStoreReviewDetails/{did}",
                    {"data": {"type": "appStoreReviewDetails", "id": did,
                              "attributes": {"notes": notes}}})
    else:  # no review detail yet — create one
        s, r = call("POST", "/v1/appStoreReviewDetails",
                    {"data": {"type": "appStoreReviewDetails", "attributes": {"notes": notes},
                              "relationships": {"appStoreVersion": {"data": {
                                  "type": "appStoreVersions", "id": ver_id}}}}})
    if s not in (200, 201):
        die("failed to set App Review notes", r)


def _read_notes(arg):
    if os.path.isfile(arg):
        with open(arg) as f:
            return f.read().strip()
    return arg


def main():
    dry = "--dry-run" in sys.argv
    notes = None
    if "--notes" in sys.argv:
        i = sys.argv.index("--notes")
        if i + 1 >= len(sys.argv):
            die("--notes needs a file path or text argument")
        notes = _read_notes(sys.argv[i + 1])

    ver_id, ver_str, ver_state = latest_version()
    build_id, build_num = latest_valid_build()
    opens = open_submissions()

    print(f"App {APP_ID}")
    print(f"  version  : {ver_str}  state={ver_state}  id={ver_id}")
    print(f"  build    : {build_num}  id={build_id}")
    print(f"  open subs: {[(s['id'], s['attributes']['state']) for s in opens]}")

    if dry:
        print("\n(dry run — no changes made)")
        return

    if ver_state not in EDITABLE:
        die(f"version state {ver_state!r} is not editable; nothing to do")

    if notes is not None:
        print(f"\n-> setting App Review notes ({len(notes)} chars)")
        set_notes(ver_id, notes)
        print("   ok")

    # 1. attach the build
    print(f"\n-> attaching build {build_num} to version {ver_str}")
    s, r = call("PATCH", f"/v1/appStoreVersions/{ver_id}/relationships/build",
                {"data": {"type": "builds", "id": build_id}})
    if s not in (200, 204):
        die("failed to attach build", r)
    print("   ok")

    # 2. cancel any open submission so the version is free to add to a fresh one
    for sub in opens:
        sid = sub["id"]
        print(f"-> canceling open submission {sid} ({sub['attributes']['state']})")
        call("PATCH", f"/v1/reviewSubmissions/{sid}",
             {"data": {"type": "reviewSubmissions", "id": sid, "attributes": {"canceled": True}}})
    if opens:
        for i in range(24):
            still = open_submissions()
            if not still:
                break
            print(f"   waiting for cancel… {[ (s['id'], s['attributes']['state']) for s in still ]}")
            time.sleep(5)

    # 3. create a fresh submission
    print("-> creating review submission")
    s, r = call("POST", "/v1/reviewSubmissions",
                {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                          "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
    if s not in (200, 201):
        die("failed to create submission", r)
    sub_id = r["data"]["id"]
    print(f"   submission {sub_id}")

    # 4. add the version as an item (retry while a just-canceled sub releases it)
    print("-> adding version as item")
    for i in range(12):
        s, r = call("POST", "/v1/reviewSubmissionItems",
                    {"data": {"type": "reviewSubmissionItems", "relationships": {
                        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": ver_id}}}}})
        if s in (200, 201):
            print("   ok")
            break
        code = (r.get("errors", [{}])[0]).get("code", "")
        print(f"   retry ({s} {code})")
        time.sleep(5)
    else:
        die("failed to add version to submission", r)

    # 5. submit
    print("-> submitting")
    s, r = call("PATCH", f"/v1/reviewSubmissions/{sub_id}",
                {"data": {"type": "reviewSubmissions", "id": sub_id,
                          "attributes": {"submitted": True}}})
    if s != 200:
        die("failed to submit", r)
    state = r["data"]["attributes"]["state"]
    print(f"\nDONE — submission {sub_id} is {state}. Build {build_num} of version {ver_str} is in review.")


if __name__ == "__main__":
    main()
