import XCTest
@testable import PangolinGitCore

final class RepositoryStatusSnapshotTests: XCTestCase {

    private func makeSnapshot() -> RepositoryStatusSnapshot {
        let output = [
            "1 .M N... 100644 100644 100644 aaaa bbbb src/app/main.swift",
            "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc src/conflict file.txt",
            "? build/",
            "? notes.txt",
            "! cache/"
        ].joined(separator: "\0") + "\0"
        let items = GitRepository.parsePorcelainV2(output: output)
        return RepositoryStatusSnapshot(root: PangolinPath("/repo"), items: items)
    }

    func testFileBadges() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.lookup(relativePath: "src/app/main.swift", isDirectory: false).badge, .modified)
        XCTAssertEqual(snapshot.lookup(relativePath: "src/conflict file.txt", isDirectory: false).badge, .conflicted)
        XCTAssertEqual(snapshot.lookup(relativePath: "notes.txt", isDirectory: false).badge, .unversioned)
        XCTAssertEqual(snapshot.lookup(relativePath: "README.md", isDirectory: false).badge, .normal)
    }

    func testFolderAggregationPrefersConflicts() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.lookup(relativePath: "src/app", isDirectory: true).badge, .modified)
        XCTAssertEqual(snapshot.lookup(relativePath: "src", isDirectory: true).badge, .conflicted)
        XCTAssertEqual(snapshot.lookup(relativePath: "", isDirectory: true).badge, .conflicted)
        XCTAssertEqual(snapshot.lookup(relativePath: "docs", isDirectory: true).badge, .normal)
    }

    func testUntrackedAndIgnoredFoldersCoverDescendants() {
        let snapshot = makeSnapshot()
        XCTAssertEqual(snapshot.lookup(relativePath: "build", isDirectory: true).badge, .unversioned)
        XCTAssertEqual(snapshot.lookup(relativePath: "build/out/a.o", isDirectory: false).badge, .unversioned)
        XCTAssertEqual(snapshot.lookup(relativePath: "cache/x", isDirectory: false).badge, .ignored)
        XCTAssertEqual(snapshot.lookup(relativePath: ".git/index", isDirectory: false).badge, GitBadgeKind.none)
    }
}
