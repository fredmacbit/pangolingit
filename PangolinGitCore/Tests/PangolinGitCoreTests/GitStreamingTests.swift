import XCTest
@testable import PangolinGitCore

final class GitStreamingTests: XCTestCase {

    private final class Chunks: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    func testStreamDeliversOutputAndResult() async throws {
        let chunks = Chunks()
        let result = try await GitCLIRunner().stream(arguments: ["--version"]) { text, _ in chunks.append(text) }
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.standardOutput.hasPrefix("git version"))
        XCTAssertEqual(chunks.value, result.standardOutput)
    }

    func testStreamReportsFailureOnStderr() async throws {
        let result = try await GitCLIRunner().stream(arguments: ["rev-parse", "--verify", "no-such-ref-xyz"],
                                                     workingDirectory: PangolinPath(NSTemporaryDirectory())) { _, _ in }
        XCTAssertFalse(result.isSuccess)
        XCTAssertFalse(result.standardError.isEmpty)
    }

    func testCancellingTheTaskTerminatesGit() async throws {
        // A shell alias that keeps running (and keeps the output pipes open) for 30 seconds.
        let task = Task {
            try await GitCLIRunner().stream(arguments: ["-c", "alias.wait=!sleep 30", "wait"],
                                            workingDirectory: PangolinPath(NSTemporaryDirectory())) { _, _ in }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        let started = Date()
        let result = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(result.isSuccess)
    }

    func testFullCommandLineInErrors() {
        XCTAssertEqual(GitCLIRunner.commandLine(["commit", "-m", "two words"]), "git commit -m 'two words'")
        XCTAssertEqual(GitCLIRunner.commandLine(["log", "--oneline"]), "git log --oneline")
    }
}
