import XCTest
@testable import Listkomat

/// Guards the English localization: the built app must ship an en strings table
/// that mirrors the Czech (source) one. Catches a key dropped from the catalog
/// or a build that stopped compiling the catalog at all.
final class LocalizationTests: XCTestCase {
    private let appBundle = Bundle(for: CatalogStore.self)

    private func stringsTable(for localization: String) throws -> [String: String] {
        let path = try XCTUnwrap(
            appBundle.path(forResource: "Localizable", ofType: "strings",
                           inDirectory: nil, forLocalization: localization),
            "Localizable.strings missing for \(localization)"
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    func testEnglishTableExistsAndIsSubstantial() throws {
        let en = try stringsTable(for: "en")
        // The catalog has ~50 translated keys; a near-empty table means the
        // catalog silently stopped compiling.
        XCTAssertGreaterThan(en.count, 40, "English strings table looks truncated")
        XCTAssertFalse(en.values.contains(""), "English table contains empty translations")
    }

    func testSpotTranslations() throws {
        let en = try stringsTable(for: "en")
        XCTAssertEqual(en["Vzhled"], "Appearance")
        XCTAssertEqual(en["Potvrdit nyní"], "Confirm now")
        XCTAssertEqual(en["Funguje s českou SIM kartou."], "Requires a Czech SIM card.")
        XCTAssertEqual(en["Lístek na %@ · %lld Kč"], "Ticket for %1$@ · %2$lld Kč")
    }

    func testCzechAndEnglishKeysMatch() throws {
        // cs is the source language; if its compiled table exists, en must
        // cover exactly the translatable keys (shouldTranslate:false keys may
        // be absent from en — so require en ⊆ cs and no cs-only *translated* gaps
        // beyond the known opt-outs).
        guard let csPath = appBundle.path(forResource: "Localizable", ofType: "strings",
                                          inDirectory: nil, forLocalization: "cs"),
              let cs = NSDictionary(contentsOfFile: csPath) as? [String: String] else {
            throw XCTSkip("cs table not emitted separately (source language)")
        }
        let en = try stringsTable(for: "en")
        let optOuts: Set<String> = ["%@ · %@", "→ %@", "Lístkomat", "Lístkomat %@", "OK", "Šalina"]
        let missing = Set(cs.keys).subtracting(en.keys).subtracting(optOuts)
        XCTAssertTrue(missing.isEmpty, "Keys missing English translation: \(missing.sorted())")
    }

    func testInfoPlistLocationUsageLocalized() throws {
        let path = try XCTUnwrap(
            appBundle.path(forResource: "InfoPlist", ofType: "strings",
                           inDirectory: nil, forLocalization: "en"),
            "InfoPlist.strings missing for en"
        )
        let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        XCTAssertNotNil(table["NSLocationWhenInUseUsageDescription"])
    }
}
