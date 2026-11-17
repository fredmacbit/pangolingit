import XCTest
import Foundation
@testable import PangolinGitCore

/// Runs the rebase todo PangolinGit generates through real git: reword via `exec … --amend -F`,
/// squash with the non-interactive editor, and the stopped-rebase state the dialog reads.
final class GitRebaseIntegrationTests: XCTestCase {

    private var tempDirectory: URL!
    private var repoPath: PangolinPath!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.isExecutableFile(atPath: GitCLIRunner.resolveGitExecutable()) else {
            throw XCTSkip("git CLI is not installed")
        }
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pangolin-rebase-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        repoPath = PangolinPath(tempDirectory.path)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Pangolin Test"])
        try git(["config", "user.email", "test@pangolingit.local"])
        try git(["config", "commit.gpgsign", "false"])
        for index in 1...3 {
            try "\(index)\n".write(to: tempDirectory.appendingPathComponent("f\(index)"), atomically: true, encoding: .utf8)
            try git(["add", "f\(index)"])
            try git(["commit", "-m", "c\(index)"])
        }
    }

    override func tearDownWithError() throws {
        if let dir = tempDirectory { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func git(_ args: [String], environment: [String: String]? = nil) throws -> String {
        try GitCLIRunner.run(arguments: args, workingDirectory: repoPath, environment: environment)
    }

    private func sequenceEditor(for steps: [GitRebaseStep]) throws -> [String: String] {
        var files: [String: String] = [:]
        for step in steps where step.newMessage != nil {
            let file = tempDirectory.appendingPathComponent("\(step.hash).msg").path
            try step.newMessage!.write(toFile: file, atomically: true, encoding: .utf8)
            files[step.hash] = file
        }
        let todo = tempDirectory.appendingPathComponent("todo").path
        try GitRebaseTodo.render(steps) { files[$0.hash] }.write(toFile: todo, atomically: true, encoding: .utf8)
        return ["GIT_SEQUENCE_EDITOR": "cp '\(todo)'"]
    }

    func testRewordAndSquash() throws {
        let c2 = try git(["rev-parse", "HEAD~1"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let c3 = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = [
            GitRebaseStep(action: .reword, hash: c2, subject: "c2", newMessage: "Better message\n\nWith body"),
            GitRebaseStep(action: .fixup, hash: c3, subject: "c3")
        ]
        var options = GitRebaseOptions(upstream: "HEAD~2")
        options.forceRebase = true
        try git(options.arguments, environment: try sequenceEditor(for: steps))
        let subjects = try git(["log", "--format=%s"]).split(separator: "\n")
        XCTAssertEqual(subjects, ["Better message", "c1"])
        XCTAssertEqual(GitOperationInProgress.detect(gitDirectory: repoPath.appendingPathComponent(".git")), .none)
    }

    func testEditStopIsDetected() throws {
        let c2 = try git(["rev-parse", "HEAD~1"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let c3 = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = [GitRebaseStep(action: .edit, hash: c2, subject: "c2"), GitRebaseStep(action: .pick, hash: c3, subject: "c3")]
        try git(GitRebaseOptions(upstream: "HEAD~2").arguments, environment: try sequenceEditor(for: steps))
        let gitDir = repoPath.appendingPathComponent(".git")
        XCTAssertEqual(GitOperationInProgress.detect(gitDirectory: gitDir), .rebase(interactive: true))
        let progress = try XCTUnwrap(GitRebaseProgress.read(gitDirectory: gitDir))
        XCTAssertTrue(progress.isEditStop)
        XCTAssertEqual(progress.step, 1)
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.remaining.first?.hash.prefix(7), c3.prefix(7))
        XCTAssertEqual(progress.headName, "refs/heads/main")
        try git(["rebase", "--abort"])
    }
}
