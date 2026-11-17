import XCTest
@testable import PangolinGitCore

/// Parsing and command building behind Resolve, Revert, Clean up, Ignore and the status-list extras.
final class WorkingTreeOperationTests: XCTestCase {

    // MARK: - Operation state and conflict labels

    func testDetectsOperationInProgress() {
        XCTAssertNil(GitOperationInProgress.detect(existing: []))
        XCTAssertEqual(GitOperationInProgress.detect(existing: ["MERGE_HEAD"]), .merge)
        XCTAssertEqual(GitOperationInProgress.detect(existing: ["CHERRY_PICK_HEAD"]), .cherryPick)
        XCTAssertEqual(GitOperationInProgress.detect(existing: ["REVERT_HEAD"]), .revert)
        // A rebase that stops on a cherry-picked commit also leaves CHERRY_PICK_HEAD behind.
        XCTAssertEqual(GitOperationInProgress.detect(existing: ["rebase-merge", "CHERRY_PICK_HEAD"]), .rebase(interactive: false))
        XCTAssertEqual(GitOperationInProgress.detect(existing: ["rebase-apply", "rebase-apply/applying"]), .applyMailbox)
        XCTAssertEqual(GitOperationInProgress.merge.abortArguments, nil)
        XCTAssertEqual(GitOperationInProgress.cherryPick.abortArguments, ["cherry-pick", "--abort"])
    }

    func testMergeSourceNameFromMergeMessage() {
        XCTAssertEqual(GitRepository.mergeSourceName(fromMergeMessage: "Merge branch 'feature/x' into main\n\n# Conflicts:"), "feature/x")
        XCTAssertEqual(GitRepository.mergeSourceName(fromMergeMessage: "Merge remote-tracking branch 'origin/dev'"), "origin/dev")
        XCTAssertNil(GitRepository.mergeSourceName(fromMergeMessage: "Some other message"))
        XCTAssertNil(GitRepository.mergeSourceName(fromMergeMessage: ""))
    }

    // MARK: - Resolve

    func testParsesUnmergedStages() {
        let output = "100644 aaa 1\tboth.txt\0100644 bbb 2\tboth.txt\0100644 ccc 3\tboth.txt\0100644 ddd 1\tgone.txt\0100644 eee 2\tgone.txt\0"
        let stages = GitRepository.parseUnmergedStages(output)
        XCTAssertEqual(stages["both.txt"], [1, 2, 3])
        XCTAssertEqual(stages["gone.txt"], [1, 2])
    }

    func testResolveCommandsCheckOutOrDeletePerSide() {
        let stages: [String: Set<Int>] = ["both.txt": [1, 2, 3], "gone.txt": [1, 2]]
        XCTAssertEqual(GitRepository.resolveCommands(paths: ["both.txt", "gone.txt"], side: .theirs, stages: stages), [
            ["checkout", "--theirs", "--", "both.txt"],
            ["add", "-v", "--", "both.txt"],
            ["rm", "-f", "--", "gone.txt"]
        ])
        XCTAssertEqual(GitRepository.resolveCommands(paths: ["both.txt", "gone.txt"], side: .mine, stages: stages), [
            ["checkout", "--ours", "--", "both.txt", "gone.txt"],
            ["add", "-v", "--", "both.txt", "gone.txt"]
        ])
    }

    // MARK: - Revert

    func testRevertCommandsRestoreAndUnstage() {
        let items = [
            GitItemStatusInfo(path: "mod.txt", status: .modified),
            GitItemStatusInfo(path: "new.txt", status: .added, stagedStatus: .added),
            GitItemStatusInfo(path: "gone.txt", status: .missing),
            GitItemStatusInfo(path: "renamed.txt", status: .renamed, stagedStatus: .renamed, originalPath: "old.txt"),
            GitItemStatusInfo(path: "junk.tmp", status: .untracked)
        ]
        XCTAssertEqual(GitRepository.revertCommands(for: items), [
            ["rm", "--cached", "-r", "--", "new.txt", "renamed.txt"],
            ["restore", "--source=HEAD", "--staged", "--worktree", "--", "mod.txt", "gone.txt", "old.txt"]
        ])
        // Only files that still exist on disk are worth keeping in the Trash.
        XCTAssertEqual(GitRepository.filesOverwrittenByRevert(items), ["mod.txt"])
        XCTAssertEqual(GitRepository.revertCommands(for: [items[0]], hasHead: false), [["checkout", "--", "mod.txt"]])
    }

    // MARK: - Clean up

    func testCleanArguments() {
        XCTAssertEqual(GitRepository.cleanArguments(GitCleanOptions(), dryRun: true), ["clean", "-n", "-d", "-f"])
        let all = GitCleanOptions(scope: .allUntracked, directories: false, nestedRepositories: true)
        XCTAssertEqual(GitRepository.cleanArguments(all, dryRun: false, paths: ["build", ""]), ["clean", "-fx", "-f", "--", "build"])
        XCTAssertEqual(GitRepository.cleanArguments(GitCleanOptions(scope: .ignoredOnly), dryRun: false), ["clean", "-d", "-fX"])
        XCTAssertEqual(GitRepository.submoduleCleanArguments(GitCleanOptions(), dryRun: true),
                       ["submodule", "foreach", "--recursive", "git", "clean", "-n", "-d", "-f"])
    }

    func testParsesCleanDryRunIncludingSubmodulesAndQuoting() {
        let output = """
        Would remove build/
        Would remove "caf\\303\\251.txt"
        Entering 'libs/sub'
        Would remove tmp.o
        Would skip repository nested/
        """
        XCTAssertEqual(GitRepository.parseCleanDryRun(output), ["build/", "café.txt", "libs/sub/tmp.o"])
        XCTAssertEqual(GitRepository.unquoteGitPath("\"a\\tb\\\"c\""), "a\tb\"c")
        XCTAssertEqual(GitRepository.unquoteGitPath("plain.txt"), "plain.txt")
    }

    // MARK: - Ignore

    func testParsesCheckIgnoreAndSkipsNegations() {
        let output = ".gitignore:3:*.log\tdebug.log\nsub/.gitignore:1:!keep.log\tsub/keep.log\n/Users/me/.config/git/ignore:12:a:b\t\"sp ace\\303\\251\"\n"
        let matches = GitRepository.parseCheckIgnore(output)
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches[2], GitIgnoreMatch(source: "/Users/me/.config/git/ignore", lineNumber: 12, pattern: "a:b", path: "sp aceé"))
        XCTAssertEqual(matches[0], GitIgnoreMatch(source: ".gitignore", lineNumber: 3, pattern: "*.log", path: "debug.log"))
        XCTAssertTrue(matches[1].isNegation)
    }

    func testIgnorePatternsFollowTortoiseGitRules() {
        // Root .gitignore, only this folder: anchored with the folder path.
        XCTAssertEqual(GitIgnoreFile.pattern(forPath: "src/app/x.o", byExtension: false, scope: .containingFolderOnly, location: .rootGitignore), "/src/app/x.o")
        XCTAssertEqual(GitIgnoreFile.pattern(forPath: "src/app/x.o", byExtension: true, scope: .containingFolderOnly, location: .rootGitignore), "/src/app/*.o")
        // Recursive: bare name anywhere below the ignore file.
        XCTAssertEqual(GitIgnoreFile.pattern(forPath: "src/app/x.o", byExtension: false, scope: .recursive, location: .rootGitignore), "x.o")
        // Containing folder's own .gitignore: anchored to that folder.
        XCTAssertEqual(GitIgnoreFile.pattern(forPath: "src/app/x.o", byExtension: false, scope: .containingFolderOnly, location: .containingFolder), "/x.o")
        XCTAssertEqual(GitIgnoreFile.ignoreFileFolder(for: "src/app/x.o", location: .containingFolder), "src/app")
        XCTAssertNil(GitIgnoreFile.ignoreFileFolder(for: "x.o", location: .localExclude))
        // Folders keep a trailing slash; extensionless names have no extension pattern.
        XCTAssertEqual(GitIgnoreFile.pattern(forPath: "build/", byExtension: false, scope: .containingFolderOnly, location: .rootGitignore), "/build/")
        XCTAssertNil(GitIgnoreFile.pattern(forPath: "Makefile", byExtension: true, scope: .recursive, location: .rootGitignore))
        XCTAssertEqual(GitIgnoreFile.exceptionPattern(forPath: "logs/keep.log"), "!/logs/keep.log")
    }

    func testRemovingIgnoreLine() {
        XCTAssertEqual(GitIgnoreFile.removingLine(2, from: "a\nb\nc\n"), "a\nc\n")
        XCTAssertEqual(GitIgnoreFile.removingLine(3, from: "a\nb\nc"), "a\nb")
        XCTAssertEqual(GitIgnoreFile.removingLine(9, from: "a\n"), "a\n")
    }

    // MARK: - Flags and line counts

    func testParsesLocalChangeFlags() {
        let flags = GitRepository.parseLocalChangeFlags("H normal.txt\0h assumed.txt\0S skipped.txt\0")
        XCTAssertEqual(flags, ["assumed.txt": .assumeUnchanged, "skipped.txt": .skipWorktree])
        XCTAssertEqual(GitRepository.flagCommands(nil, paths: ["a"]).count, 2)
    }

    func testParsesNumstat() {
        let counts = GitRepository.parseNumstat("3\t1\ta.txt\0-\t-\timage.png\u{0}2\t0\t\u{0}old.txt\u{0}new.txt\u{0}")
        XCTAssertEqual(counts["a.txt"], GitLineCount(added: 3, removed: 1))
        XCTAssertEqual(counts["image.png"], GitLineCount(added: nil, removed: nil))
        XCTAssertEqual(counts["new.txt"], GitLineCount(added: 2, removed: 0))
    }

    // MARK: - Changelists

    func testChangelistStorePersistsPerRepository() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("changelists-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = PangolinPath("/tmp/some-repo")
        let store = ChangelistStore(repositoryRoot: root, directory: folder)
        store.move(["a.txt", "b.txt"], to: "UI work")
        store.move(["local.json"], to: ChangelistStore.ignoreOnCommit)
        XCTAssertEqual(store.names, ["UI work", ChangelistStore.ignoreOnCommit])

        let reloaded = ChangelistStore(repositoryRoot: root, directory: folder)
        XCTAssertEqual(reloaded.changelist(for: "b.txt"), "UI work")
        reloaded.remove(["b.txt"])
        reloaded.prune(keeping: ["local.json"])
        XCTAssertEqual(reloaded.assignments, ["local.json": ChangelistStore.ignoreOnCommit])
        XCTAssertNotEqual(ChangelistStore(repositoryRoot: PangolinPath("/tmp/other"), directory: folder).fileURL, store.fileURL)
    }
}
