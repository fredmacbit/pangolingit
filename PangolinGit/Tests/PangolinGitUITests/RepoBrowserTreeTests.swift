import XCTest
@testable import PangolinGitCore

#if canImport(PangolinGit)
@testable import PangolinGit

final class RepoBrowserTreeTests: XCTestCase {
    func testBuildsNestedFoldersFirst() {
        let output = [
            "100644 blob aaa 10\tREADME.md",
            "040000 tree bbb -\tsrc",
            "040000 tree ccc -\tsrc/app",
            "100644 blob ddd 20\tsrc/app/main.swift",
            "100644 blob eee 30\tsrc/a.swift"
        ].joined(separator: "\0") + "\0"
        let roots = RepoBrowserWindowController.buildTree(fromLsTree: output)
        XCTAssertEqual(roots.map(\.name), ["src", "README.md"])
        let src = roots[0]
        XCTAssertEqual(src.sha, "bbb")
        XCTAssertEqual(src.children.map(\.name), ["app", "a.swift"])
        XCTAssertEqual(src.children[0].children.map(\.fullPath), ["src/app/main.swift"])
    }
}
#endif
