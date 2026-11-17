import XCTest
@testable import PangolinGitCore

#if canImport(PangolinGit)
@testable import PangolinGit

final class RefsAndRebaseUITests: XCTestCase {
    @MainActor
    func testRemoteTagsSkipPeeledEntries() {
        let output = """
        aaa\trefs/tags/v1.10
        bbb\trefs/tags/v1.10^{}
        ccc\trefs/tags/v1.2
        ddd\trefs/heads/main
        """
        XCTAssertEqual(DeleteRemoteTagsWindowController.parseRemoteTags(output), ["v1.2", "v1.10"])
    }

    @MainActor
    func testRebaseShortcuts() {
        XCTAssertEqual(RebaseTableView.nextAction(after: .pick), .squash)
        XCTAssertEqual(RebaseTableView.nextAction(after: .squash), .edit)
        XCTAssertEqual(RebaseTableView.nextAction(after: .edit), .drop)
        XCTAssertEqual(RebaseTableView.nextAction(after: .drop), .pick)
        XCTAssertEqual(RebaseTableView.nextAction(after: .reword), .pick)
        guard case .set(.squash)? = RebaseTableView.command(for: "Q") else { return XCTFail("Q squashes") }
        guard case .set(.drop)? = RebaseTableView.command(for: "s") else { return XCTFail("S skips") }
        guard case .moveDown? = RebaseTableView.command(for: "d") else { return XCTFail("D moves down") }
        XCTAssertNil(RebaseTableView.command(for: "x"))
    }
}
#endif
