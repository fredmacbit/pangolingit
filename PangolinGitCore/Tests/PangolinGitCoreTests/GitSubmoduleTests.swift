import XCTest
@testable import PangolinGitCore

final class GitSubmoduleTests: XCTestCase {
    func testParseStatusAndGitmodules() {
        let status = """
        -1111111111111111111111111111111111111111 libs/a b
        +2222222222222222222222222222222222222222 vendor/c (v1.0-3-g2222222)
         3333333333333333333333333333333333333333 vendor/d (heads/main)
        """
        let gitmodules = """
        submodule.ab.path libs/a b
        submodule.ab.url https://example.com/ab.git
        submodule.ab.branch stable
        submodule.vendor/c.path vendor/c
        submodule.vendor/c.url ../c.git
        """
        let items = GitSubmoduleInfo.parse(status: status, gitmodules: gitmodules)
        XCTAssertEqual(items.map(\.path), ["libs/a b", "vendor/c", "vendor/d"])
        XCTAssertEqual(items[0].name, "ab")
        XCTAssertEqual(items[0].branch, "stable")
        XCTAssertEqual(items[0].state, .uninitialized)
        XCTAssertEqual(items[1].url, "../c.git")
        XCTAssertEqual(items[1].state, .modifiedCommit)
        XCTAssertEqual(items[2].state, .upToDate)
        XCTAssertEqual(GitSubmoduleInfo.filter(items, under: ["vendor"]).map(\.path), ["vendor/c", "vendor/d"])
        XCTAssertEqual(GitSubmoduleInfo.filter(items, under: ["vendor/c/src"]).map(\.path), ["vendor/c"])
        XCTAssertEqual(GitSubmoduleInfo.filter(items, under: [""]).count, 3)
    }

    func testUpdateArguments() {
        var options = GitSubmoduleInfo.UpdateOptions()
        options.recursive = false
        options.remote = true
        options.mode = .rebase
        XCTAssertEqual(options.arguments(paths: ["a"]), ["submodule", "update", "--init", "--remote", "--rebase", "--", "a"])
    }

    func testChangeClassification() {
        XCTAssertEqual(GitSubmoduleChange.classify(from: nil, to: "b", fromIsAncestor: false, toIsAncestor: false, fromTime: 0, toTime: 0), .newSubmodule)
        XCTAssertEqual(GitSubmoduleChange.classify(from: "a", to: "", fromIsAncestor: false, toIsAncestor: false, fromTime: 0, toTime: 0), .deleted)
        XCTAssertEqual(GitSubmoduleChange.classify(from: "a", to: "b", fromIsAncestor: true, toIsAncestor: false, fromTime: 0, toTime: 0), .fastForward)
        XCTAssertEqual(GitSubmoduleChange.classify(from: "a", to: "b", fromIsAncestor: false, toIsAncestor: true, fromTime: 0, toTime: 0), .rewind)
        XCTAssertEqual(GitSubmoduleChange.classify(from: "a", to: "b", fromIsAncestor: false, toIsAncestor: false, fromTime: 1, toTime: 2), .newerTime)
        XCTAssertEqual(GitSubmoduleChange.classify(from: "a", to: "a", fromIsAncestor: true, toIsAncestor: true, fromTime: 1, toTime: 1), .unchanged)
    }
}
