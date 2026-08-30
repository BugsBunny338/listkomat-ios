#!/usr/bin/env python3
"""
Create the App Store version record and upload its "What's New" — the two
release steps that used to be done by hand in the ASC web UI.

Usage:
    python3 scripts/asc_new_version.py             # ensure version + notes exist
    python3 scripts/asc_new_version.py --dry-run   # print the plan, change nothing
    python3 scripts/asc_new_version.py --force     # also edit a version in review

Run this BEFORE archiving (scripts/release.sh does). It is idempotent, so a
re-run after a failed release is safe.

WHY THIS EXISTS
---------------
`asc_submit.py` only ever edits a version that already exists: it reads the
newest one and bails when the state is not in `EDITABLE`. After a release goes
live the newest version is READY_FOR_SALE, so a fresh release used to die with

    version state 'READY_FOR_SALE' is not editable; nothing to do

*after* a full archive + upload had already run (~6 minutes). Nothing created
the next version record. Separately, `fastlane/` here is metadata + screenshots
only — there is no Fastfile and no lanes — so `release_notes.txt` never reached
ASC on its own. Both gaps were invisible until 2.4 (2026-08-30).

WHAT IT DOES
------------
- Reads MARKETING_VERSION from project.yml — the single source of truth.
- Creates the appStoreVersion if missing, with releaseType AFTER_APPROVAL
  (every version 2.0 -> 2.4 has used it; override with ASC_RELEASE_TYPE=MANUAL).
- Sets `whatsNew` per locale from fastlane/metadata/<locale>/release_notes.txt.
  A new version inherits its localizations from the previous one, so this is
  normally a PATCH; a locale ASC does not have yet is POSTed.

REFUSES TO TOUCH A VERSION IN REVIEW
------------------------------------
Editing metadata on a submitted version can bounce it back to the developer,
and the house rule is to never disturb a build that is already in review (see
docs/release-checklist.md). So any state outside SAFE_TO_EDIT stops the script
rather than silently rewriting the notes. `--force` overrides, for the case
where you genuinely mean to fix copy on a version you are about to resubmit.

Prerequisites: same App Store Connect API key as asc_submit.py, whose auth and
`call()` this reuses.
"""
import importlib.util, os, re, sys

_spec = importlib.util.spec_from_file_location(
    "asc_submit", os.path.join(os.path.dirname(os.path.abspath(__file__)), "asc_submit.py"))
asc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(asc)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASE_TYPE = os.environ.get("ASC_RELEASE_TYPE", "AFTER_APPROVAL")

# States where rewriting "What's New" is harmless: nothing is with Apple yet.
# Deliberately EXCLUDES WAITING_FOR_REVIEW and IN_REVIEW, which asc_submit.py's
# own EDITABLE set does include — that set is about attaching a build to a
# submission it is going to cancel and recreate, which is a different question
# from quietly editing reviewer-visible copy.
SAFE_TO_EDIT = {"PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED",
                "METADATA_REJECTED", "INVALID_BINARY"}


def marketing_version():
    """MARKETING_VERSION from project.yml, which generates Info.plist."""
    with open(os.path.join(ROOT, "project.yml")) as f:
        m = re.search(r'^\s*MARKETING_VERSION:\s*"?([0-9][0-9.]*)"?\s*$', f.read(), re.M)
    if not m:
        asc.die("could not read MARKETING_VERSION from project.yml")
    return m.group(1)


def release_notes():
    """{asc_locale: text} from fastlane/metadata/<locale>/release_notes.txt.

    Directory names are already ASC locale codes (cs, en-US), so no mapping.
    """
    base = os.path.join(ROOT, "fastlane", "metadata")
    notes = {}
    for locale in sorted(os.listdir(base)):
        path = os.path.join(base, locale, "release_notes.txt")
        if not os.path.isfile(path):
            continue
        with open(path) as f:
            text = f.read().strip()
        if not text:
            asc.die(f"{path} is empty — App Store updates require release notes")
        notes[locale] = text
    if not notes:
        asc.die("no release_notes.txt found under fastlane/metadata/*/")
    return notes


def find_version(version):
    s, r = asc.call("GET", f"/v1/apps/{asc.APP_ID}/appStoreVersions"
                           "?limit=20&fields[appStoreVersions]=versionString,appStoreState,releaseType")
    if s != 200:
        asc.die("could not list app store versions", r)
    for v in r.get("data", []):
        if v["attributes"]["versionString"] == version:
            return v
    return None


def create_version(version, dry):
    print(f"-> creating version {version} (releaseType={RELEASE_TYPE})")
    if dry:
        return None
    s, r = asc.call("POST", "/v1/appStoreVersions",
                    {"data": {"type": "appStoreVersions",
                              "attributes": {"platform": "IOS", "versionString": version,
                                             "releaseType": RELEASE_TYPE},
                              "relationships": {"app": {"data": {"type": "apps",
                                                                 "id": asc.APP_ID}}}}})
    if s not in (200, 201):
        asc.die(f"failed to create version {version}", r)
    print(f"   created {r['data']['id']}")
    return r["data"]["id"]


def set_whats_new(ver_id, notes, dry):
    s, r = asc.call("GET", f"/v1/appStoreVersions/{ver_id}/appStoreVersionLocalizations"
                           "?limit=50&fields[appStoreVersionLocalizations]=locale,whatsNew")
    if s != 200:
        asc.die("could not list version localizations", r)
    existing = {d["attributes"]["locale"]: (d["id"], d["attributes"].get("whatsNew") or "")
                for d in r.get("data", [])}
    for locale, text in notes.items():
        if locale in existing:
            loc_id, current = existing[locale]
            if current.strip() == text:
                print(f"   whatsNew[{locale}] already current ({len(text)} chars)")
                continue
            print(f"-> setting whatsNew[{locale}] ({len(text)} chars)")
            if dry:
                continue
            s, r = asc.call("PATCH", f"/v1/appStoreVersionLocalizations/{loc_id}",
                            {"data": {"type": "appStoreVersionLocalizations", "id": loc_id,
                                      "attributes": {"whatsNew": text}}})
        else:
            print(f"-> creating localization {locale} with whatsNew ({len(text)} chars)")
            if dry:
                continue
            s, r = asc.call("POST", "/v1/appStoreVersionLocalizations",
                            {"data": {"type": "appStoreVersionLocalizations",
                                      "attributes": {"locale": locale, "whatsNew": text},
                                      "relationships": {"appStoreVersion": {"data": {
                                          "type": "appStoreVersions", "id": ver_id}}}}})
        if s not in (200, 201):
            asc.die(f"failed to set whatsNew for {locale}", r)
        print("   ok")


def main():
    dry = "--dry-run" in sys.argv
    force = "--force" in sys.argv

    version = marketing_version()
    notes = release_notes()
    print(f"App {asc.APP_ID}")
    print(f"  project.yml MARKETING_VERSION: {version}")
    print(f"  release notes: {', '.join(f'{k} ({len(v)} chars)' for k, v in notes.items())}")

    found = find_version(version)
    if found is None:
        ver_id = create_version(version, dry)
        if dry:
            print("\n(dry run — no changes made)")
            return
    else:
        ver_id = found["id"]
        state = found["attributes"].get("appStoreState")
        print(f"  version {version} exists: state={state} "
              f"releaseType={found['attributes'].get('releaseType')} id={ver_id}")
        if state not in SAFE_TO_EDIT and not force:
            print(f"\nRefusing to edit version {version} in state {state}.")
            print("Editing a version that is with Apple can bounce it back to you, and the")
            print("house rule is to let a submitted build go through (docs/release-checklist.md).")
            print("Bump MARKETING_VERSION for the next release, or pass --force if you really")
            print("mean to change this one.")
            sys.exit(2)

    set_whats_new(ver_id, notes, dry)
    if dry:
        print("\n(dry run — no changes made)")
    else:
        print(f"\nversion {version} ready: {ver_id}")


if __name__ == "__main__":
    main()
