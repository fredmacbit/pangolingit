import XCTest
@testable import PangolinGitCore

final class GitPatchSeriesTests: XCTestCase {
    func testFormatPatchArguments() {
        XCTAssertEqual(GitPatchSeries.formatPatchArguments(range: .since("origin/main"), outputDirectory: "/tmp/out", noPrefix: false),
                       ["format-patch", "--binary", "-o", "/tmp/out", "--end-of-options", "origin/main", "--"])
        XCTAssertEqual(GitPatchSeries.formatPatchArguments(range: .last(3), outputDirectory: "/o", noPrefix: true, binary: false),
                       ["format-patch", "--no-prefix", "-o", "/o", "-3", "--"])
        XCTAssertEqual(GitPatchSeries.formatPatchArguments(range: .between(from: "v1", to: "HEAD"), outputDirectory: "/o", noPrefix: false).suffix(3),
                       ["--end-of-options", "v1..HEAD", "--"])
    }

    func testWrittenFiles() {
        let output = "/tmp/out/0001-Fix-a.patch\n/tmp/out/0002-Add-b.patch\n"
        XCTAssertEqual(GitPatchSeries.writtenFiles(fromFormatPatchOutput: output), ["/tmp/out/0001-Fix-a.patch", "/tmp/out/0002-Add-b.patch"])
    }

    func testAmArguments() {
        XCTAssertEqual(GitPatchSeries.amArguments(files: ["a.patch", "b.patch"], threeWay: true, ignoreSpaceChange: false, signOff: true, keepCR: true),
                       ["am", "--signoff", "--3way", "--keep-cr", "--", "a.patch", "b.patch"])
    }

    func testMailboxDetectionAndHeader() {
        let patch = """
        From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001
        From: =?UTF-8?q?J=C3=BCrgen=20M=C3=BCller?= <jm@example.com>
        Date: Tue, 1 Oct 2024 10:00:00 +0200
        Subject: [PATCH 2/3] Fix the
         long subject line

        body
        """
        XCTAssertTrue(GitPatchSeries.isMailboxPatch(patch))
        XCTAssertFalse(GitPatchSeries.isMailboxPatch("diff --git a/x b/x\n"))
        let header = GitPatchSeries.mailHeader(of: patch)
        XCTAssertEqual(header.from, "Jürgen Müller <jm@example.com>")
        XCTAssertEqual(header.subject, "[PATCH 2/3] Fix the long subject line")
        XCTAssertEqual(header.strippedSubject, "Fix the long subject line")
        XCTAssertEqual(header.date, "Tue, 1 Oct 2024 10:00:00 +0200")
    }

    func testEncodedWords() {
        XCTAssertEqual(GitPatchSeries.decodeEncodedWords("=?UTF-8?B?w6TDtsO8?= =?UTF-8?q?_x?="), "äöü x")
        XCTAssertEqual(GitPatchSeries.decodeEncodedWords("plain text"), "plain text")
    }

    func testWorktreePorcelain() {
        let output = """
        worktree /repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /wt/feature
        HEAD 2222222222222222222222222222222222222222
        detached
        locked on a USB disk

        worktree /wt/gone
        HEAD 3333333333333333333333333333333333333333
        branch refs/heads/old
        prunable gitdir file points to non-existent location

        """
        let items = GitWorktreeInfo.parse(porcelain: output)
        XCTAssertEqual(items.map(\.path), ["/repo", "/wt/feature", "/wt/gone"])
        XCTAssertTrue(items[0].isMain)
        XCTAssertEqual(items[0].branch, "main")
        XCTAssertTrue(items[1].isDetached)
        XCTAssertNil(items[1].branch)
        XCTAssertTrue(items[1].isLocked)
        XCTAssertEqual(items[1].lockReason, "on a USB disk")
        XCTAssertTrue(items[2].isPrunable)
        XCTAssertFalse(items[2].isMain)
    }
}

final class GitBlameParserTests: XCTestCase {
    func testLinePorcelain() {
        let a = String(repeating: "a", count: 40)
        let b = String(repeating: "b", count: 40)
        let output = """
        \(a) 1 1 2
        author Alice
        author-mail <alice@example.com>
        author-time 1700000000
        summary First
        previous \(b) old name.txt
        filename new name.txt
        \tline one
        \(a) 2 2
        author Alice
        author-mail <alice@example.com>
        author-time 1700000000
        summary First
        boundary
        filename new name.txt
        \tline two

        """
        let lines = GitBlame.parse(linePorcelain: output)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].hash, a)
        XCTAssertEqual(lines[0].authorMail, "alice@example.com")
        XCTAssertEqual(lines[0].previousHash, b)
        XCTAssertEqual(lines[0].previousFilename, "old name.txt")
        XCTAssertEqual(lines[0].filename, "new name.txt")
        XCTAssertEqual(lines[0].code, "line one")
        XCTAssertTrue(lines[1].isBoundary)
        XCTAssertNil(lines[1].previousHash)
        XCTAssertEqual(lines[1].finalLine, 2)
        XCTAssertEqual(GitBlame.blockStarts(lines), [0])
    }

    func testArguments() {
        XCTAssertEqual(GitBlame.arguments(path: "a.c", revision: nil, ignoreWhitespace: true, detection: .fromExistingFiles),
                       ["blame", "--line-porcelain", "-w", "-C", "-C", "--", "a.c"])
        XCTAssertEqual(GitBlame.arguments(path: "a.c", revision: "abc", ignoreWhitespace: false, detection: .withinFile, threshold: 40, firstParent: true),
                       ["blame", "--line-porcelain", "--first-parent", "-M40", "abc", "--", "a.c"])
    }
}

final class RevisionGraphBuilderTests: XCTestCase {
    func testDecorations() {
        let refs = RevisionGraphBuilder.parseDecorations("HEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD, tag: refs/tags/v1.0, refs/stash")
        XCTAssertEqual(refs.map(\.kind), [.localBranch, .remoteBranch, .tag, .stash])
        XCTAssertEqual(refs.map(\.shortName), ["main", "origin/main", "v1.0", "stash"])
        XCTAssertTrue(refs[0].isCurrent)
        XCTAssertEqual(RevisionGraphBuilder.parseDecorations("HEAD").first?.kind, .head)
    }

    func testParseLog() {
        let output = "c1\u{1f}p1 p2\u{1f}tag: refs/tags/v2\u{1f}Merge\u{1f}Bob\u{1f}1700000000\u{1e}\n"
        let commits = RevisionGraphBuilder.parseLog(output)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].parents, ["p1", "p2"])
        XCTAssertEqual(commits[0].refs.first?.shortName, "v2")
        XCTAssertEqual(commits[0].timestamp, 1_700_000_000)
    }

    /// main: R - A - B - M(main), feature: A - F1 - F2(feature) merged into M; tag on A.
    private var history: [RevisionGraphCommit] {
        let main = RevisionGraphRef(fullName: "refs/heads/main", kind: .localBranch, isCurrent: true)
        let feature = RevisionGraphRef(fullName: "refs/heads/feature", kind: .localBranch)
        let tag = RevisionGraphRef(fullName: "refs/tags/v1", kind: .tag)
        return [
            RevisionGraphCommit(hash: "M", parents: ["B", "F2"], refs: [main]),
            RevisionGraphCommit(hash: "F2", parents: ["F1"], refs: [feature]),
            RevisionGraphCommit(hash: "F1", parents: ["A"]),
            RevisionGraphCommit(hash: "B", parents: ["A"]),
            RevisionGraphCommit(hash: "A", parents: ["R"], refs: [tag]),
            RevisionGraphCommit(hash: "R", parents: [])
        ]
    }

    func testSimplifyDecorationsOnly() {
        let simplified = RevisionGraphBuilder.simplify(history, branchPoints: false)
        XCTAssertEqual(simplified.map(\.hash), ["M", "F2", "A", "R"])
        // B is hidden, so M's mainline parent becomes A; the merged branch stays as the second parent.
        XCTAssertEqual(simplified[0].parents, ["A", "F2"])
        XCTAssertEqual(simplified[1].parents, ["A"])
        XCTAssertEqual(simplified[2].parents, ["R"])
    }

    func testSimplifyWithBranchPoints() {
        let simplified = RevisionGraphBuilder.simplify(history, branchPoints: true)
        XCTAssertEqual(simplified.map(\.hash), ["M", "F2", "A", "R"])
        let withoutTags = RevisionGraphBuilder.simplify(history, branchPoints: true, includeTags: false)
        // A stays: it is a branch point (B and F1 both descend from it).
        XCTAssertTrue(withoutTags.contains { $0.hash == "A" })
        XCTAssertEqual(withoutTags.first { $0.hash == "M" }?.parents, ["A", "F2"])
        // A merge whose second parent is already reachable from the first loses that redundant edge.
        let redundant = [
            RevisionGraphCommit(hash: "M", parents: ["X", "A"], refs: [RevisionGraphRef(fullName: "refs/heads/m", kind: .localBranch)]),
            RevisionGraphCommit(hash: "X", parents: ["A"], refs: [RevisionGraphRef(fullName: "refs/tags/x", kind: .tag)]),
            RevisionGraphCommit(hash: "A", parents: [])
        ]
        XCTAssertEqual(RevisionGraphBuilder.simplify(redundant, branchPoints: false)[0].parents, ["X"])
    }

    func testLayoutAssignsRowsAndLanes() {
        let nodes = RevisionGraphBuilder.layout(RevisionGraphBuilder.simplify(history, branchPoints: false))
        XCTAssertEqual(nodes.map(\.row), [0, 1, 2, 3])
        XCTAssertEqual(nodes[0].lane, 0)
    }
}
