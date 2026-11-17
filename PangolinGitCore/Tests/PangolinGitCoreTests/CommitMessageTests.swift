import XCTest
@testable import PangolinGitCore

final class CommitMessageTests: XCTestCase {

    // MARK: - Sign-off

    func testIdentityParsesGitVarOutput() throws {
        let identity = try XCTUnwrap(CommitMessage.identity(fromIdent: "Jane Doe <jane@example.com> 1700000000 +0100\n"))
        XCTAssertEqual(identity.name, "Jane Doe")
        XCTAssertEqual(identity.email, "jane@example.com")
        XCTAssertNil(CommitMessage.identity(fromIdent: "garbage"))
    }

    func testSignOffIsSeparatedByBlankLineFromBody() {
        let line = CommitMessage.signOffLine(name: "Jane", email: "j@x")
        XCTAssertEqual(CommitMessage.appendingSignOff("Fix crash\n\nDetails  \n\n", line: line),
                       "Fix crash\n\nDetails\n\nSigned-off-by: Jane <j@x>\n")
    }

    func testSignOffJoinsExistingTrailerBlockAndIsNotDuplicated() {
        let line = "Signed-off-by: Jane <j@x>"
        let message = "Fix\n\nReviewed-by: Bob <b@x>"
        let signed = CommitMessage.appendingSignOff(message, line: line)
        XCTAssertEqual(signed, "Fix\n\nReviewed-by: Bob <b@x>\nSigned-off-by: Jane <j@x>\n")
        XCTAssertEqual(CommitMessage.appendingSignOff(signed, line: line), signed)
        XCTAssertEqual(CommitMessage.appendingSignOff("", line: line), line + "\n")
    }

    // MARK: - Cleanup

    func testCleanupStripsCommentsAndWhitespaceButKeepsIssueReferences() {
        let raw = "\n\nSubject   \n# Please enter the message\n#\n\n\n#123 is fixed\nBody\t\n\n"
        XCTAssertEqual(CommitMessage.cleanup(raw), "Subject\n\n#123 is fixed\nBody")
    }

    func testCleanupHonoursCommentChar() {
        XCTAssertEqual(CommitMessage.cleanup("A\n; note\n# kept", commentChar: ";"), "A\n# kept")
    }

    func testUnchangedTemplateDetection() {
        let template = "Summary:\n\n# Describe why\n"
        XCTAssertTrue(CommitMessage.isUnchangedTemplate(message: "Summary:\n# Describe why", template: template))
        XCTAssertFalse(CommitMessage.isUnchangedTemplate(message: "Summary: fix", template: template))
        XCTAssertFalse(CommitMessage.isUnchangedTemplate(message: "", template: "# only comments"))
    }

    func testConflictMarkerDetection() {
        XCTAssertTrue(CommitMessage.containsConflictMarkers("a\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> topic\n"))
        XCTAssertFalse(CommitMessage.containsConflictMarkers("a\n<<<<<<< not closed\n"))
        XCTAssertFalse(CommitMessage.containsConflictMarkers("x <<<<<<< inline\n>>>>>>> y"))
    }

    // MARK: - Markup

    func testMarkupRanges() {
        let text = "a *bold* and ^it^ and _under_ but snake_case_name and 2*3*4"
        let found = CommitMessage.markupRanges(in: text).map { ((text as NSString).substring(with: $0.range), $0.style) }
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.contains { $0.0 == "*bold*" && $0.1 == .bold })
        XCTAssertTrue(found.contains { $0.0 == "^it^" && $0.1 == .italic })
        XCTAssertTrue(found.contains { $0.0 == "_under_" && $0.1 == .underline })
    }

    // MARK: - Bugtraq

    func testBugtraqRequiresMessageWithPlaceholder() {
        XCTAssertNil(BugtraqSettings(config: [:]))
        XCTAssertNil(BugtraqSettings(config: ["bugtraq.message": "Issue"]))
    }

    func testBugtraqAppendsOrPrependsLine() throws {
        let appending = try XCTUnwrap(BugtraqSettings(config: ["bugtraq.message": "Issue: %BUGID%"]))
        XCTAssertEqual(appending.label, "Bug-ID / Issue-Nr:")
        XCTAssertTrue(appending.numbersOnly)
        XCTAssertEqual(appending.apply(id: "12, 13", to: "Fix\n"), "Fix\nIssue: 12,13")
        XCTAssertEqual(appending.apply(id: "", to: "Fix"), "Fix")
        XCTAssertEqual(appending.apply(id: "12", to: "Fix\nIssue: 12"), "Fix\nIssue: 12")
        XCTAssertTrue(appending.isValid(id: "1, 2"))
        XCTAssertFalse(appending.isValid(id: "ABC-1"))

        let prepending = try XCTUnwrap(BugtraqSettings(config: [
            "bugtraq.message": "[%BUGID%]", "bugtraq.append": "false", "bugtraq.number": "false",
            "bugtraq.label": "Ticket:", "bugtraq.warnifnoissue": "true"
        ]))
        XCTAssertEqual(prepending.apply(id: "ABC-1", to: "Fix"), "[ABC-1]\nFix")
        XCTAssertTrue(prepending.isValid(id: "ABC-1"))
        XCTAssertTrue(prepending.warnIfNoIssue)
        XCTAssertEqual(prepending.label, "Ticket:")
    }

    // MARK: - Completion

    func testIdentifiersPerLanguage() {
        let swift = "final class CommitWindow {\n    func reloadStatus() {}\n    let messageFile = 1\n}"
        XCTAssertEqual(CommitAutoCompletion.identifiers(in: swift, fileExtension: "swift"),
                       ["CommitWindow", "reloadStatus", "messageFile"])
        let python = "class Parser:\n    def parse_line(self):\n        pass"
        XCTAssertEqual(CommitAutoCompletion.identifiers(in: python, fileExtension: "py"), ["Parser", "parse_line"])
        XCTAssertTrue(CommitAutoCompletion.identifiers(in: "struct Foo {", fileExtension: "cpp").contains("Foo"))
        XCTAssertTrue(CommitAutoCompletion.identifiers(in: "anything", fileExtension: "txt").isEmpty)
    }

    func testSnippetsAndCompletions() {
        let snippets = CommitAutoCompletion.parseSnippets("# comment\nsob=Signed-off-by: me\\nline2\nbad line\n=x\n")
        XCTAssertEqual(snippets, ["sob": "Signed-off-by: me\nline2"])
        let words: Set<String> = ["reloadStatus", "reloadPatchView", "Reload", "other"]
        XCTAssertEqual(CommitAutoCompletion.completions(for: "rel", in: words), ["Reload", "reloadStatus", "reloadPatchView"])
        XCTAssertEqual(CommitAutoCompletion.completions(for: "reloadStatus", in: words), [])
    }

    // MARK: - Hunks

    private let twoHunkDiff = """
    diff --git a/f.txt b/f.txt
    index 1111111..2222222 100644
    --- a/f.txt
    +++ b/f.txt
    @@ -1,3 +1,3 @@
    -one
    +ONE
     two
     three
    @@ -8,2 +8,3 @@
     eight
     nine
    +ten

    """

    func testHunkPatchContainsHeaderAndOneHunk() throws {
        let patch = try XCTUnwrap(FileHunkPatch(unifiedDiff: twoHunkDiff))
        XCTAssertEqual(patch.hunks.count, 2)
        XCTAssertEqual(patch.patch(forHunk: 1), """
        diff --git a/f.txt b/f.txt
        index 1111111..2222222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -8,2 +8,3 @@
         eight
         nine
        +ten

        """)
        XCTAssertNil(FileHunkPatch(unifiedDiff: ""))
        XCTAssertNil(FileHunkPatch(unifiedDiff: "diff --git a/b b/b\nBinary files a/b and b/b differ\n"))
    }

    // MARK: - Commit plan

    func testPlanWithPathsUsesOnly() {
        var plan = CommitPlan(messageFile: "/tmp/msg")
        plan.newBranch = "feature/x"
        plan.pathsToStage = ["new.txt"]
        plan.commitPaths = ["new.txt", "old.txt"]
        plan.author = "A <a@x>"
        plan.date = "now"
        plan.amend = true
        XCTAssertEqual(plan.commands(), [
            ["checkout", "-b", "feature/x"],
            ["add", "-A", "--", "new.txt"],
            ["commit", "-F", "/tmp/msg", "--amend", "--author=A <a@x>", "--date=now", "--only", "--", "new.txt", "old.txt"]
        ])
    }

    func testPlanForIndexAndMessageOnly() {
        var index = CommitPlan(messageFile: "m")
        XCTAssertEqual(index.commands(), [["commit", "-F", "m"]])
        index.allowEmpty = true
        index.commitPaths = []
        XCTAssertEqual(index.commands(), [["commit", "-F", "m", "--allow-empty", "--only"]])
    }

    // MARK: - History

    func testRecentMessagesAreKeptPerRepository() {
        let suite = "test.suite.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let config = ConfigManager(suiteName: suite)
        config.addRecentCommitMessage("one", forRepository: "/a")
        config.addRecentCommitMessage("two", forRepository: "/a")
        config.addRecentCommitMessage("one", forRepository: "/a")
        config.addRecentCommitMessage("other", forRepository: "/b")
        XCTAssertEqual(config.recentCommitMessages(forRepository: "/a"), ["one", "two"])
        XCTAssertEqual(config.recentCommitMessages(forRepository: "/b"), ["other"])
        XCTAssertEqual(config.recentCommitMessages.count, 3, "the global list still feeds Saved Data")
        config.setRecentCommitMessages(["two"], forRepository: "/a")
        XCTAssertEqual(config.recentCommitMessages(forRepository: "/a"), ["two"])
        config.clearRecentCommitMessages()
        XCTAssertTrue(config.recentCommitMessages(forRepository: "/b").isEmpty)
    }

    func testDateArgument() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(CommitPlan.dateArgument(date, timeZone: TimeZone(secondsFromGMT: 3600)!), "2023-11-14T23:13:20+0100")
    }
}
