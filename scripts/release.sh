#!/usr/bin/env bash
#
# One-shot App Store release for Lístkomat:
#   preflight -> version record + What's New -> archive -> export -> upload -> submit.
#
# Human habits around a release (fresh What's New, don't cancel in-review, check
# Xcode Organizer after): see docs/release-checklist.md.
#
# Before running, bump the version in project.yml:
#   - CURRENT_PROJECT_VERSION  -> +1 for every upload (must be unique per version)
#   - MARKETING_VERSION        -> bump for a new user-facing version (e.g. 1.1)
#
# Usage:
#   scripts/release.sh              # full pipeline incl. submit for review
#   scripts/release.sh --no-submit  # archive+export+upload only (submit later with asc_submit.py --build)
#   scripts/release.sh --dry-run    # preflight + asc_new_version --dry-run + archive + export; no upload
#   scripts/release.sh --check      # preflight only: every known blocker, in seconds
#   scripts/release.sh --help
# Any other argument exits 2 before anything runs. --check wins over --dry-run, which wins
# over --no-submit, in any order.
#
# Every mode runs scripts/asc_preflight.py first and stops on a fatal finding (agreement not
# accepted, unanswered age-rating questions, missing signing key, version or build not
# bumped, empty What's New). Its only write re-sends one unchanged age-rating answer, because
# GETs can't show a missing agreement; --dry-run writes nothing else.
#
# To include a reviewer message, set ASC_NOTES to a file path or text, e.g.:
#   ASC_NOTES=docs/appstore-review-notes-2.7.txt scripts/release.sh
#
# "What's New" is NOT typed into the ASC web UI — write it to
# fastlane/metadata/<locale>/release_notes.txt and scripts/asc_new_version.py
# uploads it, along with creating the version record itself (releaseType
# AFTER_APPROVAL by default; ASC_RELEASE_TYPE=MANUAL to hold the release).
#
# Requires: xcodegen, Xcode CLT, an App Store Connect API key (.p8) in
# ~/.appstoreconnect/private_keys/ — see scripts/asc_submit.py.
set -euo pipefail
cd "$(dirname "$0")/.."

# >>> parse_mode (scripts/test_asc_scripts.py runs this block on its own)
parse_mode() {
  MODE=submit
  for arg in "$@"; do
    case "$arg" in
      -h|--help) MODE=help; return ;;
      --check) MODE=check ;;
      --dry-run) [[ "$MODE" == check ]] || MODE=dry-run ;;
      --no-submit) [[ "$MODE" == check || "$MODE" == dry-run ]] || MODE=no-submit ;;
      *) echo "unknown argument: $arg (usage: release.sh [--no-submit | --dry-run | --check | --help])" >&2
         exit 2 ;;
    esac
  done
}
# <<< parse_mode
parse_mode "$@"
if [[ "$MODE" == help ]]; then
  sed -n '3,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
  exit 0
fi
echo "==> MODE: $MODE"

echo "==> preflight"
python3 scripts/asc_preflight.py || { echo "==> preflight failed: nothing archived or uploaded" >&2; exit 1; }
if [[ "$MODE" == check ]]; then
  exit 0
fi

echo "==> xcodegen generate"
xcodegen generate >/dev/null

# Deliberately before the ~6 minutes of archive+export+upload: it creates the
# App Store version record and uploads "What's New" from fastlane/metadata —
# neither of which altool or asc_submit.py does. Idempotent, so re-running a
# failed release is safe.
echo "==> ensure App Store version + What's New"
if [[ "$MODE" == dry-run ]]; then
  python3 scripts/asc_new_version.py --dry-run
else
  python3 scripts/asc_new_version.py
fi

echo "==> archive"
rm -rf build/Listkomat.xcarchive build/export
xcodebuild -scheme Listkomat -configuration Release \
  -archivePath build/Listkomat.xcarchive \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates archive >/dev/null

VER=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleShortVersionString" build/Listkomat.xcarchive/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" build/Listkomat.xcarchive/Info.plist)
echo "    archived $VER ($BUILD)"

echo "==> export ipa"
# Cloud signing with the Admin API key, not Xcode's Apple ID session: that
# session keeps expiring ("No Accounts"), and this Mac has no local
# distribution certificate. The App Manager key (ASC_KEY_ID) can't cloud-sign
# ("Cloud signing permission error"); an Admin key can. Same key Beer Llama uses.
# asc_preflight.py checks this key file with the same variable and default.
SIGNING_KEY_ID="${ASC_SIGNING_KEY_ID:-FNJQ483TF7}"
xcodebuild -exportArchive \
  -archivePath build/Listkomat.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist scripts/exportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_${SIGNING_KEY_ID}.p8" \
  -authenticationKeyID "$SIGNING_KEY_ID" \
  -authenticationKeyIssuerID "${ASC_ISSUER_ID:-69a6de8d-d1d6-47e3-e053-5b8c7c11a4d1}" >/dev/null

if [[ "$MODE" == dry-run ]]; then
  echo "==> dry run done; nothing uploaded, nothing written beyond the preflight's probe."
  exit 0
fi

echo "==> upload to App Store Connect"
xcrun altool --upload-app -f build/export/Listkomat.ipa -t ios \
  --apiKey "${ASC_KEY_ID:-J6LV34D5S8}" \
  --apiIssuer "${ASC_ISSUER_ID:-69a6de8d-d1d6-47e3-e053-5b8c7c11a4d1}"

if [[ "$MODE" == no-submit ]]; then
  echo "==> uploaded; not submitting. When it has processed: python3 scripts/asc_submit.py --build $BUILD"
  exit 0
fi

echo "==> waiting for build $BUILD of $VER to finish processing"
python3 - "$VER" "$BUILD" <<'PY'
import sys, time, importlib.util, os
spec = importlib.util.spec_from_file_location("asc", os.path.join("scripts", "asc_submit.py"))
asc = importlib.util.module_from_spec(spec); spec.loader.exec_module(asc)
ver, want = sys.argv[1], sys.argv[2]
for i in range(60):  # ~30 min max; asc.call renews its token
    # This version's build only: a bare build number can also match an older version's build.
    s, r = asc.call("GET", f"/v1/builds?filter[app]={asc.APP_ID}"
                           f"&filter[preReleaseVersion.version]={ver}&filter[version]={want}")
    b = (r.get("data") or [None])[0] if s == 200 else None
    st = b["attributes"]["processingState"] if b else "NOT_YET_VISIBLE"
    print(f"    build {want} processing={st}", flush=True)
    if st == "VALID":
        break
    if st in ("FAILED", "INVALID"):
        print(f"    build {want} processing {st}; see App Store Connect")
        sys.exit(1)
    time.sleep(30)
else:
    print(f"    build {want} did not become VALID in time; run: python3 scripts/asc_submit.py --build {want}")
    sys.exit(1)
PY

echo "==> submit for review"
if [[ -n "${ASC_NOTES:-}" ]]; then
  python3 scripts/asc_submit.py --build "$BUILD" --notes "$ASC_NOTES"
else
  python3 scripts/asc_submit.py --build "$BUILD"
fi
