import XCTest
@testable import PangolinGitCore

final class LocalizationTests: XCTestCase {
    
    func testLocalizationHelperFallback() {
        let key = "Git Commit..."
        let localized = LocalizationHelper.localized(key)
        XCTAssertFalse(localized.isEmpty)
    }
    
    func testLayoutDirectionDetection() {
        let isRTL = LocalizationHelper.isRightToLeft
        XCTAssertFalse(isRTL) // In typical test environments (en), isRTL is false
    }
}
