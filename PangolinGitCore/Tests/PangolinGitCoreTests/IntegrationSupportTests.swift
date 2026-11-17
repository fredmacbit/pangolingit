import XCTest
@testable import PangolinGitCore

/// LFS, hook scripts, update check, automation options and SSH helpers (P9/P10).
final class IntegrationSupportTests: XCTestCase {

    // MARK: - LFS

    func testLFSLocksJSON() {
        let json = """
        [{"id":"3","path":"art/a.psd","owner":{"name":"Ann"},"locked_at":"2024-01-02T03:04:05Z"},
         {"id":"4","path":"b.bin","owner":{"name":"Bob Smith"},"locked_at":"2024-01-02T03:04:05.123Z"}]
        """
        let locks = GitLFS.parseLocksJSON(Data(json.utf8))
        XCTAssertEqual(locks?.count, 2)
        XCTAssertEqual(locks?.first?.owner, "Ann")
        XCTAssertNotNil(locks?.last?.lockedAt)
        XCTAssertNil(GitLFS.parseLocksJSON(Data("not json".utf8)))
    }

    func testLFSLocksTable() {
        let locks = GitLFS.parseLocksTable("a.psd\tAnn\tID:3\nimages/b c.bin   Bob Smith   ID:4\n")
        XCTAssertEqual(locks.map(\.id), ["3", "4"])
        XCTAssertEqual(locks.last?.owner, "Bob Smith")
    }

    func testLockablePatternsAndCommands() {
        let attributes = "*.psd filter=lfs diff=lfs merge=lfs -text lockable\n*.bin filter=lfs -text\n# *.x lockable\n"
        XCTAssertEqual(GitLFS.lockablePatterns(gitattributes: attributes), ["*.psd"])
        XCTAssertEqual(GitLFS.setLockedCommands(paths: ["a"], lock: false, force: true), [["lfs", "unlock", "--force", "--", "a"]])
        XCTAssertEqual(GitLFS.setLockedCommands(paths: ["a"], lock: true, force: true), [["lfs", "lock", "--", "a"]])
    }

    // MARK: - Hooks

    func testHookLookupWalksUpAndFallsBackToStar() {
        let hooks = [
            ClientHook(type: .preCommit, path: "/Users/me/src", commandLine: "parent"),
            ClientHook(type: .preCommit, path: "*", commandLine: "any"),
            ClientHook(type: .preCommit, path: "/Users/me/src/app", commandLine: "disabled", enabled: false),
            ClientHook(type: .prePush, path: "/Users/me/src/app", commandLine: "push")
        ]
        XCTAssertEqual(ClientHookRunner.find(.preCommit, workingTree: "/Users/me/src/app", hooks: hooks)?.commandLine, "parent")
        XCTAssertEqual(ClientHookRunner.find(.preCommit, workingTree: "/tmp/other", hooks: hooks)?.commandLine, "any")
        XCTAssertNil(ClientHookRunner.find(.postCommit, workingTree: "/Users/me/src/app", hooks: hooks))

        let project = ClientHookRunner.projectHooks(values: ["hook.prepush.cmdline": "./check.sh", "hook.prepush.wait": "true"],
                                                    root: "/Users/me/src/app")
        XCTAssertEqual(project.count, 1)
        XCTAssertTrue(project[0].wait)
        // The user's own hook for the same folder wins over the project's.
        XCTAssertEqual(ClientHookRunner.find(.prePush, workingTree: "/Users/me/src/app", hooks: hooks, projectHooks: project)?.commandLine, "push")
        XCTAssertEqual(ClientHookRunner.find(.prePush, workingTree: "/Users/me/src/app", hooks: [], projectHooks: project)?.commandLine, "./check.sh")
    }

    func testHookCommandLine() {
        let hook = ClientHook(type: .postCommit, path: "*", commandLine: "%root%/scripts/post.sh")
        XCTAssertEqual(ClientHookRunner.commandLine(for: hook, root: "/r", arguments: ["/r", "it's"]),
                       "/r/scripts/post.sh '/r' 'it'\\''s'")
    }

    func testHookExecutionReportsExitCodeAndStderr() async {
        let (code, stderr) = await ClientHookRunner.execute("echo nope >&2; exit 3", in: "/tmp", wait: true)
        XCTAssertEqual(code, 3)
        XCTAssertEqual(stderr.trimmingCharacters(in: .whitespacesAndNewlines), "nope")
    }

    // MARK: - Update check

    func testVersionComparison() {
        XCTAssertEqual(UpdateCheck.compare("1.10.0", "1.9.9"), .orderedDescending)
        XCTAssertEqual(UpdateCheck.compare("v1.2", "1.2.0"), .orderedSame)
        XCTAssertEqual(UpdateCheck.compare("1.2.0-beta.2", "1.2.0"), .orderedAscending)
        XCTAssertEqual(UpdateCheck.compare("1.2.0-beta.10", "1.2.0-beta.2"), .orderedDescending)
    }

    func testReleaseFeedAndChannel() {
        let json = """
        [{"tag_name":"v1.3.0-rc1","name":"1.3 RC","prerelease":true,"draft":false,"body":"rc","assets":[]},
         {"tag_name":"v1.2.0","name":"","prerelease":false,"draft":false,"body":"* fixes",
          "html_url":"https://example.org/r/1.2.0",
          "assets":[{"name":"PangolinGit.zip","browser_download_url":"https://example.org/a.zip","size":1},
                    {"name":"PangolinGit.dmg","browser_download_url":"https://example.org/a.dmg","size":2}]},
         {"tag_name":"v9.0.0","draft":true}]
        """
        let releases = UpdateCheck.parseReleases(Data(json.utf8))
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases[1].name, "v1.2.0")
        let stable = UpdateCheck.availableUpdate(in: releases, currentVersion: "1.0.0", includePrereleases: false)
        XCTAssertEqual(stable?.version, "1.2.0")
        XCTAssertEqual(stable.flatMap(UpdateCheck.preferredAsset)?.name, "PangolinGit.dmg")
        XCTAssertEqual(UpdateCheck.availableUpdate(in: releases, currentVersion: "1.0.0", includePrereleases: true)?.version, "1.3.0-rc1")
        XCTAssertNil(UpdateCheck.availableUpdate(in: releases, currentVersion: "1.2.0", includePrereleases: false))
    }

    func testAutomaticCheckSchedule() {
        let now = Date()
        XCTAssertTrue(UpdateCheck.isAutomaticCheckDue(lastCheck: nil, remindAfter: nil, now: now))
        XCTAssertFalse(UpdateCheck.isAutomaticCheckDue(lastCheck: now.addingTimeInterval(-3600), remindAfter: nil, now: now))
        XCTAssertTrue(UpdateCheck.isAutomaticCheckDue(lastCheck: now.addingTimeInterval(-8 * 86400), remindAfter: nil, now: now))
        XCTAssertFalse(UpdateCheck.isAutomaticCheckDue(lastCheck: nil, remindAfter: now.addingTimeInterval(60), now: now))
    }

    // MARK: - Automation options

    func testURLOptions() {
        let url = URL(string: "pangolingit://log?path=/r/a&path=/r/b&rev=abc&closeonend=2&unified")!
        let options = CommandOptions(url: url)
        XCTAssertEqual(options.paths, ["/r/a", "/r/b"])
        XCTAssertEqual(options.revision, "abc")
        XCTAssertEqual(options.closeOnEnd, 2)
        XCTAssertTrue(options.bool("unified"))
        XCTAssertEqual(CommandOptions(url: options.url(command: "log")!), options)
    }

    func testCommandLineParsing() {
        let parsed = CommandOptions.parseCommandLine(["log", "src", "--rev", "HEAD~2", "--limit=5", "--unified"], currentDirectory: "/repo")
        XCTAssertEqual(parsed?.command, "log")
        XCTAssertEqual(parsed?.options.paths, ["/repo/src"])
        XCTAssertEqual(parsed?.options.revision, "HEAD~2")
        XCTAssertEqual(parsed?.options.string("limit"), "5")
        XCTAssertTrue(parsed?.options.bool("unified") ?? false)

        let tortoise = CommandOptions.parseCommandLine(["/command:commit", "/path:/r/a*/r/b", "/logmsg:Hello world", "/closeonend:1"],
                                                       currentDirectory: "/")
        XCTAssertEqual(tortoise?.command, "commit")
        XCTAssertEqual(tortoise?.options.paths, ["/r/a", "/r/b"])
        XCTAssertEqual(tortoise?.options.logMessage, "Hello world")

        let idiff = CommandOptions.parseCommandLine(["idiff", "--left", "a.png", "--right", "/x/b.png"], currentDirectory: "/w")
        XCTAssertEqual(idiff?.command, "imagediff")
        XCTAssertEqual(idiff?.options.string("left"), "/w/a.png")
        XCTAssertNil(CommandOptions.parseCommandLine([], currentDirectory: "/"))
    }

    // MARK: - SSH

    func testKnownHostsParsing() {
        let text = """
        # comment
        github.com,140.82.112.3 ssh-ed25519 AAAA
        |1|abc=|def= ecdsa-sha2-nistp256 AAAA
        @cert-authority *.example.org ssh-rsa AAAA

        """
        let hosts = SSHSupport.parseKnownHosts(text)
        XCTAssertEqual(hosts.count, 3)
        XCTAssertEqual(hosts[0].primaryHost, "github.com")
        XCTAssertTrue(hosts[1].isHashed)
        XCTAssertNil(hosts[1].primaryHost)
        XCTAssertEqual(hosts[2].keyType, "ssh-rsa")
    }

    func testKeygenArgumentsNeverContainPassphrase() {
        let arguments = SSHSupport.keygenArguments(type: .rsa, bits: 4096, comment: "me", path: "/k")
        XCTAssertEqual(arguments, ["-q", "-t", "rsa", "-b", "4096", "-C", "me", "-f", "/k"])
        XCTAssertFalse(arguments.contains("-N"))
        XCTAssertFalse(SSHSupport.keygenArguments(type: .ed25519, bits: 256, comment: "", path: "/k").contains("-b"))
    }

    func testAskPassAnswersALimitedNumberOfPrompts() throws {
        let (environment, cleanup) = try SSHSupport.askPassEnvironment(secret: "s3cret pass", answers: 2)
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let script = try XCTUnwrap(environment["SSH_ASKPASS"])
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        func ask() -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: script)
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(ask(), "s3cret pass")
        XCTAssertEqual(ask(), "s3cret pass")
        // Afterwards an empty answer, so ssh-add stops retrying a wrong passphrase.
        XCTAssertEqual(ask(), "")
    }

    func testSSHCommandRoundTrip() {
        let command = SSHSupport.sshCommand(forKey: "/Users/me/.ssh/my key")
        XCTAssertEqual(SSHSupport.keyPath(fromSSHCommand: command), "/Users/me/.ssh/my key")
        XCTAssertEqual(SSHSupport.keyPath(fromSSHCommand: "ssh -i /k -o X=y"), "/k")
    }

    // MARK: - Advanced settings

    func testAdvancedSettingsTypedAccess() {
        let config = ConfigManager(suiteName: "test.advanced.\(UUID().uuidString)")
        XCTAssertTrue(config.advancedBool(.versionCheck))
        config.setAdvancedValue("false", for: .versionCheck)
        XCTAssertFalse(config.advancedBool(.versionCheck))
        XCTAssertEqual(config.advancedInt(.daemonPort), 9418)
        config.setAdvancedValue("9000", for: .daemonPort)
        XCTAssertEqual(config.advancedInt(.daemonPort), 9000)
        config.setAdvancedValue(nil, for: .daemonPort)
        XCTAssertEqual(config.advancedInt(.daemonPort), 9418)
        XCTAssertTrue(AdvancedSetting.daemonPort.accepts("12"))
        XCTAssertFalse(AdvancedSetting.daemonPort.accepts("x"))
    }

    func testStoredDecisions() {
        let decisions = StoredDecisions(suiteName: "test.decisions.\(UUID().uuidString)")
        XCTAssertNil(decisions.decision(for: "A"))
        decisions.store(1, for: "A")
        XCTAssertEqual(decisions.decision(for: "A"), 1)
        XCTAssertEqual(decisions.count, 1)
        decisions.removeAll()
        XCTAssertEqual(decisions.count, 0)
    }

    func testActionLogAppendsAndTrims() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("action-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = ActionLog(fileURL: url)
        log.record(repository: "/r", command: "git commit -m x")
        log.record(repository: "/r", command: "git push")
        XCTAssertEqual(log.lineCount, 2)
        XCTAssertTrue(log.contents().contains("git push"))
        try (Array(repeating: "line", count: 10).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        ActionLog.trim(url, to: 3)
        XCTAssertEqual(log.lineCount, 3)
        log.clear()
        XCTAssertEqual(log.contents(), "")
    }
}
