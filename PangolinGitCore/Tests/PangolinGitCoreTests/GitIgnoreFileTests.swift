import XCTest
@testable import PangolinGitCore

final class GitIgnoreFileTests: XCTestCase {

    func testPatternBuilders() {
        XCTAssertEqual(GitIgnoreFile.exactPattern(forPath: "build/out.o"), "/build/out.o")
        XCTAssertEqual(GitIgnoreFile.exactPattern(forPath: "a[1]*.txt"), "/a\\[1]\\*.txt")
        XCTAssertEqual(GitIgnoreFile.extensionPattern(forPath: "logs/app.log"), "*.log")
        XCTAssertNil(GitIgnoreFile.extensionPattern(forPath: "Makefile"))
        XCTAssertEqual(GitIgnoreFile.folderPattern(forFolder: "build/"), "/build/")
        XCTAssertEqual(GitIgnoreFile.folderPattern(forFolder: "a/b"), "/a/b/")
        XCTAssertEqual(GitIgnoreFile.escape("#notes"), "\\#notes")
        XCTAssertEqual(GitIgnoreFile.escape("trailing "), "trailing\\ ")
    }

    func testAppendingSkipsDuplicatesAndAddsNewline() {
        XCTAssertEqual(GitIgnoreFile.appending(["*.log"], to: ""), "*.log\n")
        XCTAssertEqual(GitIgnoreFile.appending(["*.log", "/build/"], to: "*.o"), "*.o\n*.log\n/build/\n")
        XCTAssertEqual(GitIgnoreFile.appending(["*.log", "*.log", ""], to: "*.log\n"), "*.log\n")
    }

    func testAppendWritesToGitignoreAndLocalExclude() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = PangolinPath(root.path)
        _ = try GitCLIRunner.run(arguments: ["init", "-q"], workingDirectory: path)

        try GitIgnoreFile.append(["*.tmp"], to: .gitignore, repositoryRoot: path)
        try GitIgnoreFile.append(["*.tmp", "/secret.txt"], to: .gitignore, repositoryRoot: path)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8), "*.tmp\n/secret.txt\n")

        try GitIgnoreFile.append(["/local/"], to: .localExclude, repositoryRoot: path)
        let exclude = try String(contentsOf: GitIgnoreFile.url(for: .localExclude, repositoryRoot: path), encoding: .utf8)
        XCTAssertTrue(exclude.hasSuffix("/local/\n"))
    }

    func testScopedPatternsMatchOnlyWhereIntended() throws {
        XCTAssertEqual(GitIgnoreFile.namePattern(forPath: "src/a.log"), "a.log")
        XCTAssertEqual(GitIgnoreFile.namePattern(forPath: "src/a.log", inFolder: "src"), "/src/**/a.log")
        XCTAssertEqual(GitIgnoreFile.extensionPattern(forPath: "src/a.log", inFolder: "src"), "/src/**/*.log")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = PangolinPath(root.path)
        _ = try GitCLIRunner.run(arguments: ["init", "-q"], workingDirectory: path)
        try GitIgnoreFile.append([GitIgnoreFile.extensionPattern(forPath: "src/a.log", inFolder: "src")!,
                                  GitIgnoreFile.namePattern(forPath: "x/notes.txt")], to: .gitignore, repositoryRoot: path)

        func ignored(_ file: String) -> Bool {
            let result = try? GitCLIRunner().runSync(arguments: ["check-ignore", "-q", file], workingDirectory: path)
            return result?.isSuccess ?? false
        }
        XCTAssertTrue(ignored("src/a.log"))
        XCTAssertTrue(ignored("src/deep/b.log"))
        XCTAssertFalse(ignored("other/a.log"))
        XCTAssertFalse(ignored("a.log"))
        XCTAssertTrue(ignored("notes.txt"))
        XCTAssertTrue(ignored("any/where/notes.txt"))
    }

    func testRemoveFromIndexStagesDeletionOfMissingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = PangolinPath(root.path)
        for args in [["init", "-q"], ["config", "user.name", "t"], ["config", "user.email", "t@t"]] {
            _ = try GitCLIRunner.run(arguments: args, workingDirectory: path)
        }
        try "a".write(to: root.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        _ = try GitCLIRunner.run(arguments: ["add", "."], workingDirectory: path)
        _ = try GitCLIRunner.run(arguments: ["commit", "-qm", "init"], workingDirectory: path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))

        let repo = try XCTUnwrap(GitRepository.open(at: path))
        let before = try await repo.getStatus()
        XCTAssertEqual(before.first?.status, .missing)
        try await repo.removeFromIndex(paths: ["gone.txt"])
        let staged = try await repo.getStatus()
        XCTAssertEqual(staged.first?.status, .deleted)
        try await repo.commit(message: "remove", paths: ["gone.txt"])
        let after = try await repo.getStatus()
        XCTAssertTrue(after.isEmpty)
    }
}
