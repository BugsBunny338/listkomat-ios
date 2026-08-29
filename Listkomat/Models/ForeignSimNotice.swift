import Foundation

/// Decides whether to show the "you need a Czech SIM" note on the purchase
/// screen (issue #15).
///
/// Premium-SMS tickets only work from a Czech operator's SIM, and the failure is
/// invisible to us: the SMS usually "sends" fine from a roaming SIM, the ticket
/// simply never arrives, and iOS apps cannot read incoming SMS. So the only
/// defence is telling people up front.
///
/// SIM country is **not** detectable — `CTCarrier` was deprecated in iOS 16 and
/// returns placeholders (`--`, `65535`) since 16.4, with no replacement. What is
/// readable is the UI language and the App Store storefront, so those stand in
/// as a cheap "probably foreign" hint.
///
/// It informs, it never blocks: the target audience includes expats with a
/// foreign Apple ID *and* a perfectly good Czech SIM, who would be
/// false-positived by anything stricter.
enum ForeignSimNotice {
    private static let czechLanguage = "cs"
    private static let czechStorefront = "CZE"

    /// - Parameters:
    ///   - uiLanguage: the language the app is actually running in
    ///     (`Bundle.main.preferredLocalizations.first`), possibly region-qualified.
    ///   - storefrontCountry: ISO 3166-1 alpha-3 App Store storefront, or nil
    ///     while StoreKit has not resolved one yet.
    ///   - dismissed: whether the user already dismissed the note (persisted).
    static func shouldShow(uiLanguage: String?, storefrontCountry: String?, dismissed: Bool) -> Bool {
        guard !dismissed else { return false }
        if let uiLanguage, !isCzech(language: uiLanguage) { return true }
        // nil storefront means "not resolved yet", not "foreign" — treating it as
        // foreign would flash the note at every Czech user on launch.
        if let storefrontCountry,
           storefrontCountry.caseInsensitiveCompare(czechStorefront) != .orderedSame { return true }
        return false
    }

    private static func isCzech(language: String) -> Bool {
        guard let base = language.split(separator: "-").first else { return false }
        return base.caseInsensitiveCompare(czechLanguage) == .orderedSame
    }
}
