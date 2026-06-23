# Lístkomat

A clean-slate native iOS rebuild of **Lístkomat** (originally "TicketBuyer"), a Czech app
that lets you buy a city public-transport ticket by premium SMS — without remembering the
phone number or the ticket code for your chosen duration.

The original (React Native, ~2016) is archived privately at `BugsBunny338/listkomat-archive`.

- **v1:** SMS tickets, 10 Czech cities, polished SwiftUI (iOS 16.1+).
- **v2:** live transit-vehicle map (Prague + Brno).

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

## Status

Brainstorming / design. Not yet implemented.
