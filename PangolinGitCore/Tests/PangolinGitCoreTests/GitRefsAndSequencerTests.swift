import XCTest
@testable import PangolinGitCore

final class GitRefsTests: XCTestCase {
    private let sep = "\u{1f}"

    private func line(_ fields: [String]) -> String { fields.joined(separator: sep) }

    func testParseForEachRef() {
        let output = [
            line(["refs/heads/main", "aaa", "", "origin/main", "[ahead 1]", "Ann", "1700000000", "Bob", "1700000100", "1700000100", "Fix | pipes: and colons", "*", "commit"]),
            line(["refs/tags/v1", "ttt", "ccc", "", "", "", "", "", "", "1600000000", "Release 1", " ", "tag"]),
            "garbage"
        ].joined(separator: "\n")
        let refs = GitRefs.parseForEachRef(output)
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs[0].shortName, "main")
        XCTAssertEqual(refs[0].kind, .localBranch)
        XCTAssertTrue(refs[0].isHead)
        XCTAssertEqual(refs[0].upstream, "origin/main")
        XCTAssertEqual(refs[0].subject, "Fix | pipes: and colons")
        XCTAssertEqual(refs[0].committerDate, Date(timeIntervalSince1970: 1700000100))
        XCTAssertEqual(refs[1].commitHash, "ccc", "annotated tags are peeled to their commit")
        XCTAssertTrue(refs[1].isAnnotatedTag)
        XCTAssertEqual(refs[1].authorDate, Date(timeIntervalSince1970: 1600000000), "tags fall back to the tagger date")
    }

    func testRefTreeNestsNamespaces() {
        func ref(_ name: String) -> GitRefInfo { GitRefInfo(fullName: name, objectHash: "h", commitHash: "h") }
        let tree = GitRefTreeNode.build(from: [
            ref("refs/heads/main"), ref("refs/heads/feature/b"), ref("refs/heads/feature/a"),
            ref("refs/remotes/origin/HEAD"), ref("refs/remotes/origin/main"), ref("refs/stash")
        ])
        XCTAssertEqual(tree.children.map(\.name), ["heads", "remotes", "tags"])
        XCTAssertEqual(tree.refs.map(\.fullName), ["refs/stash"])
        let heads = tree.node(atPath: "refs/heads")!
        XCTAssertEqual(heads.refs.map(\.shortName), ["main"])
        XCTAssertEqual(heads.child(named: "feature")?.refs.map(\.shortName), ["feature/a", "feature/b"])
        XCTAssertEqual(heads.allRefs(nested: true).count, 3)
        XCTAssertEqual(tree.node(atPath: "refs/remotes/origin")?.refs.map(\.shortName), ["origin/main"], "origin/HEAD is skipped")
        XCTAssertNotNil(tree.node(atPath: "refs/tags"), "empty main namespaces still exist")
    }

    func testBranchDescriptions() {
        let output = "branch.main.description\nMain line\nsecond line\0branch.feature/x.description\nWork\0"
        XCTAssertEqual(GitRefs.parseBranchDescriptions(output), ["main": "Main line\nsecond line", "feature/x": "Work"])
    }

    func testRemoteOfRemoteBranch() {
        XCTAssertEqual(GitRefs.remote(ofRemoteBranch: "team/up/main", remotes: ["team", "team/up"]), "team/up")
        XCTAssertNil(GitRefs.remote(ofRemoteBranch: "main", remotes: ["origin"]))
    }

    func testRefNameValidation() {
        for valid in ["main", "feature/login", "v1.0", "fix-123", "a@b"] {
            XCTAssertNil(GitRefName.validationError(valid), valid)
        }
        for invalid in ["", "-x", "a..b", "a b", "a~1", "a^", "x:y", "a?", "a*", "[a", "a\\b", "/a", "a/", "a.", "a/.b", "a.lock", "a@{1}", "@", "a//b"] {
            XCTAssertNotNil(GitRefName.validationError(invalid), invalid)
        }
    }
}

final class GitReflogTests: XCTestCase {
    func testParsesSubjectsWithPipesAndDates() {
        let output = [
            "HEAD@{1793308903}\u{1f}a5147b8c\u{1f}commit: c | d",
            "HEAD@{1793308800}\u{1f}c0cec25e\u{1f}checkout: moving from main to x",
            "HEAD@{1793308700}\u{1f}c0cec25e\u{1f}commit (initial): a: b"
        ].joined(separator: "\n")
        let entries = GitReflog.parse(output, ref: "HEAD")
        XCTAssertEqual(entries.map(\.selector), ["HEAD@{0}", "HEAD@{1}", "HEAD@{2}"])
        XCTAssertEqual(entries[0].message, "c | d")
        XCTAssertEqual(entries[1].action, "checkout")
        XCTAssertEqual(entries[2].action, "commit (initial)")
        XCTAssertEqual(entries[2].message, "a: b")
        XCTAssertEqual(entries[0].date, Date(timeIntervalSince1970: 1793308903))
    }

    func testStashSelectorsAndMessages() {
        let output = "stash@{1793308903}\u{1f}abc\u{1f}On main: my work\n"
        let entries = GitReflog.parse(output, ref: "refs/stash")
        XCTAssertEqual(entries.first?.selector, "stash@{0}")
        XCTAssertEqual(entries.first?.action, "stash")
        XCTAssertEqual(entries.first?.message, "On main: my work")
    }

    func testArguments() {
        XCTAssertEqual(GitReflog.arguments(ref: "main", limit: 5), ["reflog", "show", "--date=unix", "--format=%gd%x1f%H%x1f%gs", "-n5", "main", "--"])
    }
}

final class GitSequencerTests: XCTestCase {
    func testParseTodo() {
        let todo = """
        pick 1111 First commit
        # comment
        r 2222 Second
        fixup -C 3333 Third one
        exec make test

        drop 4444 Gone
        """
        let lines = GitRebaseProgress.parseTodo(todo)
        XCTAssertEqual(lines.map(\.verb), ["pick", "r", "fixup", "exec", "drop"])
        XCTAssertEqual(lines[1].action, .reword)
        XCTAssertEqual(lines[2].hash, "3333")
        XCTAssertEqual(lines[2].subject, "Third one")
        XCTAssertNil(lines[3].action)
        XCTAssertEqual(lines[3].subject, "make test")
    }

    func testDetectsOperationsFromGitDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gitDir = PangolinPath(dir.path)
        XCTAssertEqual(GitOperationInProgress.detect(gitDirectory: gitDir), .none)
        try "x".write(to: dir.appendingPathComponent("MERGE_HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitOperationInProgress.detect(gitDirectory: gitDir), .merge)
        let rebase = dir.appendingPathComponent("rebase-merge")
        try FileManager.default.createDirectory(at: rebase, withIntermediateDirectories: true)
        try "".write(to: rebase.appendingPathComponent("interactive"), atomically: true, encoding: .utf8)
        try "pick aaaa One\n".write(to: rebase.appendingPathComponent("done"), atomically: true, encoding: .utf8)
        try "pick bbbb Two\nsquash cccc Three\n".write(to: rebase.appendingPathComponent("git-rebase-todo"), atomically: true, encoding: .utf8)
        try "1\n".write(to: rebase.appendingPathComponent("msgnum"), atomically: true, encoding: .utf8)
        try "3\n".write(to: rebase.appendingPathComponent("end"), atomically: true, encoding: .utf8)
        try "refs/heads/topic\n".write(to: rebase.appendingPathComponent("head-name"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitOperationInProgress.detect(gitDirectory: gitDir), .rebase(interactive: true))
        let progress = try XCTUnwrap(GitRebaseProgress.read(gitDirectory: gitDir))
        XCTAssertEqual(progress.step, 1)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.remaining.map(\.hash), ["bbbb", "cccc"])
        XCTAssertEqual(progress.headName, "refs/heads/topic")
        XCTAssertFalse(progress.isEditStop)
    }
}

final class GitCommandOptionsTests: XCTestCase {
    func testMergeArguments() {
        var options = GitMergeOptions(revision: "feature/login")
        options.noFastForward = true
        options.logMessages = 20
        options.strategy = "ort"
        options.strategyOption = "patience"
        options.message = "  Merge login  "
        XCTAssertEqual(options.arguments, ["merge", "--no-ff", "--log=20", "-s", "ort", "-X", "patience", "-m", "Merge login", "feature/login"])
        XCTAssertNil(options.validationError)
        options.squash = true
        XCTAssertNotNil(options.validationError)
        var squash = GitMergeOptions(revision: "x")
        squash.squash = true
        squash.noCommit = true
        XCTAssertEqual(squash.arguments, ["merge", "--squash", "x"], "--squash already implies no commit")
        var pending = GitMergeOptions(revision: "x")
        pending.strategyOption = "rename-threshold="
        XCTAssertNotNil(pending.validationError)
    }

    func testSwitchArguments() {
        var options = GitSwitchOptions(target: "origin/topic")
        options.newBranch = "topic"
        options.track = true
        XCTAssertEqual(options.arguments, ["checkout", "--track", "-b", "topic", "origin/topic", "--"])
        options.overrideExistingBranch = true
        options.track = false
        options.merge = true
        XCTAssertEqual(options.arguments, ["checkout", "--merge", "--no-track", "-B", "topic", "origin/topic", "--"])
        XCTAssertEqual(GitSwitchOptions(target: "v1.0").arguments, ["checkout", "v1.0", "--"])
    }

    func testRebaseArguments() {
        var options = GitRebaseOptions(upstream: "main")
        options.onto = "release"
        options.branch = "topic"
        options.rebaseMerges = true
        options.autosquash = true
        XCTAssertEqual(options.arguments, ["rebase", "--interactive", "--rebase-merges", "--no-autostash", "--autosquash",
                                           "--onto", "release", "main", "topic"])
    }

    func testRebaseTodoRendersRewordAsExec() {
        let steps = [
            GitRebaseStep(action: .pick, hash: "aaa", subject: "One"),
            GitRebaseStep(action: .reword, hash: "bbb", subject: "Two", newMessage: "Better"),
            GitRebaseStep(action: .drop, hash: "ccc", subject: "Three")
        ]
        let todo = GitRebaseTodo.render(steps) { _ in "/tmp/it's.txt" }
        XCTAssertEqual(todo, "pick aaa One\npick bbb Two\nexec git commit --amend --allow-empty -F '/tmp/it'\\''s.txt'\ndrop ccc Three\n")
        XCTAssertNil(GitRebaseTodo.validationError(steps))
        XCTAssertNotNil(GitRebaseTodo.validationError([GitRebaseStep(action: .drop, hash: "a", subject: ""),
                                                       GitRebaseStep(action: .squash, hash: "b", subject: "")]))
    }

    func testAutosquashMovesMarkedCommits() {
        let steps = [
            GitRebaseStep(hash: "a1", subject: "Add login"),
            GitRebaseStep(hash: "b2", subject: "Add logout"),
            GitRebaseStep(hash: "c3", subject: "fixup! Add login"),
            GitRebaseStep(hash: "d4", subject: "squash! Add logout"),
            GitRebaseStep(hash: "e5", subject: "fixup! fixup! Add login"),
            GitRebaseStep(hash: "f6", subject: "fixup! Nothing matches")
        ]
        let result = GitRebaseTodo.autosquash(steps)
        XCTAssertEqual(result.map(\.hash), ["a1", "c3", "e5", "b2", "d4", "f6"])
        XCTAssertEqual(result.map(\.action), [.pick, .fixup, .fixup, .pick, .squash, .pick])
    }

    func testStashArguments() {
        var options = GitStashPushOptions()
        options.message = "wip"
        options.includeUntracked = true
        options.includeIgnored = true
        options.paths = ["a.txt"]
        XCTAssertEqual(options.arguments, ["stash", "push", "-m", "wip", "--all", "--", "a.txt"])
    }

    func testCherryPickArguments() {
        var options = GitCherryPickOptions(commits: ["a", "b"])
        options.recordOrigin = true
        options.mainline = 1
        XCTAssertEqual(options.arguments, ["cherry-pick", "-x", "-m", "1", "a", "b"])
    }
}
