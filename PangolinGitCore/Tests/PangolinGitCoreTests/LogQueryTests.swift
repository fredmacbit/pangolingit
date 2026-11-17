import XCTest
@testable import PangolinGitCore

final class GitLogQueryTests: XCTestCase {

    func testDefaultQueryWalksHead() {
        let args = GitLogQuery().walkArguments()
        XCTAssertEqual(args, ["--parents", "HEAD", "--"])
    }

    func testScopesMapToTortoiseGitArguments() {
        var query = GitLogQuery()
        query.scope = .allRefs
        XCTAssertTrue(query.walkArguments().contains("--all"))
        query.scope = .basicRefs
        XCTAssertEqual(Array(query.walkArguments().dropFirst().prefix(5)),
                       ["--branches", "--tags", "--remotes", "--glob=stas[h]", "--glob=bisect"])
        query.scope = .localBranches
        XCTAssertTrue(query.walkArguments().contains("--branches"))
        query.scope = .refs(["main..feature", "v1 v2"])
        XCTAssertEqual(query.walkArguments(), ["--parents", "main..feature", "v1", "v2", "--"])
    }

    func testWalkOptionsAndPath() {
        var query = GitLogQuery()
        query.firstParent = true
        query.noMerges = true
        query.fullHistory = true
        query.simplifyByDecoration = true
        query.path = "src/a.swift"
        query.followRenames = true
        query.limit = .commits(50)
        let args = query.walkArguments()
        XCTAssertEqual(args, ["--first-parent", "--no-merges", "--full-history", "--simplify-by-decoration", "--follow",
                              "--max-count=50", "HEAD", "--", "src/a.swift"])
    }

    func testFollowNeedsPath() {
        var query = GitLogQuery()
        query.followRenames = true
        XCTAssertFalse(query.walkArguments().contains("--follow"))
    }

    func testDateLimitsUseTheLaterBound() {
        var query = GitLogQuery()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        query.limit = .weeks(1)
        let weekAgo = Calendar.current.startOfDay(for: now).addingTimeInterval(-7 * 86_400)
        XCTAssertTrue(query.walkArguments(now: now).contains("--since=\(Int(weekAgo.timeIntervalSince1970))"))
        // An explicit From date later than the limit wins.
        query.since = now.addingTimeInterval(-3600)
        XCTAssertTrue(query.walkArguments(now: now).contains("--since=\(Int(now.timeIntervalSince1970) - 3600)"))
        query.until = now
        XCTAssertTrue(query.walkArguments(now: now).contains("--until=\(Int(now.timeIntervalSince1970))"))
    }

    func testMailmapFormat() {
        var query = GitLogQuery()
        XCTAssertTrue(query.arguments().contains { $0.contains("%aN%x1f%aE") })
        query.useMailmap = false
        XCTAssertTrue(query.arguments().contains { $0.contains("%an%x1f%ae") })
    }

    func testLimitRoundTrip() {
        XCTAssertEqual(GitLogQuery.Limit(kind: "months", count: 3), .months(3))
        XCTAssertEqual(GitLogQuery.Limit(kind: "bogus", count: 3), .unlimited)
        XCTAssertEqual(GitLogQuery.Limit.commits(7).kind, "commits")
        XCTAssertEqual(GitLogQuery.Limit.commits(7).count, 7)
    }

    func testParseEntriesWithNotesAndBody() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let output = "\u{1e}\(a)\u{1f}\(b)\u{1f}Ann\u{1f}ann@x\u{1f}2024-01-02T03:04:05+00:00\u{1f}Bob\u{1f}bob@x\u{1f}2024-01-03T03:04:05+00:00"
            + "\u{1f}HEAD -> main, tag: v1\u{1f}Subject line\u{1f}A note\n\u{1f}Body text\n\n"
            + "\u{1e}\(b)\u{1f}\u{1f}Ann\u{1f}ann@x\u{1f}2024-01-01T00:00:00+00:00\u{1f}Ann\u{1f}ann@x\u{1f}2024-01-01T00:00:00+00:00"
            + "\u{1f}\u{1f}Root\u{1f}\u{1f}\n"
        let entries = GitLogParser.parse(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].revision.subject, "Subject line")
        XCTAssertEqual(entries[0].revision.body, "Body text")
        XCTAssertEqual(entries[0].notes, "A note")
        XCTAssertEqual(entries[0].revision.committer.name, "Bob")
        XCTAssertEqual(entries[0].revision.parentHashes.map(\.string), [b])
        XCTAssertEqual(entries[0].revision.refs, ["main", "tag: v1"])
        XCTAssertTrue(entries[1].revision.parentHashes.isEmpty)
        XCTAssertEqual(entries[1].notes, "")
    }
}

final class GitRefMapTests: XCTestCase {
    private let c1 = String(repeating: "1", count: 40)
    private let c2 = String(repeating: "2", count: 40)
    private let tagObject = String(repeating: "9", count: 40)

    private var output: String {
        [
            "\(c1)  commit refs/heads/main refs/remotes/origin/main",
            "\(c2)  commit refs/heads/feature ",
            "\(c1)  commit refs/remotes/origin/main ",
            "\(c1)  commit refs/remotes/origin/HEAD ",
            "\(tagObject) \(c2) tag refs/tags/v1.0 ",
            "\(c2)  commit refs/tags/light ",
            "\(c2)  commit refs/stash ",
            "\(c1)  commit refs/notes/commits "
        ].joined(separator: "\n")
    }

    func testParsesKindsPeelsTagsAndSkipsSymbolicAndNotes() {
        let map = GitRefMap.parse(forEachRef: output, headRef: "refs/heads/main\n", headHash: c1)
        XCTAssertEqual(map.currentBranch, "main")
        XCTAssertEqual(map.labels(for: c1).map(\.fullName), ["refs/heads/main", "refs/remotes/origin/main"])
        XCTAssertTrue(map.labels(for: c1)[0].isCurrent)
        let second = map.labels(for: c2)
        XCTAssertEqual(second.map(\.kind), [.localBranch, .annotatedTag, .tag, .stash])
        XCTAssertNil(map.labelsByHash[tagObject])
        XCTAssertEqual(map.upstreams["refs/heads/main"], "refs/remotes/origin/main")
        XCTAssertEqual(map.hash(forRef: "v1.0"), c2)
    }

    func testDetachedHeadGetsHeadLabel() {
        let map = GitRefMap.parse(forEachRef: output, headRef: "", headHash: c2 + "\n")
        XCTAssertNil(map.currentBranch)
        XCTAssertEqual(map.labels(for: c2).first?.kind, .head)
        XCTAssertEqual(map.headHash, c2)
    }

    func testSymbolizedNames() {
        let map = GitRefMap.parse(forEachRef: output, headRef: "refs/heads/main", headHash: c1)
        let remote = map.labels(for: c1)[1]
        XCTAssertEqual(map.displayName(for: remote, symbolize: false), "origin/main")
        XCTAssertEqual(map.displayName(for: remote, symbolize: true), "/≡")
        let other = GitRefLabel(fullName: "refs/remotes/origin/topic", kind: .remoteBranch)
        XCTAssertEqual(map.displayName(for: other, symbolize: true), "/topic")
    }
}

final class LogSearchFilterTests: XCTestCase {

    func testAllTermsMustMatchCaseInsensitively() {
        let filter = LogSearchFilter("fix crash")
        XCTAssertTrue(filter.matches("Fix the CRASH on start"))
        XCTAssertFalse(filter.matches("fix typo"))
    }

    func testExcludeOrAndQuotes() {
        XCTAssertFalse(LogSearchFilter("fix -typo").matches("fix typo"))
        XCTAssertTrue(LogSearchFilter("fix -typo").matches("fix crash"))
        let either = LogSearchFilter("alpha +beta")
        XCTAssertTrue(either.matches("beta only"))
        XCTAssertTrue(either.matches("alpha only"))
        XCTAssertFalse(either.matches("gamma"))
        let quoted = LogSearchFilter("\"two words\"")
        XCTAssertTrue(quoted.matches("has two words here"))
        XCTAssertFalse(quoted.matches("two separate words"))
        XCTAssertTrue(LogSearchFilter("\"say \"\"hi\"\"\"").matches("say \"hi\" now"))
    }

    func testNegationAndCaseSensitivity() {
        XCTAssertFalse(LogSearchFilter("!fix").matches("fix it"))
        XCTAssertTrue(LogSearchFilter("!fix").matches("other"))
        XCTAssertFalse(LogSearchFilter("Fix", caseSensitive: true).matches("fix"))
    }

    func testRegex() {
        let filter = LogSearchFilter("^(feat|fix):", useRegex: true)
        XCTAssertTrue(filter.matches("fix: thing"))
        XCTAssertFalse(filter.matches("chore: fix: thing"))
        let invalid = LogSearchFilter("(", useRegex: true)
        XCTAssertTrue(invalid.isInvalidRegex)
        XCTAssertFalse(invalid.matches("("))
    }

    func testEmptyFilterIsInactive() {
        XCTAssertFalse(LogSearchFilter("   ").isActive)
        XCTAssertTrue(LogSearchFilter("").matches("anything"))
    }

    func testSearchableTextHonoursFields() {
        let revision = GitRevision(hash: GitHash(uncheckedHex: String(repeating: "c", count: 40)),
                                   author: GitAuthor(name: "Ann", email: "ann@example.com"),
                                   committer: GitAuthor(name: "Ann", email: "ann@example.com"),
                                   subject: "Subject", body: "Body")
        let entry = GitLogEntry(revision: revision, notes: "noted")
        let subjectOnly = LogSearchFilter("x", fields: [.subject])
        let text = subjectOnly.searchableText(for: entry, refNames: ["main"], paths: ["a.txt"])
        XCTAssertEqual(text, "Subject")
        let all = LogSearchFilter("x", fields: .all).searchableText(for: entry, refNames: ["main"], paths: ["a.txt"])
        for part in ["Subject", "Body", "ann@example.com", "noted", "main", "a.txt", revision.hash.string] {
            XCTAssertTrue(all.contains(part), part)
        }
    }
}

final class LogStatisticsTests: XCTestCase {

    private func revision(_ n: Int, author: String, days: Double, parents: Int = 1) -> GitRevision {
        let hash = GitHash(uncheckedHex: String(format: "%040d", n))
        let date = Date(timeIntervalSince1970: 1_700_000_000 + days * 86_400)
        return GitRevision(hash: hash, parentHashes: Array(repeating: GitHash.zero, count: parents),
                           author: GitAuthor(name: author, email: "\(author)@x", date: date),
                           committer: GitAuthor(name: "Committer", email: "c@x", date: date), subject: "s\(n)")
    }

    func testNumstatParsing() {
        let output = "\u{1e}abc\n\n3\t1\tsrc/a.swift\n10\t0\tnew.txt\n0\t4\told.txt\n-\t-\timage.png\n create mode 100644 new.txt\n delete mode 100644 old.txt\n"
            + "\u{1e}def\n"
        let stats = CommitStatsParser.parse(output)
        XCTAssertEqual(stats["abc"]?.filesChanged, 4)
        XCTAssertEqual(stats["abc"]?.linesAdded, 3)
        XCTAssertEqual(stats["abc"]?.linesRemoved, 1)
        XCTAssertEqual(stats["abc"]?.linesInNewFiles, 10)
        XCTAssertEqual(stats["abc"]?.linesInDeletedFiles, 4)
        XCTAssertEqual(stats["def"]?.filesChanged, 0)
        XCTAssertEqual(CommitStatsParser.parseNameOnly("\u{1e}abc\n\na\nb/c\n")["abc"], ["a", "b/c"])
    }

    func testCountsAuthorsBucketsAndAuthorship() {
        let revisions = [
            revision(1, author: "Ann", days: 0),
            revision(2, author: "ann", days: 1),
            revision(3, author: "Bob", days: 2),
            revision(4, author: "Ann", days: 3)
        ]
        let stats = LogStatistics(entries: revisions)
        XCTAssertEqual(stats.totalCommits, 4)
        XCTAssertEqual(stats.unit, .day)
        XCTAssertEqual(stats.authors.first, "Ann")
        XCTAssertEqual(Set(stats.authors), ["Ann", "ann", "Bob"])
        XCTAssertEqual(stats.commitsPerAuthor["Ann"], 2)
        XCTAssertEqual(stats.buckets.count, 4)
        XCTAssertEqual(stats.percentageOfAuthorship.values.reduce(0, +), 100, accuracy: 0.001)

        var options = LogStatistics.Options()
        options.authorsCaseSensitive = false
        let folded = LogStatistics(entries: revisions, options: options)
        XCTAssertEqual(folded.commitsPerAuthor["ann"], 3)
        XCTAssertEqual(folded.authors.first, "ann")

        options.useCommitterNames = true
        XCTAssertEqual(LogStatistics(entries: revisions, options: options).authors, ["committer"])
    }

    func testTimeUnitFollowsSpan() {
        XCTAssertEqual(LogStatistics(entries: [revision(1, author: "a", days: 0), revision(2, author: "a", days: 50)]).unit, .week)
        XCTAssertEqual(LogStatistics(entries: [revision(1, author: "a", days: 0), revision(2, author: "a", days: 300)]).unit, .month)
        XCTAssertEqual(LogStatistics(entries: [revision(1, author: "a", days: 0), revision(2, author: "a", days: 1000)]).unit, .quarter)
        XCTAssertEqual(LogStatistics(entries: [revision(1, author: "a", days: 0), revision(2, author: "a", days: 3000)]).unit, .year)
    }

    func testLineStatisticsSkipMerges() {
        var stats = CommitFileStats()
        stats.linesAdded = 5
        stats.linesInNewFiles = 7
        stats.filesChanged = 2
        let normal = revision(1, author: "a", days: 0)
        let merge = revision(2, author: "a", days: 1, parents: 2)
        let result = LogStatistics(entries: [normal, merge], fileStats: [normal.hash.string: stats, merge.hash.string: stats])
        XCTAssertEqual(result.linesAdded, 5)
        XCTAssertEqual(result.linesInNewFiles, 7)
        XCTAssertEqual(result.totalFileChanges, 2)
        XCTAssertEqual(result.buckets.first?.linesWithByAuthor["a"], 12)
        XCTAssertEqual(result.buckets.first?.linesWithoutByAuthor["a"], 5)
    }

    func testIndividualAuthorsGroupsOthers() {
        let revisions = (0..<5).map { revision($0, author: "author\($0)", days: Double($0)) }
        let stats = LogStatistics(entries: revisions)
        let split = stats.individualAuthors(limit: 2, sortByCommitCount: true)
        XCTAssertEqual(split.shown.count, 2)
        XCTAssertEqual(split.others.count, 3)
        // Leaving out exactly one author shows them too.
        XCTAssertEqual(stats.individualAuthors(limit: 4, sortByCommitCount: true).others, [])
    }
}

final class GitChangedFilesTests: XCTestCase {
    func testParsesRawAndNumstat() {
        let z = "\0"
        let raw = ":100644 100644 aaa bbb M\(z)src/a.swift\(z)"
            + ":000000 100644 000 ccc A\(z)new file.txt\(z)"
            + ":100644 100644 ddd eee R087\(z)old/name.txt\(z)new/name.txt\(z)"
            + ":160000 160000 fff ggg M\(z)vendor/lib\(z)"
        let numstat = "3\t1\tsrc/a.swift\(z)5\t0\tnew file.txt\(z)2\t2\t\(z)old/name.txt\(z)new/name.txt\(z)-\t-\tvendor/lib\(z)"
        let files = GitChangedFilesParser.parse(raw: raw, numstat: numstat)
        XCTAssertEqual(files.map(\.status), ["M", "A", "R", "M"])
        XCTAssertEqual(files[0].added, 3)
        XCTAssertEqual(files[0].removed, 1)
        XCTAssertEqual(files[1].path, "new file.txt")
        XCTAssertEqual(files[2].oldPath, "old/name.txt")
        XCTAssertEqual(files[2].path, "new/name.txt")
        XCTAssertEqual(files[2].added, 2)
        XCTAssertTrue(files[3].isSubmodule)
        XCTAssertTrue(files[3].isBinary)
    }
}

final class LogDisplayFormatTests: XCTestCase {
    func testAbbreviatedRename() {
        XCTAssertEqual(LogDisplayFormat.abbreviatedRename(from: "a/x/f.txt", to: "a/y/f.txt"), "a/{x => y}/f.txt")
        XCTAssertEqual(LogDisplayFormat.abbreviatedRename(from: "dir/a.txt", to: "dir/b.txt"), "dir/{a.txt => b.txt}")
        XCTAssertEqual(LogDisplayFormat.abbreviatedRename(from: "a.txt", to: "b.txt"), "a.txt => b.txt")
        XCTAssertEqual(LogDisplayFormat.abbreviatedRename(from: "src/f", to: "lib/f"), "{src => lib}/f")
    }

    func testNonLocaleDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2024, month: 5, day: 6, hour: 7, minute: 8))!
        XCTAssertEqual(LogDisplayFormat.date(date, short: true, relative: false, systemLocale: false), "2024-05-06 07:08")
        let relative = LogDisplayFormat.date(date, short: true, relative: true, systemLocale: false, now: date.addingTimeInterval(3 * 86_400))
        XCTAssertEqual(relative, "3 days ago")
    }
}

final class GitLogIntegrationTests: XCTestCase {
    private var directory: URL!
    private var root: PangolinPath!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: GitCLIRunner.resolveGitExecutable()) else {
            throw XCTSkip("git CLI is not installed")
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pangolin-log-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = PangolinPath(directory.path)
        for args in [["init", "-b", "main"], ["config", "user.name", "Log Test"], ["config", "user.email", "log@test.local"],
                     ["config", "commit.gpgsign", "false"]] {
            try GitCLIRunner.run(arguments: args, workingDirectory: root)
        }
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func commit(_ file: String, _ content: String, _ message: String) throws {
        try content.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try GitCLIRunner.run(arguments: ["add", "--", file], workingDirectory: root)
        try GitCLIRunner.run(arguments: ["commit", "-m", message], workingDirectory: root)
    }

    func testPathFilterNotesRefsAndChangedFiles() async throws {
        try commit("a.txt", "one\n", "Add a")
        try commit("b.txt", "two\n", "Add b")
        try commit("a.txt", "one\nmore\n", "Change a")
        try GitCLIRunner.run(arguments: ["tag", "-a", "v1", "-m", "release"], workingDirectory: root)
        try GitCLIRunner.run(arguments: ["notes", "add", "-m", "reviewed", "HEAD"], workingDirectory: root)

        let repo = try GitRepository(rootPath: root)
        var query = GitLogQuery()
        let all = try await repo.log(query: query)
        XCTAssertEqual(all.map(\.revision.subject), ["Change a", "Add b", "Add a"])
        query.path = "a.txt"
        let entries = try await repo.log(query: query)
        XCTAssertEqual(entries.map(\.revision.subject), ["Change a", "Add a"])
        // Parent rewriting keeps the path-limited graph connected.
        XCTAssertEqual(entries[0].revision.parentHashes, [entries[1].revision.hash])
        XCTAssertEqual(entries[0].notes, "reviewed")

        let refs = await GitRefMap.load(root: root)
        XCTAssertEqual(refs.currentBranch, "main")
        XCTAssertEqual(refs.labels(for: entries[0].revision.hash.string).map(\.kind), [.localBranch, .annotatedTag])

        let hash = entries[0].revision.hash.string
        // The rewritten parent skips "Add b"; the real parent is what the commit changed against.
        let parent = await repo.parent(of: hash)
        XCTAssertEqual(parent, all[1].revision.hash.string)
        let rootParent = await repo.parent(of: all[2].revision.hash.string)
        XCTAssertNil(rootParent)
        let raw = try await GitCLIRunner().runChecked(arguments: GitChangedFilesParser.rawArguments(parent: parent, revision: hash), workingDirectory: root)
        let numstat = try await GitCLIRunner().runChecked(arguments: GitChangedFilesParser.numstatArguments(parent: parent, revision: hash), workingDirectory: root)
        let files = GitChangedFilesParser.parse(raw: raw, numstat: numstat)
        XCTAssertEqual(files.map(\.path), ["a.txt"])
        XCTAssertEqual(files.first?.added, 1)
    }
}
