import XCTest
@testable import Listkomat

/// Covers the catalog's `i18n` overrides and the client-side duration
/// formatting that replaced the catalog's Czech `duration` label.
final class CatalogLocalizationTests: XCTestCase {

    private func decode(_ json: String) throws -> [City] {
        try JSONDecoder().decode(TicketCatalog.self, from: Data(json.utf8)).cities
    }

    private let localized = #"""
    {"version":5,"updatedAt":"2026-08-30","cities":[
      {"key":"praha","name":"Praha","lat":50.07,"lng":14.43,"smsNumber":"90206",
       "i18n":{"en":{"name":"Prague"}},
       "tickets":[
         {"code":"DPO70","duration":"70 min","durationMinutes":70,"priceKc":38,
          "note":"o víkendu a svátcích 90 min",
          "i18n":{"en":{"note":"90 min on weekends and public holidays"}}},
         {"code":"DPT42","duration":"30 min","durationMinutes":30,"priceKc":42}
       ]}
    ]}
    """#

    // MARK: - Overrides

    func testEnglishOverridesApply() throws {
        let city = try XCTUnwrap(decode(localized).first)
        XCTAssertEqual(city.localizedName(in: "en"), "Prague")
        XCTAssertEqual(city.tickets[0].localizedNote(in: "en"),
                       "90 min on weekends and public holidays")
    }

    func testCzechIsTheFallbackForEveryUntranslatedLanguage() throws {
        let city = try XCTUnwrap(decode(localized).first)
        XCTAssertEqual(city.localizedName(in: "cs"), "Praha")
        XCTAssertEqual(city.localizedName(in: "de"), "Praha")
        XCTAssertEqual(city.tickets[0].localizedNote(in: "cs"), "o víkendu a svátcích 90 min")
        XCTAssertEqual(city.tickets[0].localizedNote(in: "de"), "o víkendu a svátcích 90 min")
    }

    func testMissingNoteStaysNilInEveryLanguage() throws {
        let plain = try XCTUnwrap(decode(localized).first).tickets[1]
        XCTAssertNil(plain.localizedNote(in: "cs"))
        XCTAssertNil(plain.localizedNote(in: "en"))
    }

    /// A shipped build must survive a catalog that grows fields it has never
    /// seen — that tolerance is what makes `i18n` safe to add at all.
    func testUnknownLanguagesAndFieldsDecodeCleanly() throws {
        let json = #"""
        {"version":9,"updatedAt":"2026-08-30","cities":[
          {"key":"brno","name":"Brno","lat":49.19,"lng":16.6,"smsNumber":"90206",
           "i18n":{"en":{"name":"Brno"},"de":{"name":"Brünn"}},"somethingNew":42,
           "tickets":[{"code":"BRNO","duration":"75 min","durationMinutes":75,"priceKc":29}]}
        ]}
        """#
        let city = try XCTUnwrap(decode(json).first)
        XCTAssertEqual(city.localizedName(in: "de"), "Brünn")
        XCTAssertEqual(city.localizedName(in: "en"), "Brno")
    }

    /// An empty override would otherwise blank out the Czech text it translates.
    func testEmptyOverrideFallsBackRatherThanBlanking() throws {
        let json = #"""
        {"version":5,"updatedAt":"2026-08-30","cities":[
          {"key":"plzen","name":"Plzeň","lat":49.73,"lng":13.37,"smsNumber":"90206",
           "i18n":{"en":{"name":""}},
           "tickets":[{"code":"PMDP35M","duration":"35 min","durationMinutes":35,"priceKc":28,
                       "note":"vnitřní zóna","i18n":{"en":{"note":""}}}]}
        ]}
        """#
        let city = try XCTUnwrap(decode(json).first)
        XCTAssertEqual(city.localizedName(in: "en"), "Plzeň")
        XCTAssertEqual(city.tickets[0].localizedNote(in: "en"), "vnitřní zóna")
    }

    func testRegionalLanguageTagsNarrowToTheBaseCode() {
        XCTAssertEqual(CatalogLanguage.base(of: "en-GB"), "en")
        XCTAssertEqual(CatalogLanguage.base(of: "cs_CZ"), "cs")
        XCTAssertEqual(CatalogLanguage.base(of: "en"), "en")
        XCTAssertEqual(CatalogLanguage.base(of: nil), "cs")   // source language
        XCTAssertEqual(CatalogLanguage.base(of: ""), "cs")
    }

    // MARK: - Duration

    private func ticket(minutes: Int, label: String = "") -> Ticket {
        Ticket(code: "X", duration: label, durationMinutes: minutes, priceKc: 1, note: nil)
    }

    func testShortDurationsStayInMinutes() {
        // 60 min is sold as sixty minutes, not "1 hodinu" — the switch to hours
        // only kicks in past the point where operators stop pricing in minutes.
        for minutes in [20, 30, 35, 45, 50, 60, 70, 75, 90] {
            XCTAssertEqual(ticket(minutes: minutes).durationUnit, .minutes(minutes))
        }
    }

    func testWholeHourDurationsBecomeHours() {
        XCTAssertEqual(ticket(minutes: 120).durationUnit, .hours(2))
        XCTAssertEqual(ticket(minutes: 1440).durationUnit, .hours(24))
        XCTAssertEqual(ticket(minutes: 4320).durationUnit, .hours(72))
    }

    func testRaggedLongDurationsStayInMinutes() {
        XCTAssertEqual(ticket(minutes: 150).durationUnit, .minutes(150))
    }

    /// A catalog row with no usable `durationMinutes` still has to render
    /// something, so it falls back to the legacy Czech label.
    func testMalformedDurationFallsBackToTheLegacyLabel() {
        XCTAssertEqual(ticket(minutes: 0, label: "24 h").localizedDuration, "24 h")
    }

    // MARK: - Bundled catalog

    /// The bundled fallback is what an offline first launch shows, so it must
    /// carry the same translations as the remote catalog it mirrors.
    @MainActor func testBundledCatalogTranslatesEveryCzechNote() {
        let catalog = CatalogStore.loadBundled(bundle: Bundle(for: CatalogStore.self))
        XCTAssertFalse(catalog.cities.isEmpty, "bundled catalog missing")

        let untranslated = catalog.cities.flatMap(\.tickets)
            .filter { $0.note != nil && $0.i18n?["en"]?.note == nil }
            .map(\.code)
        XCTAssertTrue(untranslated.isEmpty,
                      "Czech notes with no English translation: \(untranslated)")

        let praha = catalog.cities.first { $0.key == "praha" }
        XCTAssertEqual(praha?.localizedName(in: "en"), "Prague")
    }

    /// Every bundled row must have a usable `durationMinutes` — it now drives
    /// what the user reads, not just the countdown.
    @MainActor func testBundledCatalogHasUsableDurations() {
        let catalog = CatalogStore.loadBundled(bundle: Bundle(for: CatalogStore.self))
        for city in catalog.cities {
            for ticket in city.tickets {
                XCTAssertGreaterThan(ticket.durationMinutes, 0,
                                     "\(city.key)/\(ticket.code) has no durationMinutes")
            }
        }
    }
}
