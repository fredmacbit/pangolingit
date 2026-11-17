import XCTest
@testable import PangolinGitCore

#if canImport(PangolinGit)
@testable import PangolinGit

@MainActor
final class PatchToolsTests: XCTestCase {
    func testMailtoURLCarriesRecipientsSubjectBodyAndCC() throws {
        let url = try XCTUnwrap(SendMailWindowController.mailtoURL(to: ["a@example.com", "b@example.com"], cc: ["c@example.com"],
                                                                     subject: "[PATCH] Fix & test", body: "line 1\nline 2"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, "a@example.com,b@example.com")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["subject"], "[PATCH] Fix & test")
        XCTAssertEqual(query["body"], "line 1\nline 2")
        XCTAssertEqual(query["cc"], "c@example.com")
    }

    func testPatchColouringKeepsText() {
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new"
        XCTAssertEqual(PatchViewerWindowController.colourised(text).string, text + "\n")
    }

    func testNewCommandsAreRoutable() {
        for name in ["formatpatch", "applypatchserial", "sendmail", "revisiongraph"] {
            XCTAssertNotNil(PangolinCommand(rawValue: name), name)
        }
        XCTAssertTrue(PangolinCommand.sendMail.worksOutsideRepository)
    }
}
#endif
