import XCTest
@testable import PangolinGitCore

/// Commit-dialog git plumbing against a real temporary repository.
final class GitRepositoryCommitTests: XCTestCase {

    private var tempDirectory: URL!
    private var repoPath: PangolinPath!
    private var repository: GitRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.isExecutableFile(atPath: GitCLIRunner.resolveGitExecutable()) else {
            throw XCTSkip("git CLI is not installed")
        }
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pangolin-commit-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        repoPath = PangolinPath(tempDirectory.path)
        try git("init", "-b", "main")
        try git("config", "user.name", "Pangolin Test")
        try git("config", "user.email", "test@pangolingit.local")
        try git("config", "commit.gpgsign", "false")
        repository = try GitRepository(rootPath: repoPath)
    }

    override func tearDownWithError() throws {
        if let dir = tempDirectory { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        try GitCLIRunner.run(arguments: arguments, workingDirectory: repoPath)
    }

    private func write(_ name: String, _ content: String) throws {
        try content.write(to: tempDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testIdentityTemplateAndMessage() async throws {
        let identity = await repository.committerIdentity()
        XCTAssertEqual(identity?.name, "Pangolin Test")
        XCTAssertEqual(identity?.email, "test@pangolingit.local")

        let noTemplate = await repository.commitTemplate()
        XCTAssertNil(noTemplate)
        try write("tpl.txt", "Subject\n\n# why\n")
        try git("config", "commit.template", "tpl.txt")
        let template = await repository.commitTemplate()
        XCTAssertEqual(template, "Subject\n\n# why\n")

        try write("a.txt", "a\n")
        try git("add", "a.txt")
        try git("commit", "-m", "First line\n\nBody")
        let message = try await repository.commitMessage()
        XCTAssertEqual(message, "First line\n\nBody")
        let author = await repository.authorString(ofHead: true)
        XCTAssertEqual(author, "Pangolin Test <test@pangolingit.local>")
    }

    func testBranchQueries() async throws {
        let unbornDetached = await repository.isHeadDetached()
        XCTAssertFalse(unbornDetached, "an unborn branch is still a branch")
        try write("a.txt", "a\n")
        try git("add", "a.txt")
        try git("commit", "-m", "one")
        try git("tag", "v1")
        let validName = await repository.isValidBranchName("feature/x")
        let invalidName = await repository.isValidBranchName("bad..name")
        let mainExists = await repository.refExists("refs/heads/main")
        let tagExists = await repository.refExists("refs/tags/v1")
        let missing = await repository.refExists("refs/heads/nope")
        XCTAssertTrue(validName)
        XCTAssertFalse(invalidName)
        XCTAssertTrue(mainExists)
        XCTAssertTrue(tagExists)
        XCTAssertFalse(missing)
        let upstream = await repository.headUpstream()
        XCTAssertNil(upstream)

        try git("checkout", "--detach")
        let detached = await repository.isHeadDetached()
        XCTAssertTrue(detached)
    }

    func testStagingSingleHunkAndUnstagingIt() async throws {
        let lines = (1...20).map { "line \($0)" }
        try write("f.txt", lines.joined(separator: "\n") + "\n")
        try git("add", "f.txt")
        try git("commit", "-m", "base")

        var changed = lines
        changed[0] = "LINE 1"
        changed[19] = "LINE 20"
        try write("f.txt", changed.joined(separator: "\n") + "\n")

        let diff = try await repository.fileDiff("f.txt", staged: false)
        let patch = try XCTUnwrap(FileHunkPatch(unifiedDiff: diff))
        XCTAssertEqual(patch.hunks.count, 2)

        try await repository.applyToIndex(patch: patch.patch(forHunk: 1), reverse: false)
        let staged = try await repository.fileDiff("f.txt", staged: true)
        XCTAssertTrue(staged.contains("+LINE 20"))
        XCTAssertFalse(staged.contains("+LINE 1\n"))
        let status = try await repository.getStatus()
        XCTAssertEqual(status.first?.status, .stagedModified)

        let stagedPatch = try XCTUnwrap(FileHunkPatch(unifiedDiff: staged))
        try await repository.applyToIndex(patch: stagedPatch.patch(forHunk: 0), reverse: true)
        let afterUnstage = try await repository.fileDiff("f.txt", staged: true)
        XCTAssertEqual(afterUnstage, "")
    }

    func testCommitPlanCommitsOnlyCheckedPathsOnNewBranch() throws {
        try write("a.txt", "a\n")
        try git("add", "a.txt")
        try git("commit", "-m", "base")
        try write("a.txt", "changed\n")
        try write("b.txt", "new\n")
        try write("c.txt", "left out\n")

        let messageFile = tempDirectory.appendingPathComponent("../msg-\(UUID().uuidString)").standardizedFileURL
        try "Commit b and a\n".write(to: messageFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: messageFile) }

        var plan = CommitPlan(messageFile: messageFile.path)
        plan.newBranch = "topic"
        plan.pathsToStage = ["a.txt", "b.txt"]
        plan.commitPaths = ["a.txt", "b.txt"]
        plan.author = "Other Person <other@example.com>"
        for command in plan.commands() {
            try GitCLIRunner.run(arguments: command, workingDirectory: repoPath)
        }

        XCTAssertEqual(try git("symbolic-ref", "--short", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines), "topic")
        XCTAssertEqual(try git("log", "-1", "--format=%s|%an").trimmingCharacters(in: .whitespacesAndNewlines),
                       "Commit b and a|Other Person")
        let files = try git("show", "--name-only", "--format=", "HEAD").split(separator: "\n").map(String.init)
        XCTAssertEqual(Set(files), ["a.txt", "b.txt"])
        XCTAssertTrue(try git("status", "--porcelain").contains("?? c.txt"))
    }
}
