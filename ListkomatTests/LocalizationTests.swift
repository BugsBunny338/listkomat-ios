import XCTest
@testable import Listkomat

/// Guards the English localization against the catalog source of truth: every
/// translatable key in Shared/Localizable.xcstrings must resolve in the
/// compiled en table. The catalog JSON is parsed from the repo via #filePath
/// (simulator tests share the host filesystem), so the guard cannot silently
/// self-disable on toolchains that skip emitting a source-language cs table —
/// and the shouldTranslate opt-outs come from the catalog itself instead of a
/// mirrored hardcoded list.
final class LocalizationTests: XCTestCase {
    private let appBundle = Bundle(for: CatalogStore.self)

    private struct CatalogKeys {
        let translatable: Set<String>   // expected to have an en translation
        let optOuts: Set<String>        // shouldTranslate: false
    }

    private func loadCatalogKeys() throws -> CatalogKeys {
        let url = URL(fileURLWithPath: #filePath)   // …/ListkomatTests/LocalizationTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        var translatable = Set<String>()
        var optOuts = Set<String>()
        for (key, entry) in strings {
            if entry["shouldTranslate"] as? Bool == false {
                optOuts.insert(key)
            } else {
                translatable.insert(key)
            }
        }
        return CatalogKeys(translatable: translatable, optOuts: optOuts)
    }

    private func stringsTable(for localization: String, table: String = "Localizable") throws -> [String: String] {
        let path = try XCTUnwrap(
            appBundle.path(forResource: table, ofType: "strings",
                           inDirectory: nil, forLocalization: localization),
            "\(table).strings missing for \(localization)"
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }

    /// Plural entries compile to a .stringsdict rather than into .strings, so a
    /// key with variations is absent from `stringsTable` and would otherwise
    /// read as untranslated.
    private func pluralTable(for localization: String, table: String = "Localizable") -> [String: Any] {
        guard let path = appBundle.path(forResource: table, ofType: "stringsdict",
                                        inDirectory: nil, forLocalization: localization),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any]
        else { return [:] }
        return dict
    }

    /// Every literal in one .stringsdict entry, flattened — the key naming the
    /// plural variable is compiler-generated, so the shape isn't worth pinning.
    private func pluralValues(_ entry: Any?) -> Set<String> {
        switch entry {
        case let string as String: return [string]
        case let dict as [String: Any]: return dict.values.reduce(into: []) { $0.formUnion(pluralValues($1)) }
        default: return []
        }
    }

    func testEveryTranslatableKeyHasEnglish() throws {
        let catalog = try loadCatalogKeys()
        let en = try stringsTable(for: "en")
        let missing = catalog.translatable
            .subtracting(en.keys)
            .subtracting(pluralTable(for: "en").keys)
        XCTAssertTrue(missing.isEmpty, "Keys missing English translation: \(missing.sorted())")
        XCTAssertFalse(en.values.contains(""), "English table contains empty translations")
        // A truncated catalog would make the subset check pass vacuously.
        XCTAssertGreaterThan(catalog.translatable.count, 40, "Catalog looks truncated")
    }

    func testSpotTranslations() throws {
        let en = try stringsTable(for: "en")
        XCTAssertEqual(en["Vzhled"], "Appearance")
        XCTAssertEqual(en["Potvrdit nyní"], "Confirm now")
        XCTAssertEqual(en["Funguje s českou SIM kartou."], "Requires a Czech SIM card.")
        XCTAssertEqual(en["Lístek na %@ · %lld Kč"], "Ticket for %1$@ · %2$lld Kč")
        // Pins vehicle-name translations locale-independently (VehicleModelTests
        // can't — localizedName resolves per the test host's language).
        XCTAssertEqual(en["Tramvaj"], "Tram")
        // Cold-start card: the hint explains a ~30 s wait, so it has to read as
        // a sentence in both languages, not a truncated label.
        XCTAssertEqual(en["Připojuji se k živým datům…"], "Connecting to live data…")
        XCTAssertEqual(en["Brno vysílá polohy vozidel přibližně jednou za 30 sekund."],
                       "Brno broadcasts vehicle positions about once every 30 seconds.")
    }

    /// Ticket durations are formatted from `durationMinutes`, so both languages
    /// need real plural forms — the Czech ones accusative, because they always
    /// follow "Lístek na …". Compiled tables are checked rather than the source
    /// catalog: a plural entry that fails to compile is exactly the failure this
    /// has to catch.
    func testDurationPluralsCompileForBothLanguages() throws {
        for (localization, expected) in [
            ("en", ["%lld minute", "%lld minutes", "%lld hour", "%lld hours"]),
            ("cs", ["%lld minutu", "%lld minuty", "%lld minut",
                    "%lld hodinu", "%lld hodiny", "%lld hodin"]),
        ] {
            let plurals = pluralTable(for: localization)
            let values = pluralValues(plurals["%lld minut"]).union(pluralValues(plurals["%lld hodin"]))
            XCTAssertFalse(values.isEmpty, "no duration plurals compiled for \(localization)")
            for form in expected {
                XCTAssertTrue(values.contains(form), "\(localization) is missing the form \(form)")
            }
        }
    }

    func testInfoPlistLocationUsageLocalized() throws {
        let table = try stringsTable(for: "en", table: "InfoPlist")
        XCTAssertNotNil(table["NSLocationWhenInUseUsageDescription"])
    }
}
