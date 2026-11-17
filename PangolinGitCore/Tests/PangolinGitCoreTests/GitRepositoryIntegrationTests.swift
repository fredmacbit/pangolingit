import XCTest
import Foundation
@testable import PangolinGitCore

final class GitRepositoryIntegrationTests: XCTestCase {

    private var tempDirectory: URL!
    private var repoPath: PangolinPath!
    private var repository: GitRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()

        guard FileManager.default.isExecutableFile(atPath: GitCLIRunner.resolveGitExecutable()) else {
            throw XCTSkip("git CLI is not installed")
        }

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pangolin-test-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        repoPath = PangolinPath(tempDirectory.path)

        try GitCLIRunner.run(arguments: ["init", "-b", "main"], workingDirectory: repoPath)
        try GitCLIRunner.run(arguments: ["config", "user.name", "Pangolin Test"], workingDirectory: repoPath)
        try GitCLIRunner.run(arguments: ["config", "user.email", "test@pangolingit.local"], workingDirectory: repoPath)
        try GitCLIRunner.run(arguments: ["config", "commit.gpgsign", "false"], workingDirectory: repoPath)

        repository = try GitRepository(rootPath: repoPath)
    }

    override func tearDownWithError() throws {
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ content: String) throws {
        try content.write(to: tempDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testOpeningFromSubdirectoryFindsRoot() throws {
        let sub = tempDirectory.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let repo = try GitRepository(rootPath: PangolinPath(sub.path))
        XCTAssertEqual(repo.workingDirectory, repoPath)
        XCTAssertThrowsError(try GitRepository(rootPath: PangolinPath("/")))
    }

    func testRepositoryInitAndUntrackedStatus() throws {
        try write("hello world.txt", "Hello PangolinGit")

        let item = try repository.status().first(where: { $0.path == "hello world.txt" })
        XCTAssertEqual(item?.status, .untracked)
        XCTAssertEqual(item?.badgeKind, .unversioned)
    }

    func testStagingAndCommitFlow() async throws {
        try write("document.txt", "Version 1.0 Content")

        try await repository.stage(paths: ["document.txt"])
        let staged = try repository.status().first(where: { $0.path == "document.txt" })
        XCTAssertEqual(staged?.status, .added)

        try await repository.unstage(paths: ["document.txt"])
        XCTAssertEqual(try repository.status().first(where: { $0.path == "document.txt" })?.status, .untracked)

        try await repository.add(paths: ["document.txt"])
        try await repository.commit(message: "Initial commit")

        XCTAssertTrue(try repository.status().isEmpty)
        let log = try await repository.getLog(limit: 10)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.subject, "Initial commit")
        XCTAssertTrue(log.first?.refs.contains("main") ?? false)

        try write("document.txt", "Version 2.0 Content")
        XCTAssertEqual(try repository.status().first?.status, .modified)
    }

    func testRenameIsParsedWithOriginalPath() async throws {
        try write("old name.txt", "content\n")
        try await repository.add(paths: ["old name.txt"])
        try await repository.commit(message: "add")
        try GitCLIRunner.run(arguments: ["mv", "old name.txt", "new name.txt"], workingDirectory: repoPath)

        let item = try repository.status().first
        XCTAssertEqual(item?.status, .renamed)
        XCTAssertEqual(item?.path, "new name.txt")
        XCTAssertEqual(item?.originalPath, "old name.txt")
    }

    func testBranchCreationAndCheckout() async throws {
        try write("main.txt", "Main")
        try await repository.add(paths: ["main.txt"])
        try await repository.commit(message: "Main commit")

        _ = try await repository.createBranch(name: "feature-branch", checkout: true)

        let branches = try await repository.getBranches()
        let current = try await repository.getCurrentBranch()
        XCTAssertTrue(branches.contains("feature-branch"))
        XCTAssertEqual(current, "feature-branch")
    }

    func testCommitLogWithMultipleCommits() async throws {
        for index in 1...3 {
            try write("file\(index).txt", "Content \(index)")
            try await repository.add(paths: ["file\(index).txt"])
            try await repository.commit(message: "Commit \(index)\n\nBody of commit \(index)")
        }

        let log = try await repository.getLog(limit: 2)
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[0].subject, "Commit 3")
        XCTAssertEqual(log[0].body, "Body of commit 3")
        XCTAssertEqual(log[0].parentHashes.first, log[1].hash)
    }

    func testStashSaveAndPop() async throws {
        try write("stash.txt", "Initial")
        try await repository.add(paths: ["stash.txt"])
        try await repository.commit(message: "Base")

        try write("stash.txt", "Modified")
        _ = try await repository.stash(message: "WIP")
        XCTAssertTrue(try repository.status().isEmpty)
        XCTAssertEqual(try repository.stashList().count, 1)

        _ = try await repository.stashPop()
        XCTAssertEqual(try repository.status().first?.status, .modified)
    }

    func testTagCreationAndDeletion() async throws {
        try write("tag.txt", "Tag me")
        try await repository.add(paths: ["tag.txt"])
        try await repository.commit(message: "Taggable")

        _ = try await repository.tagCreate(name: "v1.0.0", message: "Release")
        XCTAssertEqual(try repository.tagList(), ["v1.0.0"])

        _ = try await repository.tagDelete(name: "v1.0.0")
        XCTAssertTrue(try repository.tagList().isEmpty)
    }

    func testFailedCommandThrows() {
        XCTAssertThrowsError(try GitCLIRunner.run(arguments: ["checkout", "does-not-exist"], workingDirectory: repoPath)) { error in
            guard case GitCLIError.commandFailed(let code, _, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertNotEqual(code, 0)
        }
    }
}
