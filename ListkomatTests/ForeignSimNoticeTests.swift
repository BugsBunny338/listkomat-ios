import XCTest
@testable import Listkomat

/// The purchase-screen note for users who probably can't buy (issue #15).
/// SIM country is undetectable on iOS 16.4+ (CTCarrier returns placeholders),
/// so the heuristic leans on the two signals we *can* read: the UI language and
/// the App Store storefront. It only ever informs — nothing here blocks a purchase.
final class ForeignSimNoticeTests: XCTestCase {

    func testCzechUserOnCzechStorefrontSeesNothing() {
        XCTAssertFalse(ForeignSimNotice.shouldShow(uiLanguage: "cs", storefrontCountry: "CZE", dismissed: false))
    }

    func testEnglishUIShowsTheNotice() {
        XCTAssertTrue(ForeignSimNotice.shouldShow(uiLanguage: "en", storefrontCountry: "CZE", dismissed: false))
    }

    func testForeignStorefrontShowsTheNoticeEvenWithCzechUI() {
        XCTAssertTrue(ForeignSimNotice.shouldShow(uiLanguage: "cs", storefrontCountry: "USA", dismissed: false))
    }

    func testDismissedNoticeNeverComesBack() {
        XCTAssertFalse(ForeignSimNotice.shouldShow(uiLanguage: "en", storefrontCountry: "USA", dismissed: true))
    }

    /// StoreKit hands us nil before the storefront resolves. Unknown must not
    /// count as foreign, or every Czech user would flash the note at launch.
    func testUnknownStorefrontAloneDoesNotTrigger() {
        XCTAssertFalse(ForeignSimNotice.shouldShow(uiLanguage: "cs", storefrontCountry: nil, dismissed: false))
    }

    func testUnknownStorefrontStillShowsForEnglishUI() {
        XCTAssertTrue(ForeignSimNotice.shouldShow(uiLanguage: "en", storefrontCountry: nil, dismissed: false))
    }

    /// preferredLocalizations can carry a region ("cs-CZ") — still Czech.
    func testRegionQualifiedCzechCountsAsCzech() {
        XCTAssertFalse(ForeignSimNotice.shouldShow(uiLanguage: "cs-CZ", storefrontCountry: "CZE", dismissed: false))
    }

    /// A nil UI language means the bundle told us nothing; don't invent a foreigner.
    func testUnknownLanguageAndStorefrontShowsNothing() {
        XCTAssertFalse(ForeignSimNotice.shouldShow(uiLanguage: nil, storefrontCountry: nil, dismissed: false))
    }

    func testStorefrontComparisonIsCaseInsensitive() {
        XCTAssertFalse(ForeignSimNotice.shouldShow(uiLanguage: "cs", storefrontCountry: "cze", dismissed: false))
    }
}
