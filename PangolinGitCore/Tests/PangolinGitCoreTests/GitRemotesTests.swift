import XCTest
@testable import PangolinGitCore

final class GitRemotesTests: XCTestCase {

    // MARK: - Pure parsing

    func testParseRemoteConfigKeepsOrderAndDottedNames() {
        let output = """
        remote.origin.url https://github.com/me/repo.git
        remote.origin.fetch +refs/heads/*:refs/remotes/origin/*
        remote.origin.tagopt --no-tags
        remote.my.fork.url git@github.com:other/repo.git
        remote.my.fork.pushurl git@github.com:mine/repo.git
        remote.my.fork.prune true
        remote.my.fork.sshkey ~/.ssh/fork_key
        remote.orphan.prune false
        """
        let remotes = GitRemotes.parseRemoteConfig(output)
        XCTAssertEqual(remotes.map(\.name), ["origin", "my.fork"])
        XCTAssertEqual(remotes[0].tagOption, .none)
        XCTAssertNil(remotes[0].prune)
        XCTAssertEqual(remotes[1].url, "git@github.com:other/repo.git")
        XCTAssertEqual(remotes[1].pushURL, "git@github.com:mine/repo.git")
        XCTAssertEqual(remotes[1].prune, true)
        XCTAssertEqual(remotes[1].sshKey, "~/.ssh/fork_key")
        XCTAssertEqual(remotes[1].tagOption, .reachable)
    }

    func testParseRemoteBranchesStripsRemoteAndHead() {
        let output = "refs/remotes/origin/HEAD\nrefs/remotes/origin/main\nrefs/remotes/origin/feature/x\nrefs/remotes/originals/main\n"
        XCTAssertEqual(GitRemotes.parseRemoteBranches(output, remote: "origin"), ["main", "feature/x"])
    }

    func testMergeBranchName() {
        XCTAssertEqual(GitRemotes.mergeBranchName("refs/heads/release/1.0"), "release/1.0")
        XCTAssertEqual(GitRemotes.mergeBranchName("main"), "main")
    }

    func testParseLeftRight() {
        XCTAssertEqual(GitRemotes.parseLeftRight("3\t5\n")?.left, 3)
        XCTAssertEqual(GitRemotes.parseLeftRight("3\t5\n")?.right, 5)
        XCTAssertNil(GitRemotes.parseLeftRight("fatal"))
    }

    func testCompareSnapshotsAndChangeKinds() {
        let old = ["refs/heads/main": "a", "refs/remotes/origin/gone": "b", "refs/tags/v1": "c"]
        let new = ["refs/heads/main": "d", "refs/remotes/origin/new": "e", "refs/tags/v1": "c"]
        let changes = GitRemotes.compareSnapshots(old: old, new: new)
        XCTAssertEqual(changes.map(\.ref), ["refs/heads/main", "refs/remotes/origin/gone", "refs/remotes/origin/new", "refs/tags/v1"])
        XCTAssertEqual(changes.map(\.kind), [.changed, .deleted, .new, .same])
        XCTAssertEqual(changes[1].shortName, "origin/gone")
        XCTAssertEqual(changes[1].typeTitle, "Remote branch")

        XCTAssertEqual(GitRemotes.changeKind(ahead: 2, behind: 0), .fastForward(2))
        XCTAssertEqual(GitRemotes.changeKind(ahead: 0, behind: 1), .rewind(1))
        XCTAssertEqual(GitRemotes.changeKind(ahead: 1, behind: 1), .diverged(ahead: 1, behind: 1))
    }

    func testTagListPrefersPeeledCommit() {
        let lsRemote = "111\trefs/tags/v1.0\n222\trefs/tags/v2.0\n333\trefs/tags/v2.0^{}\n"
        XCTAssertEqual(GitRemotes.parseTagList(lsRemote), ["v1.0": "111", "v2.0": "333"])
        let showRef = "111 refs/tags/v1.0\n999 refs/tags/v3.0\n"
        let comparison = GitRemotes.compareTags(local: GitRemotes.parseTagList(showRef), remote: GitRemotes.parseTagList(lsRemote))
        XCTAssertEqual(comparison.map(\.name), ["v1.0", "v2.0", "v3.0"])
        XCTAssertEqual(comparison.map(\.state), [.same, .remoteOnly, .localOnly])
    }

    func testSSHEnvironmentQuotesPath() {
        let env = GitRemotes.sshEnvironment(keyPath: "/Users/me/my keys/it's")
        XCTAssertEqual(env["GIT_SSH_COMMAND"], "ssh -i '/Users/me/my keys/it'\\''s' -o IdentitiesOnly=yes")
    }

    func testParseNameStatus() {
        let parsed = GitRemotes.parseNameStatus("M\ta.txt\nR100\told.txt\tnew.txt\n")
        XCTAssertEqual(parsed.map(\.status), ["M", "R"])
        XCTAssertEqual(parsed.map(\.path), ["a.txt", "new.txt"])
    }

    // MARK: - Against real repositories

    func testFetchSnapshotUpstreamAndRemoteBranches() async throws {
        guard FileManager.default.isExecutableFile(atPath: GitCLIRunner.resolveGitExecutable()) else {
            throw XCTSkip("git CLI is not installed")
        }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pangolin-remotes-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let upstream = PangolinPath(base.appendingPathComponent("upstream").path)
        let clone = PangolinPath(base.appendingPathComponent("clone").path)
        try FileManager.default.createDirectory(atPath: upstream.rawPath, withIntermediateDirectories: true)

        func git(_ args: [String], in dir: PangolinPath) throws {
            try GitCLIRunner.run(arguments: ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args,
                                 workingDirectory: dir)
        }
        try git(["init", "-b", "main"], in: upstream)
        try git(["commit", "--allow-empty", "-m", "one"], in: upstream)
        try git(["clone", upstream.rawPath, clone.rawPath], in: PangolinPath(base.path))

        let up = await GitRemotes.upstream(of: "main", in: clone)
        XCTAssertEqual(up?.remote, "origin")
        XCTAssertEqual(up?.branch, "main")
        let branches = await GitRemotes.remoteBranches(of: "origin", in: clone)
        XCTAssertEqual(branches, ["main"])
        let remotes = await GitRemotes.loadRemotes(in: clone)
        XCTAssertEqual(remotes.first?.url, upstream.rawPath)

        let before = await GitRemotes.refSnapshot(in: clone)
        try git(["commit", "--allow-empty", "-m", "two"], in: upstream)
        try git(["commit", "--allow-empty", "-m", "three"], in: upstream)
        try git(["fetch", "origin"], in: clone)
        let after = await GitRemotes.refSnapshot(in: clone)
        let changes = await GitRemotes.classify(GitRemotes.compareSnapshots(old: before, new: after), in: clone)
        XCTAssertEqual(changes.first { $0.ref == "refs/remotes/origin/main" }?.kind, .fastForward(2))
        XCTAssertEqual(changes.first { $0.ref == "refs/heads/main" }?.kind, .same)

        let counts = await GitRemotes.aheadBehind("HEAD", "origin/main", in: clone)
        XCTAssertEqual(counts?.ahead, 0)
        XCTAssertEqual(counts?.behind, 2)
    }
}

final class GitCredentialTests: XCTestCase {

    func testCredentialRequestRoundTrip() {
        let request = GitCredentialRequest.parse("protocol=https\nhost=github.com\nusername=me\n\nignored=1\n")
        XCTAssertEqual(request.host, "github.com")
        XCTAssertEqual(request.username, "me")
        XCTAssertNil(request["ignored"])
        XCTAssertEqual(request.location, "https://github.com")

        var answer = request
        answer["password"] = "s3cret=x"
        XCTAssertEqual(answer.serialized(), "protocol=https\nhost=github.com\nusername=me\npassword=s3cret=x\n\n")
        XCTAssertEqual(GitCredentialRequest.parse(answer.serialized()).password, "s3cret=x")
    }

    func testLocationIncludesPathWhenSent() {
        let request = GitCredentialRequest.parse("protocol=https\nhost=example.com:8443\npath=team/repo.git\n")
        XCTAssertEqual(request.location, "https://example.com:8443/team/repo.git")
    }

    func testAccountParsingKeepsAtSignsInUsername() {
        let account = GitCredentialStore.account(username: "me@corp.com", location: "https://git.corp.com")
        XCTAssertEqual(GitCredentialStore.parseAccount(account), .init(username: "me@corp.com", location: "https://git.corp.com"))
        XCTAssertNil(GitCredentialStore.parseAccount("no-at-sign"))
    }

    func testAskPassEnvironmentAddsCredentialHelperOnlyWhenFree() {
        let env = AskPassHelper.askPassEnvironment(helperPath: "/Apps/My App/pangolin-askpass", credentialPrompt: true, inherited: [:])
        XCTAssertEqual(env["GIT_CONFIG_KEY_0"], "credential.helper")
        XCTAssertEqual(env["GIT_CONFIG_VALUE_0"], "!'/Apps/My App/pangolin-askpass'")
        XCTAssertEqual(env["GIT_ASKPASS"], "/Apps/My App/pangolin-askpass")

        let taken = AskPassHelper.askPassEnvironment(helperPath: "/x", credentialPrompt: true, inherited: ["GIT_CONFIG_COUNT": "2"])
        XCTAssertNil(taken["GIT_CONFIG_COUNT"])
        let off = AskPassHelper.askPassEnvironment(helperPath: "/x", credentialPrompt: false, inherited: [:])
        XCTAssertNil(off["GIT_CONFIG_KEY_0"])
    }

    func testHostKeyPromptParsing() {
        let prompt = """
        The authenticity of host 'github.com (140.82.121.3)' can't be established.
        ED25519 key fingerprint is SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        let parsed = AskPassHelper.parseHostKeyPrompt(prompt)
        XCTAssertEqual(parsed?.host, "github.com (140.82.121.3)")
        XCTAssertEqual(parsed?.keyType, "ED25519")
        XCTAssertEqual(parsed?.fingerprint, "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")
        XCTAssertEqual(parsed?.changed, false)
        XCTAssertNil(AskPassHelper.parseHostKeyPrompt("Password for 'https://x': "))
    }

    func testPromptLocation() {
        XCTAssertEqual(AskPassHelper.promptLocation("Password for 'https://me@github.com': "), "https://me@github.com")
        XCTAssertNil(AskPassHelper.promptLocation("Enter passphrase"))
    }

    /// git really runs the `!'<path>'` helper form with a path containing spaces.
    func testGitRunsQuotedCredentialHelper() throws {
        guard FileManager.default.isExecutableFile(atPath: GitCLIRunner.resolveGitExecutable()) else {
            throw XCTSkip("git CLI is not installed")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pangolin cred \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("fake helper")
        try "#!/bin/sh\n[ \"$1\" = get ] && printf 'username=bob\\npassword=pw\\n'\nexit 0\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        var env = AskPassHelper.askPassEnvironment(helperPath: helper.path, credentialPrompt: true, inherited: [:])
            .filter { $0.key.hasPrefix("GIT_CONFIG_") }
        // Keep the user's own helpers (osxkeychain) out of the test.
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS"] = "/usr/bin/false"
        let result = try GitCLIRunner().runSync(arguments: ["credential", "fill"], workingDirectory: PangolinPath(dir.path),
                                                environment: env,
                                                standardInput: Data("protocol=https\nhost=example.com\n\n".utf8))
        XCTAssertTrue(result.standardOutput.contains("username=bob"), result.standardError)
        XCTAssertTrue(result.standardOutput.contains("password=pw"))
    }
}
