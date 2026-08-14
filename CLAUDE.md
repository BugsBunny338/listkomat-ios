# Lístkomat — agent context

Native SwiftUI rebuild of a Czech premium-SMS transit-ticket app, plus a live
vehicle map. Personal/portfolio project — not a money-maker. The user-facing
overview, repo family table and doc links live in [README.md](README.md); this
file is the working context that isn't obvious from the code.

**Start sessions from this directory** (`~/prj/listkomat`), not from `~/prj`.
Memory is keyed by session cwd, and the Lístkomat memories — release state,
GitHub/proxy references, working rules — live in this repo's store. Starting
from `~/prj` gets you the personal-projects store instead, which no longer
carries anything Lístkomat.

## Build, test, run

The Xcode project is **generated and gitignored** — `xcodegen generate` first, or
nothing will build. `project.yml` is the source of truth for targets, versions
and build settings; never hand-edit `Listkomat.xcodeproj`.

```sh
xcodegen generate                     # required after any project.yml change / fresh clone
xcodebuild -scheme Listkomat -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -scheme Listkomat -destination 'platform=iOS Simulator,name=iPhone 16' test
```

- Targets: `Listkomat` (app), `ListkomatWidgets` (Live Activity), `ListkomatTests`,
  with shared code in `Shared/`.
- iOS 16.2 deployment target, Swift 5 language mode (bump to 6 once it builds clean).
- Team `35AS7FL468`, bundle prefix `cz.flipcom`, automatic signing.
- `Listkomat/Info.plist` is generated too — edit the `info.properties` block in
  `project.yml`. Localized Info.plist strings are authoritative in
  `Listkomat/InfoPlist.xcstrings` (cs + en); the `project.yml` values are only a
  fallback, so change both.

For anything interactive — building to a simulator, driving the UI, reading logs
— prefer the available agentic iOS tooling over hand-rolled `xcodebuild`
invocations. If a tool that would obviously help isn't installed, ask for it
rather than hand-hacking around its absence.

## Release

`scripts/release.sh` does archive → export → upload → submit in one shot
(`--no-submit` to stop after upload). It needs `xcodegen`, Xcode CLT, and an App
Store Connect API key in `~/.appstoreconnect/private_keys/` (see
`scripts/asc_submit.py`). `ASC_NOTES=<file-or-text>` attaches reviewer notes.

Bump both in `project.yml` before running: `CURRENT_PROJECT_VERSION` (+1 for
every upload, must be unique) and `MARKETING_VERSION` (new user-facing version).

`docs/release-checklist.md` holds the human judgement around it. Two rules that
bite most often:

- **Write fresh "What's New" every release.** Never carry the previous notes
  over — describe what actually changed. House style in `docs/appstore-whatsnew-*.txt`.
- **Never cancel a build that's already in review.** Let it go through and batch
  new changes into the next version, unless the user explicitly says to swap it.

`fastlane/` is metadata + screenshots only — there is no Fastfile and no lanes.

## Observability — deliberately minimal

No analytics, no third-party SDKs, a "Data Not Collected" privacy label, and we
keep it that way. **Xcode Organizer (Crashes + Metrics) is the entire strategy**;
check it a day or two after each release.

"Keep it simple" here means *no third-party SaaS* (Sentry, Crashlytics, etc.) —
it does **not** rule out Apple-native or free serverless infrastructure. The
Cloudflare Worker in `proxy/` is squarely within bounds.

## Services and repos

- `proxy/` — Cloudflare Worker proxying Golemio/PID open data for the Prague
  live map. Deploy with `npx --yes wrangler@4 deploy`.
- Sibling repos `listkomat-catalog` (runtime `tickets.json`) and `listkomat-web`
  (Support/Privacy URLs on GitHub Pages) are **live dependencies** — the app and
  the App Store listing point at them. Don't delete or break them.
- All under the **BugsBunny338** GitHub account. `gh` is configured with two
  accounts, so switch to `BugsBunny338` for anything here, then switch back.

## Conventions

- Push to `origin` right after committing to `main` — don't leave local-only
  commits sitting. Never auto-push work-in-progress.
- App UI language is Czech (`developmentLanguage: cs`) with English localization;
  code, comments, commit messages and PRs are English.
- `gws` and the `/whats-new` skill are **Alaigned-only tooling** — the @mensa.cz
  account spans several unrelated contexts. Never reach for them here.
