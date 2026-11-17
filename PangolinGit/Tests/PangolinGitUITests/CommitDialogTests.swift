import XCTest
import Cocoa
@testable import PangolinGitCore

#if canImport(PangolinGit)
@testable import PangolinGit
#endif

/// Commit dialog logic that lives in the app target (quick-select groups, staging states, the
/// patch pane's view of new files) plus a layout smoke test.
final class CommitDialogTests: XCTestCase {

    private func info(_ path: String, _ status: GitItemStatus, staged: GitItemStatus? = nil, submodule: Bool = false) -> GitItemStatusInfo {
        GitItemStatusInfo(path: path, status: status, stagedStatus: staged, isSubmodule: submodule)
    }

    func testQuickSelectGroups() {
        let added = info("a", .added, staged: .added)
        let modified = info("m", .modified)
        let missing = info("d", .missing)
        let untracked = info("u", .untracked)
        let submodule = info("s", .modified, submodule: true)

        XCTAssertTrue(QuickSelect.added.matches(added, skipSubmodules: false))
        XCTAssertFalse(QuickSelect.added.matches(modified, skipSubmodules: false))
        XCTAssertTrue(QuickSelect.deleted.matches(missing, skipSubmodules: false))
        XCTAssertTrue(QuickSelect.unversioned.matches(untracked, skipSubmodules: false))
        XCTAssertFalse(QuickSelect.versioned.matches(untracked, skipSubmodules: false))
        XCTAssertTrue(QuickSelect.modified.matches(submodule, skipSubmodules: false))
        XCTAssertFalse(QuickSelect.modified.matches(submodule, skipSubmodules: true), "submodules are skipped unless asked for")
        XCTAssertTrue(QuickSelect.submodules.matches(submodule, skipSubmodules: true))
        XCTAssertFalse(QuickSelect.files.matches(submodule, skipSubmodules: false))
    }

    @MainActor
    func testStagingStates() {
        XCTAssertTrue(CommitWindowController.isStagedEntry(info("a", .added, staged: .added)))
        XCTAssertFalse(CommitWindowController.isStagedEntry(info("m", .modified)))
        XCTAssertTrue(CommitWindowController.isPartiallyStaged(info("m", .stagedModified, staged: .modified)))
        XCTAssertTrue(CommitWindowController.isPartiallyStaged(info("a", .modified, staged: .added)))
        XCTAssertFalse(CommitWindowController.isPartiallyStaged(info("m", .modified, staged: .modified)))
    }

    @MainActor
    func testNewFileDiffParsesAsOneHunk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("commit-new-\(UUID().uuidString).txt")
        try "one\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let diff = CommitWindowController.newFileDiff(path: "new.txt", url: url)
        let patch = try XCTUnwrap(FileHunkPatch(unifiedDiff: diff))
        XCTAssertEqual(patch.hunks.first?.lines, ["+one", "+two"])
    }

    @MainActor
    func testHistoryMenuTitleUsesFirstLine() {
        XCTAssertEqual(CommitWindowController.menuTitle(for: "\nSubject\n\nBody"), "Subject")
        XCTAssertEqual(CommitWindowController.menuTitle(for: String(repeating: "x", count: 100)).count, 70)
    }

    @MainActor
    func testWindowLaysOut() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("commit-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try GitCLIRunner.run(arguments: ["init", "-b", "main"], workingDirectory: PangolinPath(folder.path))

        let controller = CommitWindowController(repositoryPath: PangolinPath(folder.path), selection: ["sub"])
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.title.contains("Commit"))
        XCTAssertGreaterThan(controller.messageTextView.enclosingScrollView?.frame.height ?? 0, 50)
        XCTAssertGreaterThan(controller.statusListView.frame.height, 100)
        XCTAssertFalse(controller.wholeProjectCheckbox.isHidden, "opened for a selection, so Whole Project is offered")
        XCTAssertEqual(controller.commitButton.keyEquivalent, "\r")
        controller.setPatchPaneVisible(true)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.patchView.frame.width, 150)
        controller.setPatchPaneVisible(false)
        XCTAssertNil(controller.patchView.superview)
        window.close()
    }
}
