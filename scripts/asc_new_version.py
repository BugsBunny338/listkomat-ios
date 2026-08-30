#!/usr/bin/env python3
"""
Create the App Store version record and push the store copy from fastlane/ —
the release steps that used to be done by hand in the ASC web UI.

Usage:
    python3 scripts/asc_new_version.py             # ensure version + copy exist
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
- Pushes the store copy per locale from fastlane/metadata/<locale>/:

      release_notes.txt -> whatsNew     ) per-version, on appStoreVersionLocalizations
      description.txt   -> description  )
      keywords.txt      -> keywords     )
      subtitle.txt      -> subtitle       product page, on appInfoLocalizations

  A new version inherits its localizations from the previous one, so this is
  normally a PATCH; a locale ASC does not have yet is POSTed. Only fields that
  actually differ are sent, so a re-run prints "already current" and does
  nothing. Length limits are checked locally, because ASC answers an over-long
  value with a generic 409.

WHY SUBTITLE IS SEPARATE
------------------------
Subtitle (and the app name) hang off `appInfo`, not off a version — they are the
product page, not the release. An app carries several appInfos at once: the live
one plus one per in-flight submission, and only an editable one may be written.
So while a release is in review there is nothing to write and the subtitle step
is skipped with a note rather than failing the release.

This gap is why cs drifted: until 2.5 nothing here pushed anything but
release notes, so a subtitle/keyword edit made in the web UI was never mirrored
back into fastlane/, and fastlane/ was never pushed out. The files are the
source of truth now — edit them, not the web UI.

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

# Per-version copy: lives on appStoreVersionLocalizations, changes per release.
VERSION_FIELDS = {"whatsNew": "release_notes",
                  "description": "description",
                  "keywords": "keywords"}
# Product-page copy: lives on appInfoLocalizations, independent of any version.
APP_INFO_FIELDS = {"subtitle": "subtitle"}
# ASC rejects over-long values with a generic 409, so check locally first.
LIMITS = {"subtitle": 30, "keywords": 100, "description": 4000, "whatsNew": 4000}


def marketing_version():
    """MARKETING_VERSION from project.yml, which generates Info.plist."""
    with open(os.path.join(ROOT, "project.yml")) as f:
        m = re.search(r'^\s*MARKETING_VERSION:\s*"?([0-9][0-9.]*)"?\s*$', f.read(), re.M)
    if not m:
        asc.die("could not read MARKETING_VERSION from project.yml")
    return m.group(1)


def metadata():
    """{asc_locale: {asc_attribute: text}} from fastlane/metadata/<locale>/.

    Directory names are already ASC locale codes (cs, en-US), so no mapping.
    Only release_notes.txt is required; the rest are synced when present, so a
    locale that has never had a description simply doesn't get one pushed.
    """
    base = os.path.join(ROOT, "fastlane", "metadata")
    found = {}
    for locale in sorted(os.listdir(base)):
        if not os.path.isdir(os.path.join(base, locale)):
            continue
        fields = {}
        for attribute, filename in {**VERSION_FIELDS, **APP_INFO_FIELDS}.items():
            path = os.path.join(base, locale, f"{filename}.txt")
            if not os.path.isfile(path):
                continue
            with open(path) as f:
                text = f.read().strip()
            if not text:
                if attribute == "whatsNew":
                    asc.die(f"{path} is empty — App Store updates require release notes")
                continue
            limit = LIMITS.get(attribute)
            if limit and len(text) > limit:
                asc.die(f"{path}: {attribute} is {len(text)} chars, ASC allows {limit}")
            if attribute == "keywords" and ", " in text:
                asc.die(f"{path}: drop the spaces after commas — they eat the 100-char budget")
            fields[attribute] = text
        if "whatsNew" not in fields:
            continue
        found[locale] = fields
    if not found:
        asc.die("no release_notes.txt found under fastlane/metadata/*/")
    return found


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


def _changed(current, wanted):
    """Only the fields ASC does not already hold, so a re-run is a no-op."""
    return {k: v for k, v in wanted.items() if (current.get(k) or "").strip() != v}


def set_version_copy(ver_id, meta, dry):
    """What's New, description and keywords — the per-version copy."""
    fields = ",".join(["locale"] + list(VERSION_FIELDS))
    s, r = asc.call("GET", f"/v1/appStoreVersions/{ver_id}/appStoreVersionLocalizations"
                           f"?limit=50&fields[appStoreVersionLocalizations]={fields}")
    if s != 200:
        asc.die("could not list version localizations", r)
    existing = {d["attributes"]["locale"]: (d["id"], d["attributes"]) for d in r.get("data", [])}

    for locale, all_fields in meta.items():
        wanted = {k: v for k, v in all_fields.items() if k in VERSION_FIELDS}
        if locale in existing:
            loc_id, current = existing[locale]
            delta = _changed(current, wanted)
            if not delta:
                print(f"   {locale}: version copy already current")
                continue
            print(f"-> {locale}: setting {', '.join(f'{k} ({len(v)} chars)' for k, v in delta.items())}")
            if dry:
                continue
            s, r = asc.call("PATCH", f"/v1/appStoreVersionLocalizations/{loc_id}",
                            {"data": {"type": "appStoreVersionLocalizations", "id": loc_id,
                                      "attributes": delta}})
        else:
            print(f"-> {locale}: creating localization with {', '.join(wanted)}")
            if dry:
                continue
            s, r = asc.call("POST", "/v1/appStoreVersionLocalizations",
                            {"data": {"type": "appStoreVersionLocalizations",
                                      "attributes": {"locale": locale, **wanted},
                                      "relationships": {"appStoreVersion": {"data": {
                                          "type": "appStoreVersions", "id": ver_id}}}}})
        if s not in (200, 201):
            asc.die(f"failed to set version copy for {locale}", r)
        print("   ok")


def set_app_info_copy(meta, dry, force):
    """Subtitle — product-page copy, which hangs off appInfo, not the version.

    An app carries several appInfos at once: the live one (READY_FOR_SALE) plus
    one per in-flight submission. Only an editable one may be written, so while
    a release sits in review there is nothing to write and this is skipped
    rather than failed — the version copy above is the release-blocking part.
    """
    wanted_by_locale = {loc: {k: v for k, v in f.items() if k in APP_INFO_FIELDS}
                        for loc, f in meta.items()}
    wanted_by_locale = {k: v for k, v in wanted_by_locale.items() if v}
    if not wanted_by_locale:
        return

    s, r = asc.call("GET", f"/v1/apps/{asc.APP_ID}/appInfos?limit=10")
    if s != 200:
        asc.die("could not list appInfos", r)
    editable = [d for d in r.get("data", [])
                if d["attributes"].get("appStoreState") in SAFE_TO_EDIT]
    if not editable:
        states = ", ".join(sorted({d["attributes"].get("appStoreState") or "?"
                                   for d in r.get("data", [])}))
        print(f"   subtitle: no editable appInfo (states: {states}) — skipping")
        if not force:
            print("      product-page copy is only editable between submissions;")
            print("      re-run after this release is approved.")
        return
    info_id = editable[0]["id"]

    fields = ",".join(["locale"] + list(APP_INFO_FIELDS))
    s, r = asc.call("GET", f"/v1/appInfos/{info_id}/appInfoLocalizations"
                           f"?limit=50&fields[appInfoLocalizations]={fields}")
    if s != 200:
        asc.die("could not list appInfo localizations", r)
    existing = {d["attributes"]["locale"]: (d["id"], d["attributes"]) for d in r.get("data", [])}

    for locale, wanted in wanted_by_locale.items():
        if locale not in existing:
            print(f"   subtitle[{locale}]: locale not on appInfo {info_id} — skipping")
            continue
        loc_id, current = existing[locale]
        delta = _changed(current, wanted)
        if not delta:
            print(f"   {locale}: product-page copy already current")
            continue
        print(f"-> {locale}: setting {', '.join(f'{k} ({len(v)} chars)' for k, v in delta.items())}")
        if dry:
            continue
        s, r = asc.call("PATCH", f"/v1/appInfoLocalizations/{loc_id}",
                        {"data": {"type": "appInfoLocalizations", "id": loc_id,
                                  "attributes": delta}})
        if s not in (200, 201):
            asc.die(f"failed to set product-page copy for {locale}", r)
        print("   ok")


def main():
    dry = "--dry-run" in sys.argv
    force = "--force" in sys.argv

    version = marketing_version()
    meta = metadata()
    print(f"App {asc.APP_ID}")
    print(f"  project.yml MARKETING_VERSION: {version}")
    for locale, fields in meta.items():
        print(f"  {locale}: " + ", ".join(f"{k} ({len(v)} chars)" for k, v in fields.items()))

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

    set_version_copy(ver_id, meta, dry)
    set_app_info_copy(meta, dry, force)
    if dry:
        print("\n(dry run — no changes made)")
    else:
        print(f"\nversion {version} ready: {ver_id}")


if __name__ == "__main__":
    main()
