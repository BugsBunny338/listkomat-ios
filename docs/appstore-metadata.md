# App Store listing — Lístkomat (draft)

Category: **Travel** · Price: **Free** · Age rating: **4+**
Availability: **Czechia storefront only (v1)** — SMS purchase requires a Czech SIM, so foreign-carrier
users can't transact; we don't surface the app to them until a foreigner-friendly purchase path exists.
Expand to other storefronts in a later version (see Roadmap below).

## Czech localization (primary)

**Name:** Lístkomat
**Subtitle (≤30):** Jízdenky MHD přes SMS
**Promotional text (≤170):** Kup si jízdenku MHD jednou SMS — bez hledání čísla a kódu. Stačí vybrat město a dobu platnosti.

**Keywords (≤100, comma, no spaces after comma):**
`jízdenka,MHD,SMS jízdenka,jízdné,doprava,tramvaj,autobus,trolejbus,metro,Praha,Brno,Ostrava,Plzeň`

**Description:**
> Lístkomat vám koupí jízdenku městské hromadné dopravy jedinou SMS — bez toho, abyste si pamatovali telefonní číslo a kód lístku. Vyberte město, zvolte délku jízdenky a appka předvyplní správnou SMS. Lístek koupíte jejím odesláním.
>
> Podporovaná města: Praha, Brno, Ostrava, Plzeň, Liberec, Olomouc, Ústí nad Labem, Hradec Králové, České Budějovice, Pardubice.
>
> • Podle polohy vám rovnou nabídne nejbližší město
> • Po koupi vám na zamykací obrazovce běží odpočet platnosti lístku (Live Activity)
> • Ceník se aktualizuje sám — vždy aktuální ceny a kódy
>
> **Pro nákup je potřeba česká SIM karta.** Cenu lístku účtuje váš operátor prostřednictvím prémiové SMS (cena = cena lístku). Jízdenka platí jen ve zvoleném městě.

## English localization

**Name:** Lístkomat
**Subtitle (≤30):** Czech transit tickets by SMS
**Promotional text:** Buy a Czech public-transport ticket with one SMS — no need to remember the number or the ticket code.

**Keywords (≤100):**
`Czech transit ticket,public transport,tram,bus,metro,Prague,Brno,jizdenka,MHD,SMS ticket,Czechia`

**Description:**
> Lístkomat buys a Czech city public-transport ticket with a single SMS — without memorising the phone number and ticket code. Pick a city, choose a ticket length, and the app pre-fills the correct SMS; send it to buy.
>
> Cities: Prague, Brno, Ostrava, Plzeň, Liberec, Olomouc, Ústí nad Labem, Hradec Králové, České Budějovice, Pardubice.
>
> • Auto-suggests the nearest city from your location
> • A lock-screen countdown of your ticket's remaining validity (Live Activity)
> • Self-updating fare list — always current prices and codes
>
> **A Czech SIM card is required to buy tickets** — the fare is charged by your mobile carrier via premium SMS (price = ticket price), and tickets are valid only in the chosen city. Visitors on a foreign carrier won't be able to send the premium SMS.

## Privacy nutrition labels
- **Location** — used for App Functionality (suggest nearest city). NOT linked to identity, NOT used for tracking, NOT collected/sent off device.
- No other data collected. No analytics, no accounts, no third-party SDKs.

## URLs (live — GitHub Pages, repo BugsBunny338/listkomat-web)
- **Support URL:** https://bugsbunny338.github.io/listkomat-web/
- **Privacy Policy URL:** https://bugsbunny338.github.io/listkomat-web/privacy.html
- **Marketing URL (optional):** same as support

## Review notes (App Review → "Notes")
> The app pre-fills an SMS to a Czech premium short-code so the user can buy a real public-transport ticket (a real-world transit service, billed by the carrier — not digital content, so no IAP applies). Costs are disclosed in-app and in the description. A Czech SIM is required; reviewers outside CZ won't be able to complete a purchase, which is expected.

## Assets
- App icon 1024×1024 ✅ (in Assets.xcassets / source in iCloud)
- Screenshots 6.9" (1320×2868): `fastlane/screenshots/` — 01-main ✅, 02-grid ✅; optional: Live Activity / offline

## Roadmap (post-v1)
- **Foreigner purchase path** — premium SMS needs a Czech SIM, so foreign-carrier visitors can't buy.
  A later version adds an alternative: deep-link to the operator's official app, redirect to the
  official web purchase, or in-app card payment (real-world transit service → no IAP required).
- **Storefront expansion** — only once the above exists do we open availability beyond Czechia.
- **v2 live map** — works for all visitors regardless of SIM; the tourist-facing feature.
