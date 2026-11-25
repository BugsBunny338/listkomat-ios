#!/usr/bin/env python3
"""
Release preflight: every known App Store blocker, reported at once, before
anything is archived or uploaded. scripts/release.sh runs it first in every
mode; `scripts/release.sh --check` runs only this.

SIBLINGS: listkomat-ios/scripts/asc_preflight.py and
beer-llama-ios/scripts/asc_preflight.py are the same script. Only the block
marked "app-specific" differs; keep the rest identical when changing either.

Usage:
    python3 scripts/asc_preflight.py               # all checks; exit 1 if any is fatal
    python3 scripts/asc_preflight.py --build <n>   # check this build number instead of the default
    python3 scripts/asc_preflight.py --help

Any other argument exits 2 before anything reaches App Store Connect.

Output: one line per check (✓ ok, ! warning, ✗ fatal), then a summary.

THE CHECKS (each one a release that stumbled, 2026-11-25 Lístkomat 2.7)
-------------------------------------------------------------------------
- agreements   After Apple updates an agreement, App Store Connect answers every
               WRITE with 403 FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED,
               while GETs (so every dry run) keep working, for a while even after
               the agreement is accepted. Only a write shows it, so this check
               sends ONE idempotent write: it re-sends one age-rating answer with
               the value it already has (PATCH ageRatingDeclarations/<id>), to an
               editable appInfo or else the live one, never one with Apple.
               Nothing changes; that PATCH is the only write this script makes.
- age rating   Apple adds age-rating questions (2026: socialMedia,
               datingAndRelationships, sharedLocation) and the submission then
               fails with 409 ENTITY_ERROR.ATTRIBUTE.REQUIRED. Every appInfo's
               declaration is read and any unanswered (null) question that is not
               optional is fatal. This script never answers them: Jiri does, in
               App Store Connect -> App Information -> Age Rating.
- signing key  The export cloud-signs with the Admin API key (Xcode's Apple ID
               session expires, and there is no local distribution certificate);
               its .p8 must exist where release.sh looks for it. Also the App
               Manager key the scripts use for the API.
- version      project.yml MARKETING_VERSION must not be a version that is already
               with Apple or live (the bump was done), and no other version may be
               in flight. The build number must not already be uploaded for it.
- notes        fastlane/metadata/<locale>/release_notes.txt non-empty for every
               locale (not needed before an app's first release), and the App
               Review notes file present (a warning only).

Prerequisites: the App Store Connect API key asc_submit.py uses (its call()).
ASC_METADATA_DIR overrides the metadata directory (tests).
"""
import importlib.util, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("asc_submit", os.path.join(HERE, "asc_submit.py"))
asc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(asc)

# ---- app-specific: the only lines that differ between the sibling copies -------------------
APP_NAME = "Lístkomat"
SIGNING_KEY_ENV = "ASC_SIGNING_KEY_ID"        # release.sh's variable for the export (Admin) key
SIGNING_OPT_OUT = None                        # (env var, value) under which release.sh signs without the key
BUILD_FROM_PROJECT = True                     # the build number is project.yml CURRENT_PROJECT_VERSION
BUILD_ENV = None                              # env var that release.sh sets to the build number
REVIEW_NOTES = "docs/appstore-review-notes-{version}.txt"
# ---------------------------------------------------------------------------------------------

ROOT = os.path.dirname(HERE)
PROJECT_YML = os.path.join(ROOT, "project.yml")
METADATA = os.environ.get("ASC_METADATA_DIR", os.path.join(ROOT, "fastlane", "metadata"))
KEY_DIR = os.path.expanduser("~/.appstoreconnect/private_keys")
SIGNING_KEY_DEFAULT = "FNJQ483TF7"

AGREEMENT_CODE = "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED"
AGREEMENT_FIX = ("accept the updated agreement: App Store Connect -> Business "
                 "(and developer.apple.com -> Account)")

# Version states (appStoreState and the newer appVersionState names).
SAFE_TO_EDIT = {"PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED",
                "METADATA_REJECTED", "INVALID_BINARY"}
RELEASED = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION",
            "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"}

# appInfo states: one we may write to, and ones that are with Apple (never probed).
INFO_EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED"}
INFO_WITH_APPLE = {"WAITING_FOR_REVIEW", "IN_REVIEW", "ACCEPTED", "PENDING_RELEASE"}
INFO_RETIRED = {"REPLACED_WITH_NEW_INFO"}

# Age-rating attributes that may stay null.
OPTIONAL_AGE_RATING = {"developerAgeRatingInfoUrl", "gracRatingClassificationNumber", "kidsAgeBand",
                       "ageRatingOverride", "ageRatingOverrideV2", "koreaAgeRatingOverride",
                       # deprecated, superseded by gambling / contests and the age bands
                       "gamblingAndContests", "seventeenPlus"}
# Answers the agreement probe may re-send: plain answers that are never null once the form is filled.
PROBE_ATTRIBUTES = ("advertising", "gambling", "unrestrictedWebAccess", "lootBox", "messagingAndChat",
                    "parentalControls", "userGeneratedContent", "ageAssurance", "healthOrWellnessTopics",
                    "contests", "gamblingSimulated", "profanityOrCrudeHumor")

FLAGS = {"-h", "--help"}
VALUED_FLAGS = {"--build"}
USAGE = "usage: asc_preflight.py [--build <n>] [--help]"


class Report:
    MARKS = {"ok": "✓", "warn": "!", "fatal": "✗"}

    def __init__(self):
        self.rows = []

    def add(self, level, check, text):
        self.rows.append((level, check, text))
        print(f"{self.MARKS[level]} {check:<12} {text}", flush=True)

    def ok(self, check, text): self.add("ok", check, text)
    def warn(self, check, text): self.add("warn", check, text)
    def fatal(self, check, text): self.add("fatal", check, text)

    def count(self, level):
        return sum(1 for row in self.rows if row[0] == level)


def usage_error(msg):
    print(f"ERROR: {msg}\n{USAGE}")
    sys.exit(2)


def parse_args(argv):
    """{flag: value or True}. Anything unknown stops here, before any App Store Connect call."""
    opts, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if a in VALUED_FLAGS:
            if i + 1 >= len(argv) or argv[i + 1].startswith("-"):
                usage_error(f"{a} needs a value")
            opts[a] = argv[i + 1]
            i += 2
        elif a in FLAGS:
            opts[a] = True
            i += 1
        else:
            usage_error(f"unknown argument {a!r}")
    return opts


def _error(r):
    """'STATUS CODE: detail' of the first error in an ASC error payload."""
    errors = (r or {}).get("errors") or [{}]
    e = errors[0]
    return f"{e.get('code', '?')}: {e.get('detail') or e.get('title') or r}"


def _codes(r):
    return {e.get("code") for e in ((r or {}).get("errors") or [])}


def version_key(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def info_state(info):
    """appInfo carries the deprecated `appStoreState` and the newer `state`."""
    return info["attributes"].get("state") or info["attributes"].get("appStoreState")


# --- local checks ------------------------------------------------------------------------------

def project_versions(rep):
    """(MARKETING_VERSION, CURRENT_PROJECT_VERSION) from project.yml; None for one that is missing."""
    try:
        with open(PROJECT_YML, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        rep.fatal("project.yml", f"cannot read {PROJECT_YML}: {e}")
        return None, None
    found = []
    for name in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        m = re.search(rf'^\s*{name}:\s*"?([0-9][0-9.]*)"?\s*$', text, re.M)
        if not m:
            rep.fatal("project.yml", f"no {name} in project.yml")
        found.append(m.group(1) if m else None)
    return tuple(found)


def check_keys(rep):
    """True when the API key is there, so the App Store Connect checks can run."""
    if SIGNING_OPT_OUT and os.environ.get(SIGNING_OPT_OUT[0]) == SIGNING_OPT_OUT[1]:
        rep.warn("signing key", f"{SIGNING_OPT_OUT[0]}={SIGNING_OPT_OUT[1]}: the export signs with "
                                "Xcode's account, which must be signed in (Xcode -> Settings -> Accounts)")
    else:
        key_id = os.environ.get(SIGNING_KEY_ENV) or SIGNING_KEY_DEFAULT
        path = os.path.join(KEY_DIR, f"AuthKey_{key_id}.p8")
        if os.path.isfile(path):
            rep.ok("signing key", f"export (cloud signing) key {key_id} present")
        else:
            rep.fatal("signing key", f"no {path}: the export cloud-signs with the Admin key {key_id} "
                                     f"(set {SIGNING_KEY_ENV} for another one)")
    if os.path.isfile(asc.KEY_PATH):
        rep.ok("api key", f"App Store Connect API key {asc.KEY_ID} present")
        return True
    rep.fatal("api key", f"no {asc.KEY_PATH}: the scripts talk to App Store Connect with it")
    return False


def check_notes(rep, marketing, first_release):
    locales = sorted(d for d in os.listdir(METADATA) if os.path.isdir(os.path.join(METADATA, d))) \
        if os.path.isdir(METADATA) else []
    if not locales:
        rep.fatal("what's new", f"no locales under {METADATA}")
    elif first_release:
        rep.ok("what's new", "not needed: the app has never been released (ASC refuses it on a first version)")
    else:
        missing = []
        for locale in locales:
            path = os.path.join(METADATA, locale, "release_notes.txt")
            try:
                with open(path, encoding="utf-8") as f:
                    if not f.read().strip():
                        missing.append(f"{locale} (empty)")
            except OSError:
                missing.append(f"{locale} (no file)")
        if missing:
            rep.fatal("what's new", "release_notes.txt missing or empty for " + ", ".join(missing)
                      + ": write fresh What's New in fastlane/metadata/<locale>/release_notes.txt")
        else:
            rep.ok("what's new", "release_notes.txt filled for " + ", ".join(locales))
    if marketing:
        rel = REVIEW_NOTES.format(version=marketing)
        path = os.path.join(ROOT, rel)
        try:
            with open(path, encoding="utf-8") as f:
                filled = bool(f.read().strip())
        except OSError:
            filled = None
        if filled:
            rep.ok("review notes", f"{rel} present")
        else:
            rep.warn("review notes", f"{rel} {'is empty' if filled is False else 'missing'} "
                                     "(release.sh sends notes only with ASC_NOTES=<file>)")


# --- App Store Connect checks ------------------------------------------------------------------

def check_version(rep, marketing, versions):
    mine = next((v for v in versions if v["attributes"].get("versionString") == marketing), None)
    if mine is not None:
        state = asc.version_state(mine["attributes"])
        if state in SAFE_TO_EDIT:
            rep.ok("version", f"{marketing} exists on App Store Connect, {state} (editable)")
        else:
            rep.fatal("version", f"{marketing} is already {state} on App Store Connect: bump "
                                 "MARKETING_VERSION in project.yml (and CURRENT_PROJECT_VERSION)")
        return
    if not versions:
        rep.ok("version", f"{marketing} will be created (no App Store version yet)")
        return
    newest = versions[0]["attributes"]
    newest_v, newest_state = newest.get("versionString"), asc.version_state(newest)
    if newest_state not in RELEASED:
        rep.fatal("version", f"{newest_v} is {newest_state}: App Store Connect allows one version in "
                             f"flight, so {marketing} can't be created until {newest_v} is released "
                             f"(or set MARKETING_VERSION back to {newest_v})")
    elif version_key(marketing) <= version_key(newest_v):
        rep.fatal("version", f"project.yml says {marketing}, but {newest_v} is already {newest_state}: "
                             "bump MARKETING_VERSION")
    else:
        rep.ok("version", f"{marketing} will be created (newest is {newest_v}, {newest_state})")


def check_build(rep, marketing, build):
    if not build:
        rep.ok("build", "a fresh UTC timestamp at archive time (pass --build <n> to check one)")
        return
    s, r = asc.call("GET", f"/v1/builds?filter[app]={asc.APP_ID}"
                           f"&filter[preReleaseVersion.version]={marketing}&filter[version]={build}&limit=5")
    if s != 200:
        rep.fatal("build", f"could not list builds: {s} {_error(r)}")
    elif r.get("data"):
        state = r["data"][0]["attributes"].get("processingState")
        rep.fatal("build", f"build {build} of {marketing} is already uploaded ({state}): bump "
                           "CURRENT_PROJECT_VERSION in project.yml" if BUILD_FROM_PROJECT else
                  f"build {build} of {marketing} is already uploaded ({state})")
    else:
        rep.ok("build", f"build {build} of {marketing} not uploaded yet")


def null_answers(attributes):
    """Age-rating questions left unanswered (null) that are not optional."""
    optional = set(OPTIONAL_AGE_RATING)
    if not attributes.get("socialMedia"):
        optional.add("socialMediaAgeRestricted")    # only asked when socialMedia is true
    return sorted(k for k, v in attributes.items() if v is None and k not in optional)


def age_ratings(rep, infos):
    """[(appInfo, declaration)] for every current appInfo; reports unanswered questions."""
    found, all_ok = [], True
    for info in infos:
        state = info_state(info)
        if state in INFO_RETIRED:
            continue
        s, r = asc.call("GET", f"/v1/appInfos/{info['id']}/ageRatingDeclaration")
        decl = r.get("data") if s == 200 else None
        if not decl:
            rep.fatal("age rating", f"could not read the age rating of appInfo {info['id']} ({state}): "
                                    f"{s} {_error(r)}")
            all_ok = False
            continue
        found.append((info, decl))
        nulls = null_answers(decl.get("attributes") or {})
        if nulls:
            all_ok = False
            rep.fatal("age rating", f"appInfo {state}: unanswered {', '.join(nulls)}: answer these in "
                                    "App Store Connect -> App Information -> Age Rating")
    if all_ok and found:
        rep.ok("age rating", "all questions answered (" + ", ".join(info_state(i) or "?" for i, _ in found) + ")")
    return found


def probe_target(declarations):
    """An editable appInfo's declaration, else the live one's; never one that is with Apple."""
    for wanted in (lambda st: st in INFO_EDITABLE, lambda st: st not in INFO_WITH_APPLE):
        for info, decl in declarations:
            if wanted(info_state(info)):
                return info, decl
    return None, None


def check_agreements(rep, declarations):
    info, decl = probe_target(declarations)
    if decl is None:
        rep.warn("agreements", "not probed: no appInfo outside review to write to")
        return
    attrs = decl.get("attributes") or {}
    name = next((a for a in PROBE_ATTRIBUTES if attrs.get(a) is not None), None)
    if name is None:
        rep.warn("agreements", "not probed: no answered age-rating question to re-send")
        return
    state = info_state(info)
    s, r = asc.call("PATCH", f"/v1/ageRatingDeclarations/{decl['id']}",
                    {"data": {"type": "ageRatingDeclarations", "id": decl["id"],
                              "attributes": {name: attrs[name]}}})
    if 200 <= s < 300:
        rep.ok("agreements", f"writes accepted (re-sent {name}={attrs[name]!r} on the {state} appInfo)")
    elif s == 403 and AGREEMENT_CODE in _codes(r):
        rep.fatal("agreements", f"403 {AGREEMENT_CODE}: {AGREEMENT_FIX}")
    elif s == 409 and state not in INFO_EDITABLE:
        rep.warn("agreements", f"inconclusive: the {state} appInfo refused the write ({s} {_error(r)}), "
                               "which is past the agreement gate but proves nothing more")
    else:
        rep.fatal("agreements", f"the probe write failed: {s} {_error(r)}")


def check_store(rep, marketing, build):
    """Everything that needs App Store Connect. Returns True when the app was never released."""
    s, r = asc.call("GET", f"/v1/apps/{asc.APP_ID}/appStoreVersions?limit=50")
    if s != 200:
        rep.fatal("version", f"could not list App Store versions: {s} {_error(r)}")
        versions = None
    else:
        versions = r.get("data", [])
    if versions is not None and marketing:
        check_version(rep, marketing, versions)
    if marketing:
        check_build(rep, marketing, build)

    s, r = asc.call("GET", f"/v1/apps/{asc.APP_ID}/appInfos?limit=10")
    if s != 200:
        rep.fatal("age rating", f"could not list appInfos: {s} {_error(r)}")
        rep.fatal("agreements", "not probed: no appInfos")
    else:
        check_agreements(rep, age_ratings(rep, r.get("data", [])))
    return versions is not None and not any(asc.version_state(v["attributes"]) in RELEASED for v in versions)


def main():
    opts = parse_args(sys.argv[1:])
    if "-h" in opts or "--help" in opts:
        print(__doc__)
        return
    print(f"Preflight: {APP_NAME} (app {asc.APP_ID})")
    rep = Report()
    marketing, project_build = project_versions(rep)
    build = opts.get("--build") or (os.environ.get(BUILD_ENV) if BUILD_ENV else None) \
        or (project_build if BUILD_FROM_PROJECT else None)
    if marketing:
        rep.ok("project.yml", f"MARKETING_VERSION {marketing}" + (f", build {build}" if build else ""))
    first_release = False
    if check_keys(rep):
        try:
            first_release = check_store(rep, marketing, build)
        except Exception as e:   # offline, DNS, a key that won't sign: one line, not a traceback
            rep.fatal("connect", f"App Store Connect unreachable: {type(e).__name__}: {e}")
    check_notes(rep, marketing, first_release)

    fatal, warn = rep.count("fatal"), rep.count("warn")
    print(f"\npreflight: {'FAILED' if fatal else 'OK'}: {fatal} fatal, {warn} warning(s)")
    sys.exit(1 if fatal else 0)


if __name__ == "__main__":
    main()
