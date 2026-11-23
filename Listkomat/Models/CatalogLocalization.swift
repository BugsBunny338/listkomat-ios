import Foundation

/// Per-language overrides carried by the catalog, keyed by language code ("en").
///
/// Czech is the catalog's source language and lives in the plain `name`/`note`
/// fields, so anything without an override falls back to Czech rather than to
/// nothing. The block is additive on purpose: the catalog is fetched by every
/// build ever shipped, and older ones simply ignore the unknown `i18n` key.
struct CatalogText: Codable, Hashable {
    let name: String?
    let note: String?
}

enum CatalogLanguage {
    /// The language the UI is actually running in — not the device region. A
    /// phone in Czechia set to English has to read the English catalog strings,
    /// and `preferredLocalizations` resolves against what the bundle ships.
    /// Narrowed to the base code so "en-GB" still matches an "en" override.
    static var current: String { base(of: Bundle.main.preferredLocalizations.first) }

    static func base(of tag: String?) -> String {
        guard let tag, !tag.isEmpty else { return "cs" }
        return String(tag.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }
}

extension Optional where Wrapped == String {
    /// Treats an empty override as absent, so a blank catalog string can't blank
    /// out the Czech text it was meant to translate.
    fileprivate var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

extension City {
    var localizedName: String { localizedName(in: CatalogLanguage.current) }

    func localizedName(in language: String) -> String {
        i18n?[language]?.name.nonEmpty ?? name
    }
}

extension Ticket {
    var localizedNote: String? { localizedNote(in: CatalogLanguage.current) }

    func localizedNote(in language: String) -> String? {
        i18n?[language]?.note.nonEmpty ?? note.nonEmpty
    }

    typealias DurationUnit = TicketDuration.Unit

    var durationUnit: DurationUnit { TicketDuration.unit(minutes: durationMinutes) }

    /// Duration in the user's language, formatted from `durationMinutes` rather
    /// than taken from the catalog's Czech `duration` label (see `TicketDuration`).
    var localizedDuration: String {
        guard durationMinutes > 0 else { return duration }   // malformed catalog row
        return TicketDuration.label(minutes: durationMinutes)
    }
}
