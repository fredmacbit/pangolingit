import XCTest
@testable import PangolinGitCore

final class ConfigManagerTests: XCTestCase {
    
    private var testSuiteName: String!
    private var config: ConfigManager!
    
    override func setUp() {
        super.setUp()
        testSuiteName = "test.suite.\(UUID().uuidString)"
        config = ConfigManager(suiteName: testSuiteName)
    }
    
    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: testSuiteName)
        super.tearDown()
    }
    
    func testDefaultValues() {
        XCTAssertEqual(config.gitExecutablePath, "") // empty = auto-detect
        XCTAssertTrue(config.showUnversionedOverlay)
        XCTAssertFalse(config.showIgnoredOverlay)
        XCTAssertEqual(config.recursiveStatusDepth, 3)
        XCTAssertEqual(config.progressAutoClose, .manual)
        XCTAssertFalse(config.defaultCommitAll)
        XCTAssertTrue(config.confirmOnRevert)
        XCTAssertEqual(config.maxRecentHistory, 25)
        XCTAssertEqual(config.credentialHelper, "osxkeychain")
    }
    
    func testContextMenuToggles() {
        XCTAssertTrue(config.isContextMenuEnabled(for: "commit"))
        
        config.setContextMenuEnabled(false, for: "commit")
        XCTAssertFalse(config.isContextMenuEnabled(for: "commit"))
        
        config.setContextMenuEnabled(true, for: "commit")
        XCTAssertTrue(config.isContextMenuEnabled(for: "commit"))
    }
    
    func testColorsConfiguration() {
        XCTAssertEqual(config.diffAddedColorHex, "#28A745")
        XCTAssertEqual(config.diffDeletedColorHex, "#D73A49")
        XCTAssertEqual(config.diffModifiedColorHex, "#0366D6")
        
        config.diffAddedColorHex = "#00FF00"
        XCTAssertEqual(config.diffAddedColorHex, "#00FF00")
    }
    
    func testRecentSavedData() {
        XCTAssertTrue(config.recentCommitMessages.isEmpty)
        
        config.addRecentCommitMessage("Fix issue #123")
        config.addRecentCommitMessage("Update documentation")
        
        XCTAssertEqual(config.recentCommitMessages.count, 2)
        XCTAssertEqual(config.recentCommitMessages.first, "Update documentation")
        
        config.clearRecentCommitMessages()
        XCTAssertTrue(config.recentCommitMessages.isEmpty)
    }
    
    func testExternalTools() {
        XCTAssertEqual(config.externalDiffTool, "")
        config.externalDiffTool = "/usr/local/bin/bcomp"
        XCTAssertEqual(config.externalDiffTool, "/usr/local/bin/bcomp")
    }
}
