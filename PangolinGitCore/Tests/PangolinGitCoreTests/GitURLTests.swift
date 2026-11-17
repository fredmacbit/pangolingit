import XCTest
@testable import PangolinGitCore

final class GitURLTests: XCTestCase {
    func testRepositoryName() {
        XCTAssertEqual(GitURL.repositoryName(from: "https://github.com/user/repo.git"), "repo")
        XCTAssertEqual(GitURL.repositoryName(from: "https://github.com/user/repo/"), "repo")
        XCTAssertEqual(GitURL.repositoryName(from: "git@github.com:user/repo.git"), "repo")
        XCTAssertEqual(GitURL.repositoryName(from: "git@host:repo"), "repo")
        XCTAssertEqual(GitURL.repositoryName(from: "/Users/me/src/project.git"), "project")
        XCTAssertNil(GitURL.repositoryName(from: ""))
    }

    func testLooksLikeRemoteURL() {
        XCTAssertTrue(GitURL.looksLikeRemoteURL("https://github.com/user/repo.git"))
        XCTAssertTrue(GitURL.looksLikeRemoteURL("git@github.com:user/repo.git"))
        XCTAssertTrue(GitURL.looksLikeRemoteURL("ssh://git@host:22/repo"))
        XCTAssertFalse(GitURL.looksLikeRemoteURL("hello world"))
        XCTAssertFalse(GitURL.looksLikeRemoteURL("just-text"))
    }
}

final class GitMutationClassificationTests: XCTestCase {
    func testMutatingCommands() {
        for args in [["commit", "-m", "x"], ["add", "--", "a"], ["branch", "-D", "old"], ["branch", "new", "HEAD"],
                     ["tag", "v1"], ["stash"], ["stash", "pop"], ["remote", "add", "o", "u"], ["checkout", "main"],
                     ["-c", "core.quotepath=off", "reset", "--hard"], ["worktree", "add", "../wt"], ["bisect", "good"],
                     ["config", "user.name", "x"], ["lfs", "lock", "a.psd"], ["push", "origin", "main"]] {
            XCTAssertTrue(GitCLIRunner.isMutating(args), "\(args)")
        }
    }

    func testReadOnlyCommands() {
        for args in [["status", "--porcelain=v2"], ["log", "-n", "5"], ["branch", "--list", "--format=%(refname:short)"],
                     ["branch"], ["tag", "-l"], ["tag"], ["stash", "list"], ["remote"], ["remote", "-v"], ["worktree", "list"],
                     ["submodule", "status"], ["config", "--get", "remote.origin.url"], ["apply", "--check", "p.diff"],
                     ["rev-parse", "HEAD"], ["for-each-ref"], ["diff", "HEAD"], ["clean", "-n"], ["lfs", "locks"], []] {
            XCTAssertFalse(GitCLIRunner.isMutating(args), "\(args)")
        }
    }
}
