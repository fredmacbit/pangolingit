import XCTest
@testable import PangolinGit

/// The string catalog is compiled into the app for every shipped language (QF-25), so dialogs can
/// switch to `String(localized:)` (CC-06) and the language choice in Settings ▸ General has an effect.
final class LocalizationCatalogTests: XCTestCase {

    func testCatalogIsCompiledForEachLanguage() throws {
        let bundle = Bundle.main
        for language in ["de", "fr", "nl", "ja", "zh-Hans"] {
            XCTAssertTrue(bundle.localizations.contains(language), "missing localization \(language)")
            let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language),
                                     "no compiled Localizable.strings for \(language)")
            let table = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
            XCTAssertNotNil(table["Show Log"], "Show Log not translated for \(language)")
        }
    }

    func testLocalizedLookupFallsBackToKey() {
        // A key without an entry (most UI text until CC-06) must come back unchanged, not empty.
        XCTAssertEqual(String(localized: "PangolinGit-untranslated-sample"), "PangolinGit-untranslated-sample")
    }
}
