import XCTest
@testable import PangolinGitCore

#if canImport(PangolinGit)
@testable import PangolinGit

/// Logic behind the Check for Modifications summary and the Rename dialog's destination checks.
final class WorkingTreeDialogTests: XCTestCase {

    func testStatusSummaryCountsLinesAndFiles() {
        let items = [
            GitItemStatusInfo(path: "a.swift", status: .modified),
            GitItemStatusInfo(path: "b.swift", status: .stagedModified, stagedStatus: .modified),
            GitItemStatusInfo(path: "new.swift", status: .added, stagedStatus: .added),
            GitItemStatusInfo(path: "gone.swift", status: .missing),
            GitItemStatusInfo(path: "tmp.txt", status: .untracked)
        ]
        let counts = ["a.swift": GitLineCount(added: 3, removed: 1), "new.swift": GitLineCount(added: 10, removed: 0),
                      "img.png": GitLineCount(added: nil, removed: nil)]
        XCTAssertEqual(StatusSummary.text(for: items, lineCounts: counts),
                       "Lines: +13 −1 · Files: 2 modified, 1 added, 1 deleted, 1 unversioned")
        XCTAssertEqual(StatusSummary.text(for: [], lineCounts: [:]), "No changes")
    }

    func testRenameDestinationStaysInsideWorkingTree() {
        let root = PangolinPath("/repo")
        XCTAssertEqual(RenameWindowController.resolve("src/new.txt", root: root), "src/new.txt")
        XCTAssertEqual(RenameWindowController.resolve("src/../docs/x.md", root: root), "docs/x.md")
        XCTAssertEqual(RenameWindowController.resolve("/repo/a/b", root: root), "a/b")
        XCTAssertEqual(RenameWindowController.resolve(".", root: root), "")
        XCTAssertNil(RenameWindowController.resolve("../outside.txt", root: root))
        XCTAssertNil(RenameWindowController.resolve("/elsewhere/x", root: root))
        XCTAssertNil(RenameWindowController.resolve("  ", root: root))

        XCTAssertNil(RenameWindowController.validationError(forDestination: "src/new.txt"))
        XCTAssertNotNil(RenameWindowController.validationError(forDestination: ".git/config"))
        XCTAssertNotNil(RenameWindowController.validationError(forDestination: "a:b"))
    }
}
#endif
