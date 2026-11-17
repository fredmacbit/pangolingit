import XCTest
@testable import PangolinGitCore

#if canImport(PangolinGit)
@testable import PangolinGit

@MainActor
final class DiffViewTests: XCTestCase {
    func testCompareRevisionsParsesRenamesAndBinaries() {
        let nameStatus = "M\0src/a.swift\0R087\0old/name.txt\0new/name.txt\0A\0logo.png\0"
        let numstat = "3\t1\tsrc/a.swift\0" + "2\t2\t\0old/name.txt\0new/name.txt\0" + "-\t-\tlogo.png\0"
        let entries = FileDiffWindowController.parseDiffOutput(nameStatusZ: nameStatus, numstat: numstat)
        XCTAssertEqual(entries.map(\.path), ["src/a.swift", "new/name.txt", "logo.png"])
        XCTAssertEqual(entries[1].oldPath, "old/name.txt")
        XCTAssertEqual(entries[1].displayPath, "old/name.txt → new/name.txt")
        XCTAssertEqual(entries[1].linesAdded, 2)
        XCTAssertEqual(entries[0].linesAdded, 3)
        XCTAssertTrue(entries[2].isBinary)
    }

    func testSideBySideViewNavigatesDifferences() {
        let view = SideBySideDiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.collapseUnchanged = false
        let context = (1...40).map { " line \($0)" }
        let diff = (["@@ -1,42 +1,42 @@", "-old a", "+new a"] + context + ["-old b", "+new b"]).joined(separator: "\n")
        view.setDiff(rawUnifiedText: diff)
        XCTAssertEqual(view.blocks.count, 2)
        view.goToFirstDifference()
        XCTAssertEqual(view.currentBlockIndex, 0)
        view.goToNextDifference()
        XCTAssertEqual(view.currentBlockIndex, 1)
        XCTAssertEqual(view.blockIndex(containing: view.blocks[1].lowerBound), 1)
        XCTAssertTrue(view.goToLine(20))
    }

    func testCollapsedViewExpandsForGoToLine() {
        let view = SideBySideDiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.collapseUnchanged = true
        let context = (1...40).map { " line \($0)" }
        view.setDiff(rawUnifiedText: (["@@ -1,41 +1,41 @@", "-old", "+new"] + context).joined(separator: "\n"))
        XCTAssertTrue(view.rows.contains { $0.kind == .fold })
        XCTAssertTrue(view.goToLine(30))
        XCTAssertFalse(view.collapseUnchanged)
    }
}
#endif
