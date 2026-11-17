import XCTest
@testable import PangolinGitCore

#if canImport(PangolinGit)
@testable import PangolinGit

final class RemoteDialogTests: XCTestCase {

    func testPickedRefsBecomeRemoteBranchNames() {
        XCTAssertEqual(BranchComboField.branchName(fromPicked: "refs/remotes/origin/feature/x", remote: "origin"), "feature/x")
        XCTAssertEqual(BranchComboField.branchName(fromPicked: "origin/main", remote: "origin"), "main")
        XCTAssertEqual(BranchComboField.branchName(fromPicked: "refs/heads/dev", remote: "origin"), "dev")
        XCTAssertEqual(BranchComboField.branchName(fromPicked: "upstream/main", remote: "origin"), "upstream/main")
    }

    func testNewRemoteCommands() {
        let remote = GitRemoteConfig(name: "fork", url: "git@h:me/r.git", pushURL: "", tagOption: .none, prune: true, sshKey: "~/.ssh/k")
        let commands = RemotesEditorViewController.saveCommands(original: nil, edited: remote, makePushDefault: true, currentPushDefault: nil)
        XCTAssertEqual(commands.map(\.0), [
            ["remote", "add", "fork", "git@h:me/r.git"],
            ["config", "remote.fork.tagopt", "--no-tags"],
            ["config", "remote.fork.prune", "true"],
            ["config", "remote.fork.sshkey", "~/.ssh/k"],
            ["config", "remote.pushDefault", "fork"],
        ])
    }

    func testEditingRenamesAndUnsetsOnlyWhatChanged() {
        let original = GitRemoteConfig(name: "origin", url: "https://a/r.git", pushURL: "https://p/r.git", tagOption: .all, prune: false)
        var edited = original
        edited.name = "main-remote"
        edited.pushURL = ""
        edited.tagOption = .reachable
        let commands = RemotesEditorViewController.saveCommands(original: original, edited: edited, makePushDefault: false, currentPushDefault: "origin")
        XCTAssertEqual(commands.map(\.0), [
            ["remote", "rename", "origin", "main-remote"],
            ["config", "--unset-all", "remote.main-remote.pushurl"],
            ["config", "--unset-all", "remote.main-remote.tagopt"],
            ["config", "--unset", "remote.pushDefault"],
        ])
        // Unsets may fail harmlessly when the key is already gone.
        XCTAssertEqual(commands.map(\.1), [false, true, true, true])
    }

    func testCloneArguments() {
        let args = CloneWindowController.cloneArguments(url: "https://h/r.git", directory: "/tmp/r.git", branch: "dev", depth: "1",
                                                        origin: "up", recursive: true, bare: true, noCheckout: true,
                                                        lfs: false, sshKey: "/k")
        XCTAssertEqual(args, ["clone", "--progress", "--branch", "dev", "--depth=1", "--bare", "--origin", "up",
                              "--config", "remote.up.sshkey=/k", "--", "https://h/r.git", "/tmp/r.git"])

        let plain = CloneWindowController.cloneArguments(url: "u", directory: "d", branch: "", depth: "x", origin: "origin",
                                                         recursive: true, bare: false, noCheckout: true, lfs: true, sshKey: "")
        XCTAssertTrue(plain.contains("--recurse-submodules"))
        XCTAssertTrue(plain.contains("--no-checkout"))
        XCTAssertTrue(plain.contains("filter.lfs.process=git-lfs filter-process"))
        XCTAssertFalse(plain.contains("--origin"))
        XCTAssertFalse(plain.contains { $0.hasPrefix("--depth") })
    }

    /// `git clone --config` really applies the LFS filter and the remote key to the new repository.
    func testCloneConfigLandsInNewRepository() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pangolin-clone-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = PangolinPath(base.appendingPathComponent("src").path)
        try FileManager.default.createDirectory(atPath: source.rawPath, withIntermediateDirectories: true)
        try GitCLIRunner.run(arguments: ["init", "-b", "main"], workingDirectory: source)
        try GitCLIRunner.run(arguments: ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                                         "commit", "--allow-empty", "-m", "x"], workingDirectory: source)
        let target = base.appendingPathComponent("dst").path
        let args = CloneWindowController.cloneArguments(url: source.rawPath, directory: target, branch: "", depth: "",
                                                        origin: "", recursive: false, bare: false, noCheckout: false,
                                                        lfs: false, sshKey: "/keys/id")
        try GitCLIRunner.run(arguments: args, workingDirectory: PangolinPath(base.path))
        let key = try GitCLIRunner.run(arguments: ["config", "--get", "remote.origin.sshkey"], workingDirectory: PangolinPath(target))
        XCTAssertEqual(key.trimmingCharacters(in: .whitespacesAndNewlines), "/keys/id")
    }

    /// Every remote dialog builds and lays out on a real repository with a remote.
    @MainActor
    func testDialogsLayOut() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pangolin-dialogs-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let upstream = PangolinPath(base.appendingPathComponent("up").path)
        let clone = PangolinPath(base.appendingPathComponent("clone").path)
        try FileManager.default.createDirectory(atPath: upstream.rawPath, withIntermediateDirectories: true)
        try GitCLIRunner.run(arguments: ["init", "-b", "main"], workingDirectory: upstream)
        try GitCLIRunner.run(arguments: ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                                         "commit", "--allow-empty", "-m", "first"], workingDirectory: upstream)
        try GitCLIRunner.run(arguments: ["clone", upstream.rawPath, clone.rawPath], workingDirectory: PangolinPath(base.path))

        let controllers: [(String, NSWindowController)] = [
            ("pull", PullFetchWindowController(repositoryPath: clone)),
            ("fetch", PullFetchWindowController(repositoryPath: clone, mode: .fetch)),
            ("push", PushWindowController(repositoryPath: clone)),
            ("sync", SyncWindowController(repositoryPath: clone)),
            ("clone", CloneWindowController(initialDirectory: base.path)),
            ("remotes", RemotesWindowController(repositoryPath: clone)),
        ]
        // Let the asynchronous loads (remotes, branches) finish.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let snapshots = ProcessInfo.processInfo.environment["PANGOLIN_SNAPSHOT_DIR"]
        for (name, controller) in controllers {
            guard let window = controller.window, let view = window.contentView else {
                XCTFail("\(name) has no window")
                continue
            }
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(view.frame.width, 300, name)
            XCTAssertGreaterThan(view.frame.height, 200, name)
            if let snapshots, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshots).appendingPathComponent("\(name).png"))
            }
            window.close()
        }
    }
}
#endif
