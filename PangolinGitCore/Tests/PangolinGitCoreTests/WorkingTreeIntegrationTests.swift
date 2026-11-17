import XCTest
import Foundation
@testable import PangolinGitCore

/// Runs the Resolve / Clean up / Ignore helpers against a real repository.
final class WorkingTreeIntegrationTests: XCTestCase {

    private var tempDirectory: URL!
    private var repoPath: PangolinPath!
    private var repository: GitRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.isExecutableFile(atPath: GitCLIRunner.resolveGitExecutable()) else {
            throw XCTSkip("git CLI is not installed")
        }
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pangolin-wt-\(UUID().uuidString)")
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
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    @discardableResult
    private func git(_ args: String...) throws -> String {
        try GitCLIRunner.run(arguments: args, workingDirectory: repoPath)
    }

    private func write(_ name: String, _ content: String) throws {
        let url = tempDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: tempDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    func testMergeConflictIsDetectedAndResolvedUsingTheirs() throws {
        try write("file.txt", "base\n")
        try git("add", "file.txt")
        try git("commit", "-m", "base")
        try git("checkout", "-b", "feature")
        try write("file.txt", "feature\n")
        try git("commit", "-am", "feature")
        try git("checkout", "main")
        try write("file.txt", "main\n")
        try git("commit", "-am", "main")
        _ = try? git("merge", "feature")

        XCTAssertEqual(repository.operationInProgress, .merge)
        XCTAssertEqual(repository.conflictSideNames(), GitConflictSideNames(mine: "main", theirs: "feature"))

        for command in repository.resolveCommands(paths: ["file.txt"], side: .theirs) {
            try GitCLIRunner.run(arguments: command, workingDirectory: repoPath)
        }
        XCTAssertEqual(try read("file.txt"), "feature\n")
        let status = try repository.status()
        XCTAssertFalse(status.contains { $0.isConflicted })
    }

    func testCleanDryRunAndIgnoreHelpers() throws {
        try write(".gitignore", "*.log\n")
        try write("tracked.txt", "x\n")
        try git("add", ".")
        try git("commit", "-m", "init")
        try write("stray.tmp", "x\n")
        try write("debug.log", "x\n")
        try write("out/a.o", "x\n")

        let untracked = try GitCLIRunner.run(arguments: GitRepository.cleanArguments(GitCleanOptions(), dryRun: true), workingDirectory: repoPath)
        XCTAssertEqual(Set(GitRepository.parseCleanDryRun(untracked)), ["stray.tmp", "out/"])
        let ignored = try GitCLIRunner.run(arguments: GitRepository.cleanArguments(GitCleanOptions(scope: .ignoredOnly), dryRun: true),
                                           workingDirectory: repoPath)
        XCTAssertEqual(GitRepository.parseCleanDryRun(ignored), ["debug.log"])

        let matches = try repository.ignoreMatches(paths: ["debug.log", "stray.tmp"])
        XCTAssertEqual(matches.map(\.path), ["debug.log"])
        XCTAssertEqual(matches.first?.lineNumber, 1)
        XCTAssertEqual(repository.trackedPaths(among: ["tracked.txt", "stray.tmp", ""]), ["tracked.txt"])

        try GitIgnoreFile.ignore(["out/a.o"], byExtension: true, scope: .containingFolderOnly, location: .containingFolder, repositoryRoot: repoPath)
        XCTAssertEqual(try read("out/.gitignore"), "/*.o\n")
        XCTAssertTrue(try repository.ignoreMatches(paths: ["out/a.o"]).first?.source.hasSuffix("out/.gitignore") ?? false)
    }

    func testLocalChangeFlagsAndLineCounts() throws {
        try write("a.txt", "one\n")
        try git("add", ".")
        try git("commit", "-m", "init")
        try write("a.txt", "one\ntwo\n")
        XCTAssertEqual(try repository.lineCounts()["a.txt"], GitLineCount(added: 1, removed: 0))

        for command in GitRepository.flagCommands(.skipWorktree, paths: ["a.txt"]) {
            try GitCLIRunner.run(arguments: command, workingDirectory: repoPath)
        }
        XCTAssertEqual(try repository.localChangeFlags(), ["a.txt": .skipWorktree])
        for command in GitRepository.flagCommands(nil, paths: ["a.txt"]) {
            try GitCLIRunner.run(arguments: command, workingDirectory: repoPath)
        }
        XCTAssertEqual(try repository.localChangeFlags(), [:])
    }
}
