import XCTest
import Cocoa
@testable import PangolinGitCore

#if canImport(PangolinGit)
@testable import PangolinGit
#endif

/// UI Snapshot and Layout Hierarchy Tests for PangolinGit Dialogs (Phase 13.3).
final class SnapshotTests: XCTestCase {
    
    private var tempRepoURL: URL!
    private var testPath: PangolinPath!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRepoURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRepoURL, withIntermediateDirectories: true)
        testPath = PangolinPath(tempRepoURL.path)
    }
    
    override func tearDownWithError() throws {
        if let temp = tempRepoURL {
            try? FileManager.default.removeItem(at: temp)
        }
        try super.tearDownWithError()
    }
    
    @MainActor
    func testSettingsWindowLayout() throws {
        let settings = SettingsWindowController()
        XCTAssertNotNil(settings.window)
        XCTAssertEqual(settings.window?.title, "PangolinGit Settings")
        XCTAssertGreaterThan(settings.window?.frame.width ?? 0, 400)
        XCTAssertGreaterThan(settings.window?.frame.height ?? 0, 300)
    }
    
    @MainActor
    func testRenameDialogLayout() throws {
        let rename = RenameWindowController(repositoryPath: testPath, sourceRelativePath: "test.txt")
        XCTAssertNotNil(rename.window)
        XCTAssertTrue(rename.window?.title.contains("Rename") ?? false)
        XCTAssertNotNil(rename.window?.contentView)
        // Controls sit in stack views, so count all descendants.
        func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        XCTAssertGreaterThan(rename.window?.contentView.map(descendants)?.filter { $0 is NSControl }.count ?? 0, 4)
    }
    
    @MainActor
    func testRemoveDialogLayout() throws {
        let remove = RemoveWindowController(repositoryPath: testPath, targetPaths: ["file1.txt", "file2.txt"])
        XCTAssertNotNil(remove.window)
        XCTAssertTrue(remove.window?.title.contains("Remove") ?? false)
        XCTAssertNotNil(remove.window?.contentView)
    }
    
    @MainActor
    func testRequestPullDialogLayout() throws {
        let reqPull = RequestPullWindowController(repositoryPath: testPath)
        XCTAssertNotNil(reqPull.window)
        XCTAssertTrue(reqPull.window?.title.contains("Request Pull") ?? false)
        XCTAssertNotNil(reqPull.window?.contentView)
    }
    
    @MainActor
    func testLFSLocksDialogLayout() throws {
        let lfs = LFSLocksWindowController(repositoryPath: testPath)
        XCTAssertNotNil(lfs.window)
        XCTAssertTrue(lfs.window?.title.contains("LFS Locks") ?? false)
        XCTAssertNotNil(lfs.window?.contentView)
    }
}
