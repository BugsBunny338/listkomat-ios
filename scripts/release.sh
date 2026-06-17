#!/usr/bin/env bash
#
# One-shot App Store release for Lístkomat: archive -> export -> upload -> submit.
#
# Before running, bump the version in project.yml:
#   - CURRENT_PROJECT_VERSION  -> +1 for every upload (must be unique per version)
#   - MARKETING_VERSION        -> bump for a new user-facing version (e.g. 1.1)
#
# Usage:
#   scripts/release.sh            # full pipeline incl. submit for review
#   scripts/release.sh --no-submit  # archive+export+upload only (submit later)
#
# To include a reviewer message, set ASC_NOTES to a file path or text, e.g.:
#   ASC_NOTES=docs/appstore-review-reply-5.1.1.txt scripts/release.sh
#
# Requires: xcodegen, Xcode CLT, an App Store Connect API key (.p8) in
# ~/.appstoreconnect/private_keys/ — see scripts/asc_submit.py.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> xcodegen generate"
xcodegen generate >/dev/null

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
xcodebuild -exportArchive \
  -archivePath build/Listkomat.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist scripts/exportOptions.plist \
  -allowProvisioningUpdates >/dev/null

echo "==> upload to App Store Connect"
xcrun altool --upload-app -f build/export/Listkomat.ipa -t ios \
  --apiKey "${ASC_KEY_ID:-J6LV34D5S8}" \
  --apiIssuer "${ASC_ISSUER_ID:-69a6de8d-d1d6-47e3-e053-5b8c7c11a4d1}"

if [[ "${1:-}" == "--no-submit" ]]; then
  echo "==> uploaded; skipping submit (--no-submit). Run scripts/asc_submit.py when processed."
  exit 0
fi

echo "==> waiting for build $BUILD to finish processing, then submitting"
python3 - "$BUILD" <<'PY'
import sys, time, importlib.util, os
spec = importlib.util.spec_from_file_location("asc", os.path.join("scripts", "asc_submit.py"))
asc = importlib.util.module_from_spec(spec); spec.loader.exec_module(asc)
want = sys.argv[1]
for i in range(40):  # ~20 min max
    s, r = asc.call("GET", f"/v1/builds?filter[app]={asc.APP_ID}&limit=10&sort=-version")
    b = next((x for x in r.get("data", []) if x["attributes"]["version"] == want), None)
    st = b["attributes"]["processingState"] if b else "NOT_YET_VISIBLE"
    print(f"    build {want} processing={st}")
    if st == "VALID":
        break
    time.sleep(30)
else:
    print("    build did not become VALID in time; run scripts/asc_submit.py later")
    sys.exit(1)
PY

if [[ -n "${ASC_NOTES:-}" ]]; then
  python3 scripts/asc_submit.py --notes "$ASC_NOTES"
else
  python3 scripts/asc_submit.py
fi
