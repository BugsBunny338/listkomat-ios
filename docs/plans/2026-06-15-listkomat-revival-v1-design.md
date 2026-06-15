# Lístkomat Revival — v1 Design

*Date: 2026-06-15 · Status: draft for review*

## What this is

A clean-slate rebuild of **Lístkomat** (originally "TicketBuyer"), a Czech iOS app from
~2016 that let you buy a city public-transport ticket by premium SMS — without
remembering the phone number or the cryptic ticket code for your chosen duration. The
original was React Native; the surviving copy is archived at
`github.com/BugsBunny338/listkomat-archive` (private). This rebuild is native SwiftUI.

## Goals & non-goals

**Goals (in priority order)**
1. **Fun & nostalgia** — enjoy rebuilding it; ship something that feels like itself.
2. **Portfolio piece** — a clean, modern, demoable showcase of SwiftUI + AI-assisted dev.
3. **Real users** — it would be lovely if the same kind of person who once phoned about it
   finds it useful again.

**Non-goals**
- Making money. Paid price / ads are out of scope as a *financial* goal. (A symbolic
  price or "tip jar" could be a fun experiment later, but v1 is free.)
- Replacing the official city apps. We serve people who want *one simple app* across
  cities and don't want to remember SMS codes.

## Scope

**v1 — SMS tickets + "time-left" Live Activity, polished.** 10 cities (the 2 discontinued
ones dropped). After a ticket is sent, a glanceable countdown of remaining validity on the
lock screen / Dynamic Island / Always-On display.
**v2 — live vehicle map** (Prague + Brno first). Deliberately deferred.

## Architecture

- **Platform:** **iOS 16.1+**, iPhone-first. Swift 6 + SwiftUI, MVVM. (16.1 is the Live
  Activity floor and reaches iPhone 8/X-and-newer — see Device support. Uses `ObservableObject`
  rather than the iOS 17 `@Observable` macro; trivial at this size.)
- **No backend.** The ticket catalog is a small static JSON ("remote config") hosted free
  (GitHub Pages or a raw GitHub URL). App fetches on launch, caches locally, falls back to
  a bundled copy when offline. → wrong/stale codes can be fixed in seconds without an App
  Store release.
- **SMS send:** `MFMessageComposeViewController` wrapped in a `UIViewControllerRepresentable`.
  iOS will not auto-send; the user taps Send. This preserves the whole value prop (no
  remembering numbers/codes) within Apple's rules. (Direct port of the original's
  `react-native-message-composer`, which was the same native API.) Its delegate result
  (`.sent` / `.cancelled` / `.failed`) is the trigger for the time-left countdown below.
- **Live Activity:** ActivityKit (iOS 16.1+) for the ticket time-left countdown, with a
  WidgetKit Lock/Home-Screen widget fallback for long (24h/72h) tickets. See dedicated section.
- **Location:** CoreLocation, when-in-use, to auto-select the nearest known city. Manual
  city picker always available. (Ports the original haversine nearest-city logic.)
- **Dependencies:** essentially none. Pure SwiftUI + Foundation.

## Data model

### Ticket catalog (remote JSON) — proposed schema

```json
{
  "version": 1,
  "updatedAt": "2026-06-15",
  "cities": [
    {
      "key": "praha",
      "name": "Praha",
      "lat": 50.075538,
      "lng": 14.437800,
      "smsNumber": "90206",
      "tickets": [
        { "code": "DPT42",  "duration": "30 min", "priceKc": 42,  "note": "" },
        { "code": "DPT55",  "duration": "90 min", "priceKc": 55,  "note": "" },
        { "code": "DPT150", "duration": "24 h",   "priceKc": 150, "note": "" },
        { "code": "DPT350", "duration": "72 h",   "priceKc": 350, "note": "" }
      ]
    }
  ]
}
```

### Verified v1 catalog (2026-06-15)

Numbers in use: **90206** (most) and **90230** (Hradec Králové only). Coordinates carry
over unchanged from the recovered 2016 `constants.js`.

| City | Number | Code | Duration | Price | Note |
|------|--------|------|----------|------:|------|
| **Praha** | 90206 | DPT42 | 30 min | 42 | |
| | | DPT55 | 90 min | 55 | |
| | | DPT150 | 24 h | 150 | |
| | | DPT350 | 72 h | 350 | |
| **Brno** *(unchanged since 2016)* | 90206 | BRNO20 | 20 min | 20 | |
| | | BRNO | 75 min | 29 | |
| | | BRNOD | 24 h | 99 | |
| **Ostrava** | 90206 | DPO70 | 70 min (90 min wknd/hol) | 38 | |
| | | DPO70Z | 70 min | 19 | zlevněný |
| | | DPO24 | 24 h | 100 | |
| | | DPO24Z | 24 h | 50 | zlevněný |
| **Plzeň** | 90206 | PMDP35M | 35 min | 28 | vnitřní zóna |
| | | PMDP24H | 24 h | 99 | vnitřní zóna |
| **Liberec** ⚠︎ | 90206 | LIB | 60 min | 38 | verify price |
| | | LIB45 | 90 min | 45 | tram L11 do Jablonce; verify |
| **Olomouc** | 90206 | DPMO | 50 min (70 min víkend) | 27 | |
| **Ústí n.L.** ⚠︎ | 90206 | MDJ | 60 min | 26 | verify (23 vs 26) |
| | | MDJ106 | 24 h | 106 | |
| | | MDJ60 | 24 h | 60 | |
| | | MDJZD | 24 h | 53 | zlevněný |
| **Hradec Králové** | 90230 | HK | 60 min | 30 | |
| | | HKZ | 60 min | 15 | zlevněný (6–15 / 65+) |
| | | HK24 | 24 h | 100 | |
| **České Budějovice** | 90206 | BUD | 60 min | 30 | |
| | | BUD24 | 24 h | 115 | |
| **Pardubice** *(unchanged since 2016)* | 90206 | DPMP | 45 min (60 min víkend/svátek) | 25 | pásma I+II |
| | | DPMP24 | 24 h | 65 | |

**Dropped vs 2016:** Karlovy Vary (SMS discontinued 1 Jan 2025 → Vary Virtual app);
Rychnov nad Kněžnou (folded into IREDO, no SMS product).

⚠︎ = re-verify against the operator's current ceník before shipping.

## Device support & accessibility

- **Minimum: iOS 16.1 — a SOFT floor.** Reaches iPhone 8 / X (2017) and newer — the cheap
  secondhand models the older-user audience is most likely to own — while keeping Live
  Activities on the baseline. **This is a preference, not a constraint:** if holding 16.1 would
  mean compromising any feature or notably complicating the code, we bump the floor back up
  (e.g. to 17) rather than degrade the app. Reach serves the app; the app doesn't serve reach.
- **Graceful degradation:** the core SMS flow works on every supported device; the time-left
  Live Activity lights up on 16.1+; Dynamic Island + Always-On are bonuses on iPhone 14 Pro+.
  No device is excluded from the core feature.
- **Design for the smallest screen first:** iPhone SE (375pt wide); scales up to Pro Max
  automatically via SwiftUI layout.
- **Accessibility:** full Dynamic Type support; vector assets imported with "Preserve Vector
  Data" so icons stay crisp at large accessibility text sizes. (Audience skews older — many
  CZ cities give 65+/70+ free transit, so the paying older cohort is ~60–70.)

## Graphics & assets

All from the recovered iCloud assets (`~/Library/Mobile Documents/.../Lístkomat`). Audited
2026-06-15:
- **City icons — true vector SVGs** (path/shape data, no embedded raster). Scale infinitely.
  Import into the Asset Catalog with **Preserve Vector Data**. (`Praha.svg` uses shape
  elements rather than `<path>` — still vector; eyeball on import.) Note: catalog covers 11
  cities; **Olomouc has no icon** (it was in code but not the icon set) — needs one made (from
  the editable sources) or an SF Symbol fallback.
- **Logo — vector SVG** (+ editable `.ai` / `.sketch` / `.psd`). Regenerate at any size.
- **App icon — `1024×1024` PNG exists** (exact App Store size); Xcode auto-generates the rest.
- **Transit-mode icons (bus/metro/tram/trolejbus) — `375×375` PNG (raster).** Plenty for
  on-screen icon use; not infinitely scalable. Optional later swap to SF Symbols
  (`bus.fill`, `tram.fill`, `cablecar`, …). Mostly a v2-map concern.
- **Verdict:** graphics are in good shape; no redesign needed for v1 (only an Olomouc icon).

## Screens & flow (v1)

1. **Main screen (portrait).**
   - Header: app identity (original logo + Alte Haas Grotesk font from the iCloud assets).
   - Context line: "Nyní se nacházíte ve městě:" / "Nejbližší známé město…" / "Vybrané město:"
     (ported copy), with the city name.
   - List of ticket buttons for the current city: "Lístek na 30 min (42 Kč)" + optional note.
     Tap → SMS composer pre-filled with the code + number → user taps Send.
   - City picker (grid of the original city icons) to override GPS.
2. **Permissions:** friendly location pre-prompt (ported Czech copy), graceful manual
   fallback if denied.
3. **Offline:** uses cached/bundled catalog; shows a subtle "naposledy aktualizováno" note.

## Ticket time-left — Live Activity (v1)

A glanceable countdown of how much validity remains on the ticket just bought, shown on the
**lock screen, Dynamic Island, Always-On display** (iPhone 14 Pro+), and **Apple Watch Smart
Stack** (iOS 18+).

**What we can and can't know**
- iOS reports the compose result via the `MFMessageComposeViewController` delegate: `.sent`
  means the user tapped Send and the message was handed off. That is our trigger.
- We **cannot** read the operator's confirmation SMS (iOS has no inbox API), so we don't get
  the exact "platí od–do" window. The countdown is therefore an **estimate**: anchored to the
  `.sent` timestamp + the chosen ticket's known duration.
- The real ticket activates when the reply arrives (often a minute or two later), so the
  estimate runs slightly optimistic. Mitigation: when the confirmation pings, offer a one-tap
  **"Mám lístek — spustit odpočet"** to re-anchor the timer to the real activation moment.

**Mechanism**
- ActivityKit `Activity` started on `.sent`; the UI uses `Text(timerInterval:)` so the
  countdown ticks **on-device, no push/server needed**.
- **Lifetime limit:** a Live Activity lasts ~8h (≤~12h incl. its ended state). Perfect for
  20/30/60/90-min tickets. For **24h / 72h** tickets it would expire before the ticket → fall
  back to a **WidgetKit** Lock/Home-Screen widget (and/or Watch complication) for the long
  ones. v1 ships the Live Activity for short tickets; the long-ticket widget can follow.

**Honesty / legal framing (must-have)**
- The countdown is a **convenience, not the legal ticket** — a revízor checks the operator's
  SMS. The UI must state this clearly (and the App Store description should too), so it never
  misleads.

## Error handling

- No network on launch → bundled catalog, silent.
- Device can't send SMS (iPad/no SIM) → disable buttons with explanation.
- Catalog fetch fails → keep last good cache; never block the core flow.
- Unknown location / GPS off → land on manual picker.

## Testing

- Unit: nearest-city (haversine), catalog decoding, fallback logic, SMS body/recipient
  construction.
- Snapshot/UI: main screen per city, picker, permission-denied state (Xcode 26 preview
  screenshots).
- Manual: real send on a device for 1–2 cities (verify the composer pre-fills correctly).

## Milestones

1. **M0 — Backup** ✅ (archive repo + new `listkomat-ios` repo created).
2. **M1 — Project skeleton** ✅ SwiftUI app, catalog model + bundled JSON, city picker,
   nearest-city. Builds clean on Xcode 26.5; 3/3 unit tests pass; runs on iPhone 17 sim with
   GPS auto-selecting the city (verified Praha→Brno). Toolchain: XcodeGen + XcodeBuildMCP.
3. **M2 — SMS flow:** composer wired (done); remaining: ticket-button polish + end-to-end
   real-send test on a physical device.
4. **M3 — Time-left Live Activity:** ActivityKit countdown on `.sent`, Dynamic Island /
   lock-screen / Always-On; "re-anchor on confirmation" tap. (Long-ticket WidgetKit fallback
   can trail.)
5. **M4 — Branding** ✅ app icon (2016 ticket-machine art), brand teal `#56C4CF`,
   Alte Haas Grotesk on titles/headlines, and a city-icon grid picker using the original
   landmark SVGs (incl. a hand-drawn Olomouc Holy Trinity Column matching the set). Verified
   on iPhone 17 sim. Residual polish (later): permission pre-prompt UX + offline
   "naposledy aktualizováno" note.
6. **M5 — Catalog hosting:** publish JSON, wire remote fetch + cache + fallback.
7. **M6 — Ship prep:** App Store assets, privacy nutrition labels, premium-SMS cost
   disclosure, Small Business Program enrollment, submit.
8. **v2 — Live map:** Prague (Golemio GTFS-RT) + Brno (KORDIS ArcGIS), landscape mode.

## Android — deferred (Apple-only for now)

Intentionally Apple-only. The standout feature (Live Activity / Dynamic Island / Always-On)
is deeply iOS-specific; a cross-platform layer would dilute exactly what makes this special,
and it fits the goal of building for love on the platform of choice.

If Android ever happens:
- It would be **native Kotlin + Jetpack Compose** (Java is legacy now), as a *separate* app —
  not React Native (what the 2016 original used).
- **No code-sharing needed:** the remote-config **ticket-catalog JSON is already the
  cross-platform contract.** Both apps just read the same JSON. The app's real logic (catalog
  + nearest-city haversine + building an SMS string) is tiny — re-implementing in Kotlin is
  trivial, so Kotlin Multiplatform's toolchain overhead isn't worth it at this size.
- Android bonus (someday file): Android *can* read incoming SMS with permission, enabling
  exact validity from the confirmation reply — but Google Play restricts that to default-SMS
  apps, so it's hard to ship. Sending via intent is unrestricted.

## Costs

- Apple Developer Program: ~$99/yr (~2,400 Kč).
- Hosting: $0 (static JSON on GitHub Pages / raw).
- Commission (only if ever paid): 15% via Small Business Program.

## App Store account

- Enroll as a **CZ Individual** using the **CZ Apple ID** (seller = personal name; no D-U-N-S).
- Storefront availability is chosen per-country at publish time and is **independent of the
  account's country** — so the CZ account ships to the Czech App Store (and anywhere else we
  pick). A US account would also reach CZ; CZ is chosen to match the market/address and avoid
  US tax-form overhead if a price is ever added.
- The app is **free**, so only Apple's free-app agreement is needed — **no banking or tax
  forms**. (Dev has both CZ and US Apple IDs / billing / residency; CZ chosen deliberately.)

## Risks / open questions

- **Ticket-data accuracy** is the real ongoing burden — codes/prices drift. Mitigated by
  remote config + a periodic re-verify habit. Consider a "report a wrong ticket" link.
- **Premium-SMS longevity** — Karlovy Vary already dropped it; more cities may follow. The
  app degrades gracefully (just fewer cities) and remote config lets us remove a city fast.
- **App Store review** — an app that triggers premium SMS should clearly disclose costs in
  UI + description to avoid rejection. Worth confirming current guidelines before submit.
- **New app's repo/name** — decide where the rebuild lives (`listkomat` name is free on
  GitHub again now). Local path proposed: `~/prj/listkomat`.
- **Branding** — reuse the 2016 identity as-is, or refresh it? (Assets are all in iCloud.)
