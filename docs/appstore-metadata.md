# App Store listing — Lístkomat (draft)

Category: **Travel** · Price: **Free** · Age rating: **4+**
Availability: **all storefronts** (downloadable worldwide; SMS purchase needs a Czech SIM — disclosed below)

## Czech localization (primary)

**Name:** Lístkomat
**Subtitle (≤30):** Jízdenky MHD přes SMS
**Promotional text (≤170):** Kup si jízdenku MHD jednou SMS — bez hledání čísla a kódu. Stačí vybrat město a délku jízdenky.

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

## URLs (TODO — need to provide/host)
- **Support URL:** e.g. https://listkomat.flipcom.cz or a GitHub Pages page
- **Privacy Policy URL:** required — short page; can host on GitHub Pages (claude can generate)
- **Marketing URL (optional)**

## Review notes (App Review → "Notes")
> The app pre-fills an SMS to a Czech premium short-code so the user can buy a real public-transport ticket (a real-world transit service, billed by the carrier — not digital content, so no IAP applies). Costs are disclosed in-app and in the description. A Czech SIM is required; reviewers outside CZ won't be able to complete a purchase, which is expected.

## Assets
- App icon 1024×1024 ✅ (in Assets.xcassets / source in iCloud)
- Screenshots 6.9" (1320×2868): `fastlane/screenshots/` — 01-main ✅; add city grid + (optional) Live Activity / offline
