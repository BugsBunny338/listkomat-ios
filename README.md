# Lístkomat

A clean-slate native iOS rebuild of **Lístkomat** (originally "TicketBuyer"), a Czech app
that lets you buy a city public-transport ticket by premium SMS — without remembering the
phone number or the ticket code for your chosen duration.

The original (React Native, ~2016) is archived privately at `BugsBunny338/listkomat-archive`.

- **v1:** SMS tickets, 10 Czech cities, polished SwiftUI (iOS 16.1+).
- **v2:** live transit-vehicle map (Brno; Prague planned for v2.1, needs a backend proxy).

## Related repositories

All under the **BugsBunny338** GitHub account. The `listkomat-*` prefix covers the
current family, but the original app predates the rename — so this is the canonical map.

| Repo | Visibility | Role |
|------|-----------|------|
| [`listkomat-ios`](https://github.com/BugsBunny338/listkomat-ios) | public | This repo — the current SwiftUI app. |
| [`listkomat-catalog`](https://github.com/BugsBunny338/listkomat-catalog) | public | Remote ticket catalog (`tickets.json`) the app fetches at runtime. |
| [`listkomat-web`](https://github.com/BugsBunny338/listkomat-web) | public | GitHub Pages site — App Store Support & Privacy Policy URLs. |
| `listkomat-archive` | private | Recovered archive of the 2016 React Native app, full git history. |
| `listkomat` | private | 2018 iteration. |
| `TicketBuyer` | private | The 2016 original — Lístkomat's first name. |

## Docs

- [v1 design](docs/plans/2026-06-15-listkomat-revival-v1-design.md)
- [Hardening & backend handover](docs/plans/2026-06-23-listkomat-hardening-backend-handover.md) — what's next
- [Release checklist](docs/release-checklist.md) — habits around every App Store release (incl. Organizer observability)

## Status

**Live on the App Store — v2.0.1.** SMS tickets across 10 cities, theme-able UI,
Live Activity with a validity buffer (pending → active, *Potvrdit nyní*), and a
Brno live-vehicle map.

Observability is handled by Xcode Organizer as a post-release habit (no code, no
third-party SDKs — see the [release checklist](docs/release-checklist.md)). Next
build-work is the v2.1 backend that unlocks the Prague live map, off-device
diagnostics, and locked-screen push. See the
[hardening & backend handover](docs/plans/2026-06-23-listkomat-hardening-backend-handover.md).
