import XCTest
@testable import PangolinGitCore

final class BugtraqConfigTests: XCTestCase {

    private func config(message: String = "Issue: %BUGID%", append: Bool = true, regex: String = "") -> BugtraqConfig {
        BugtraqConfig(values: [
            "bugtraq.url": "https://example.org/issues/%BUGID%",
            "bugtraq.message": message,
            "bugtraq.append": append ? "true" : "false",
            "bugtraq.logregex": regex
        ])
    }

    func testDefaults() {
        let empty = BugtraqConfig(values: [:])
        XCTAssertFalse(empty.isActive)
        XCTAssertTrue(empty.numericOnly)
        XCTAssertTrue(empty.append)
        XCTAssertEqual(empty.displayLabel, "Bug-ID / Issue-Nr:")
    }

    func testMessageAssemblyAppendAndTop() {
        XCTAssertEqual(config().messageWithBugID("Fix crash\n", bugID: "12"), "Fix crash\nIssue: 12")
        XCTAssertEqual(config(append: false).messageWithBugID("Fix crash", bugID: "12,13"), "Issue: 12,13\nFix crash")
        XCTAssertEqual(config().messageWithBugID("Fix", bugID: "  "), "Fix")
    }

    func testBugIDRoundTrip() {
        let bugtraq = config()
        let assembled = bugtraq.messageWithBugID("Subject\n\nBody", bugID: "77")
        let split = bugtraq.bugID(fromMessage: assembled)
        XCTAssertEqual(split?.bugID, "77")
        XCTAssertEqual(split?.message, "Subject\n\nBody")
    }

    func testNumericValidation() {
        XCTAssertTrue(config().isValidBugID("12, 13"))
        XCTAssertFalse(config().isValidBugID("ABC-1"))
    }

    func testSingleRegexUsesGroupOne() {
        let bugtraq = config(regex: "#(\\d+)")
        let refs = bugtraq.issueReferences(in: "Fixes #12 and #345")
        XCTAssertEqual(refs.map(\.id), ["12", "345"])
        XCTAssertEqual(refs.first?.url?.absoluteString, "https://example.org/issues/12")
    }

    func testTwoLineRegex() {
        let bugtraq = config(regex: "[Ii]ssues?:?(\\s*(,|and)?\\s*#\\d+)+\n(\\d+)")
        let refs = bugtraq.issueReferences(in: "This is a test for Issue #33 and #44")
        XCTAssertEqual(refs.map(\.id), ["33", "44"])
    }

    func testMessageLineFallback() {
        let refs = config().issueReferences(in: "Subject\n\nIssue: 5, 6")
        XCTAssertEqual(refs.map(\.id), ["5", "6"])
        XCTAssertTrue(config().issueReferences(in: "No issue here").isEmpty)
    }

    func testProjectSettingsParsing() {
        let settings = ProjectSettings(values: ["tgit.logminsize": "10", "tgit.logwidthmarker": "72",
                                                "tgit.warnnosignedoffby": "true", "tgit.projectlanguage": "-1"])
        XCTAssertEqual(settings.logMinSize, 10)
        XCTAssertEqual(settings.logWidthMarker, 72)
        XCTAssertTrue(settings.warnNoSignedOffBy)
        XCTAssertTrue(settings.spellCheckingDisabled)
    }

    func testConfigListParsing() {
        let parsed = GitConfigStore.parseListZ("bugtraq.url\nhttps://x/%BUGID%\0core.bare\nfalse\0flag\0Bugtraq.Number\ntrue\0")
        XCTAssertEqual(parsed["bugtraq.url"], "https://x/%BUGID%")
        XCTAssertEqual(parsed["flag"], "true")
        XCTAssertEqual(parsed["bugtraq.number"], "true")
    }

    func testProjectScopeReadsTgitconfig() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bugtraq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = PangolinPath(dir.path)
        try GitCLIRunner.run(arguments: ["init", "-q"], workingDirectory: repo)
        let store = GitConfigStore(repository: repo)
        try await store.set("bugtraq.message", to: "Project %BUGID%", in: .project)
        try await store.set("bugtraq.message", to: "Local %BUGID%", in: .local)
        let projectMessage = await store.value("bugtraq.message", in: .project)
        XCTAssertEqual(projectMessage, "Project %BUGID%")
        // Local overrides the project file, as in TortoiseGit.
        let effective = await store.bugtraq()
        XCTAssertEqual(effective.message, "Local %BUGID%")
        try await store.set("bugtraq.message", to: nil, in: .local)
        let afterUnset = await store.bugtraq()
        XCTAssertEqual(afterUnset.message, "Project %BUGID%")
    }
}
