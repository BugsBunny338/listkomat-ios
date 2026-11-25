#!/usr/bin/env python3
"""
Attach a processed build to the current App Store version and submit it for
review: the App Store Connect REST steps that `altool` can't do. Lístkomat
(app 6780662652). Sibling of beer-llama-ios/scripts/asc_submit.py, which
hardened the original of this script; it was ported back here after 2.7.

Usage:
    python3 scripts/asc_submit.py                  # newest VALID build of the version + submit
    python3 scripts/asc_submit.py --build 15       # exactly that build (release.sh passes it)
    python3 scripts/asc_submit.py --dry-run        # print current state, change nothing
    python3 scripts/asc_submit.py --notes FILE     # also set App Review notes from FILE
    python3 scripts/asc_submit.py --notes 'text'   # ...or inline text
    python3 scripts/asc_submit.py --resubmit       # allowed to cancel a submission that is with Apple
    python3 scripts/asc_submit.py --help

Any other argument is refused before anything reaches App Store Connect, so a
typo such as --dryrun can never turn into a real submit. (Until 2.7 the script
ignored unknown arguments: `--help` ran a real submit.)

--notes FILE: a relative path is read from the repo root (so it works from any
cwd), then from the cwd. An argument that looks like a path (has a "/" or ends
in .txt) but names no file, or an empty file, stops the script before any call.
Reviewer notes per version live in docs/appstore-review-notes-<version>.txt.

ASKS BEFORE CANCELLING AN IN-REVIEW BUILD
-----------------------------------------
Submitting cancels any open review submission and creates a fresh one. While
the version is WAITING_FOR_REVIEW / IN_REVIEW, or an open submission is with
Apple (WAITING_FOR_REVIEW, IN_REVIEW, COMPLETING), that would pull a build out of
review, so the script stops unless --resubmit is given (house rule: let a
submitted build go through; ask Jiri first). A submission that is not with
Apple (READY_FOR_REVIEW, or UNRESOLVED_ISSUES after a rejection) is replaced
without the flag.

The notes go in the App Store version's "App Review > Notes" field, the only
reviewer-facing message channel the ASC API exposes (there is no API for the
Resolution Center reply thread). Use it to tell the reviewer what changed.

ONLY BUILDS OF THE VERSION BEING SUBMITTED
------------------------------------------
Builds are looked up within the version (filter[preReleaseVersion.version]).
Before 2.7 the script took the newest VALID build of ANY version, attached
2.6's build 14 to 2.7, and Apple refused the submission with a 409.

Prerequisites (one-time):
    - App Store Connect API key (.p8) at ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
    - PyJWT + cryptography (pip install pyjwt cryptography)

The .p8 is the only secret and stays local (never commit it). Key ID and Issuer ID
are not secret. Override any of the constants below via environment variables.

Full release flow: scripts/release.sh (asc_preflight -> asc_new_version ->
archive -> export -> upload -> this script with --build).
"""
import json, os, sys, time, urllib.parse, urllib.request, urllib.error
import jwt  # PyJWT

KEY_ID    = os.environ.get("ASC_KEY_ID", "J6LV34D5S8")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "69a6de8d-d1d6-47e3-e053-5b8c7c11a4d1")
KEY_PATH  = os.environ.get("ASC_KEY_PATH",
                           os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"))
APP_ID    = os.environ.get("ASC_APP_ID", "6780662652")  # Lístkomat
BASE      = "https://api.appstoreconnect.apple.com"
ROOT      = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Version states from which a new build can be attached / a submission created.
EDITABLE = {"PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED",
            "METADATA_REJECTED", "INVALID_BINARY", "WAITING_FOR_REVIEW"}
SUB_CLOSED = {"COMPLETE", "CANCELED"}
# With Apple: cancelling these pulls a build out of review, so it needs --resubmit.
VERSION_IN_REVIEW = {"WAITING_FOR_REVIEW", "IN_REVIEW"}
SUB_WITH_APPLE = {"WAITING_FOR_REVIEW", "IN_REVIEW", "COMPLETING"}

FLAGS = {"-h", "--help", "--dry-run", "--resubmit"}
VALUED_FLAGS = {"--build", "--notes"}
USAGE = ("usage: asc_submit.py [--build <n>] [--notes FILE|TEXT] [--resubmit] [--dry-run] [--help]")

_token_cache = {"value": None, "made": 0.0}


def _token():
    with open(KEY_PATH) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode({"iss": ISSUER_ID, "iat": now, "exp": now + 1200,
                       "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def _bearer():
    """A token made on first use and renewed after 15 min (they live 20), so a
    long wait for build processing doesn't end in a 401, and --help needs no key."""
    if _token_cache["value"] is None or time.time() - _token_cache["made"] > 900:
        _token_cache["value"] = _token()
        _token_cache["made"] = time.time()
    return _token_cache["value"]


def call(method, path, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + _bearer())
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


def version_state(attributes):
    """`appStoreState` is deprecated in favour of `appVersionState`; read either."""
    return attributes.get("appStoreState") or attributes.get("appVersionState")


def latest_version():
    s, r = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?limit=1&include=build")
    if s != 200 or not r.get("data"):
        die("could not fetch app store versions", r)
    v = r["data"][0]
    a = v["attributes"]
    return v["id"], a["versionString"], version_state(a)


def valid_build(version_string, build_number=None):
    """The newest VALID, unexpired build of `version_string`, or exactly `build_number`."""
    query = (f"/v1/builds?filter[app]={APP_ID}"
             f"&filter[preReleaseVersion.version]={urllib.parse.quote(version_string)}"
             "&limit=20&sort=-uploadedDate")
    if build_number:
        query += f"&filter[version]={urllib.parse.quote(build_number)}"
    s, r = call("GET", query)
    if s != 200:
        die("could not fetch builds", r)
    for b in r.get("data", []):
        if b["attributes"]["processingState"] == "VALID" and not b["attributes"].get("expired"):
            return b["id"], b["attributes"]["version"]
    wanted = f"build {build_number}" if build_number else "a VALID (processed, non-expired) build"
    die(f"no {wanted} of version {version_string} — wait for processing or upload one")


def open_submissions():
    s, r = call("GET", f"/v1/apps/{APP_ID}/reviewSubmissions?limit=20")
    if s != 200:
        die("could not fetch review submissions", r)
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
    """A file's text (relative paths from the repo root, then the cwd), or `arg` itself as inline text."""
    candidates = [arg] if os.path.isabs(arg) else [os.path.join(ROOT, arg), arg]
    for path in candidates:
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                text = f.read().strip()
            if not text:
                die(f"--notes file {path} is empty")
            return text
    if "/" in arg or arg.endswith(".txt"):
        die(f"--notes {arg!r} looks like a file, but there is none (looked in {ROOT} and the cwd)")
    return arg


def usage_error(msg):
    print(f"ERROR: {msg}\n{USAGE}")
    sys.exit(2)


def parse_args(argv):
    """{flag: value or True}. Anything unknown stops here, before any App Store Connect call."""
    opts, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if a in VALUED_FLAGS:
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                usage_error(f"{a} needs a value")
            opts[a] = argv[i + 1]
            i += 2
        elif a in FLAGS:
            opts[a] = True
            i += 1
        else:
            usage_error(f"unknown argument {a!r}")
    return opts


def main():
    opts = parse_args(sys.argv[1:])
    if "-h" in opts or "--help" in opts:
        print(__doc__)
        return
    dry = "--dry-run" in opts
    resubmit = "--resubmit" in opts
    notes_arg = opts.get("--notes")
    notes = _read_notes(notes_arg) if notes_arg is not None else None
    build_arg = opts.get("--build")

    ver_id, ver_str, ver_state = latest_version()
    build_id, build_num = valid_build(ver_str, build_arg)
    opens = open_submissions()

    print(f"App {APP_ID}")
    print(f"  version  : {ver_str}  state={ver_state}  id={ver_id}")
    print(f"  build    : {build_num}  id={build_id}")
    print(f"  open subs: {[(s['id'], s['attributes']['state']) for s in opens]}")

    with_apple = [s for s in opens if s["attributes"]["state"] in SUB_WITH_APPLE]
    needs_resubmit = ver_state in VERSION_IN_REVIEW or bool(with_apple)

    if dry:
        if needs_resubmit and not resubmit:
            print("\n(a real run would refuse: a build is with Apple; --resubmit pulls it out of review)")
        print("\n(dry run — no changes made)")
        return

    if ver_state not in EDITABLE:
        die(f"version state {ver_state!r} is not editable; nothing to do")

    if needs_resubmit and not resubmit:
        what = [f"version {ver_str} is {ver_state}"] if ver_state in VERSION_IN_REVIEW else []
        what += [f"submission {s['id']} is {s['attributes']['state']}" for s in with_apple]
        die("refusing to cancel a build that is with Apple (" + "; ".join(what) + "). "
            "House rule: let it go through and ship the change in the next version. "
            "If Jiri wants it pulled and resubmitted, re-run with --resubmit.")

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
        s, r = call("PATCH", f"/v1/reviewSubmissions/{sid}",
                    {"data": {"type": "reviewSubmissions", "id": sid, "attributes": {"canceled": True}}})
        if s != 200:
            die(f"failed to cancel submission {sid}", r)
    if opens:
        for i in range(24):
            still = open_submissions()
            if not still:
                break
            print(f"   waiting for cancel… {[ (s['id'], s['attributes']['state']) for s in still ]}")
            time.sleep(5)
        else:
            die(f"open submissions still not closed after ~2 min: "
                f"{[(s['id'], s['attributes']['state']) for s in still]}; check App Store Connect, then re-run")

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
