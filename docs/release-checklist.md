# Lístkomat — Release Checklist

The habits to run around every App Store release. Short on purpose. The release
mechanics themselves live in [`scripts/release.sh`](../scripts/release.sh); this is
the human judgement that wraps them.

## Before submitting

- **Bump versions in `project.yml`** — `CURRENT_PROJECT_VERSION` +1 (unique per
  upload), `MARKETING_VERSION` for a new user-facing version.
- **Write fresh "What's New."** Don't carry the previous release's notes over —
  deliberately describe what actually changed this time. (See
  `docs/appstore-whatsnew-*.txt` for the house style.) Write the shipping copy
  into `fastlane/metadata/<locale>/release_notes.txt` for **every** locale —
  `scripts/asc_new_version.py` uploads it and the release fails on an empty
  file, so there is no way to ship last release's notes by accident.
- **Reviewer notes if the SMS flow is in play** — premium-SMS apps get extra
  scrutiny; reuse/adapt `docs/appstore-review-notes-*.txt`.

Nothing here needs the ASC web UI. `scripts/release.sh` creates the version
record and uploads the store copy before it archives, so a missing version bump
or an empty release-notes file stops the run in seconds instead of after the
upload.

- **Store copy lives in `fastlane/metadata/`, not in the web UI.** Description,
  keywords and subtitle are pushed alongside the notes, and only fields that
  actually differ are sent. Editing them in ASC instead means the next release
  silently overwrites your edit — check `git diff` there, not the browser.
- **A subtitle change needs a gap between submissions.** It is product-page copy,
  so while a release is in review the script skips it and says so. Re-run
  `python3 scripts/asc_new_version.py` once the release is approved.

## While in review

- **Don't cancel a build that's in review.** Let submitted builds go through.
  Batch new changes for the next version instead of swapping the binary
  mid-review — unless there's a genuine reason to pull it.

## After every release — observe (this is our whole observability strategy)

Lístkomat is a hobby app with **no analytics, no third-party SDKs, and a "Data
Not Collected" privacy label** — and we intend to keep it that way. That rules
out Sentry/Crashlytics and, for now, a diagnostics backend. The good news:
**Xcode Organizer already gives us everything a zero-code setup can**, collected
by Apple from opted-in users, with no privacy-label cost.

So the habit is simply: **a day or two after each release, open Xcode → Organizer**
and check two tabs.

Most of that is also available headlessly — run `python3 scripts/asc_health.py`
for Power & Performance metrics, per-build diagnostic signatures (hangs, disk
writes, launches) and crash counts, without opening Xcode. It needs the **Admin**
API key; see the script's docstring for why there are two keys. Symbolicated
crash *stacks* have no API, so those still mean opening Organizer — but the
script tells you whether there is anything worth opening it for.

- **Crashes** — symbolicated, grouped stack traces from opted-in App Store users
  (~1–2 day lag). Look for any new signature that appeared with this version.
  When a friend says *"it crashed the other day doing X,"* this is where you look
  — find a crash around that time and read the trace.
- **Metrics** — powered by MetricKit under the hood, collected automatically (no
  code). Watch **hang rate, launch time, memory, disk, battery** for regressions.
  A performance fix like the Brno-map hang shows up here as the rate dropping.

### What Organizer does *not* give you (and why we accept that)

- **Breadcrumbs** — the "what were they tapping in the 30 seconds before" trail.
  Only crash-reporter SDKs (Sentry/Crashlytics) or a custom backend provide this,
  and both break the "Data Not Collected" label. A symbolicated stack trace is
  enough for a hobby app; we accept the gap.
- **Off-device delivery of richer per-incident payloads.** A custom
  `MXMetricManager` subscriber can receive full `MXCrashDiagnostic` /
  `MXHangDiagnostic` payloads *in the app*, but with no backend to send them to,
  they just sit on the user's phone and never reach us — so building one now is
  premature. It's deferred to the v2.1 backend era (Track B), if ever. See the
  [hardening & backend handover](plans/2026-06-23-listkomat-hardening-backend-handover.md).

### Urgent one-off

If you need a specific report *now* and can't wait for Organizer's lag, a friendly
user can share **Settings → Privacy & Security → Analytics & Improvements →
Analytics Data**: `Listkomat-*.ips` is a code crash, `JetsamEvent-*` is a memory
kill.
