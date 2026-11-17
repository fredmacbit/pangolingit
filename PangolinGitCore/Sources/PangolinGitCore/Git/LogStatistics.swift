import Foundation

/// Per-commit file statistics from `git log --numstat --summary`.
public struct CommitFileStats: Hashable, Sendable {
    /// Lines added / removed in files that existed before and after the commit.
    public var linesAdded = 0
    public var linesRemoved = 0
    /// Lines of files the commit created / deleted.
    public var linesInNewFiles = 0
    public var linesInDeletedFiles = 0
    public var filesChanged = 0

    public init() {}
}

public enum CommitStatsParser {
    /// The `git log` arguments (before the walk arguments) producing what `parse` reads.
    public static let arguments = ["log", "--format=%x1e%H", "--numstat", "--summary", "--no-renames"]

    /// Parses records `\x1e<hash>` followed by numstat lines (`added\tremoved\tpath`, `-` for
    /// binaries) and summary lines (` create mode 100644 path`, ` delete mode …`).
    public static func parse(_ output: String) -> [String: CommitFileStats] {
        var result: [String: CommitFileStats] = [:]
        for record in output.components(separatedBy: "\u{1e}") {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let hash = lines.first?.trimmingCharacters(in: .whitespaces), !hash.isEmpty else { continue }
            var numstat: [String: (Int, Int)] = [:]
            var created = Set<String>()
            var deleted = Set<String>()
            for line in lines.dropFirst() {
                if line.hasPrefix(" create mode ") || line.hasPrefix(" delete mode ") {
                    // " create mode 100644 path/to/file"
                    let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3).map(String.init)
                    guard parts.count == 4 else { continue }
                    if parts[0] == "create" { created.insert(parts[3]) } else { deleted.insert(parts[3]) }
                    continue
                }
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                numstat[parts[2]] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
            }
            var stats = CommitFileStats()
            stats.filesChanged = numstat.count
            // TortoiseGit's StatGraphDlg: new files count as "new lines", deleted files as
            // "deleted lines", everything else as increments / decrements.
            for (path, counts) in numstat {
                if deleted.contains(path) { stats.linesInDeletedFiles += counts.1 }
                else if created.contains(path) { stats.linesInNewFiles += counts.0 }
                else { stats.linesAdded += counts.0; stats.linesRemoved += counts.1 }
            }
            result[hash] = stats
        }
        return result
    }

    /// Parses `git log --format=%x1e%H --name-only` into the changed paths per commit
    /// (the Log's "Paths" search field).
    public static func parseNameOnly(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for record in output.components(separatedBy: "\u{1e}") {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let hash = lines.first, !hash.isEmpty else { continue }
            result[hash] = Array(lines.dropFirst())
        }
        return result
    }
}

/// The numbers behind TortoiseGit's Statistics dialog (`StatGraphDlg::GatherData`).
public struct LogStatistics: Sendable {

    public struct Options: Equatable, Sendable {
        public var authorsCaseSensitive = true
        public var useCommitterNames = false
        public var useCommitDates = false
        public init() {}
    }

    /// Size of one time bucket; chosen from the history's span as TortoiseGit does.
    public enum TimeUnit: String, Sendable {
        case day, week, month, quarter, year

        public var title: String { rawValue }
    }

    public struct Bucket: Sendable {
        public let label: String
        public var commitsByAuthor: [String: Int] = [:]
        public var fileChangesByAuthor: [String: Int] = [:]
        /// Changed lines including lines of new / deleted files.
        public var linesWithByAuthor: [String: Int] = [:]
        /// Changed lines in files that existed before and after.
        public var linesWithoutByAuthor: [String: Int] = [:]

        public var commits: Int { commitsByAuthor.values.reduce(0, +) }
    }

    public struct AuthorActivity: Sendable {
        public let name: String
        public let average: Double
        public let maximum: Int
        public let minimum: Int
    }

    public let totalCommits: Int
    public let totalFileChanges: Int
    /// Authors by descending commit count (ties alphabetical).
    public let authors: [String]
    public let commitsPerAuthor: [String: Int]
    /// Percent, summing to 100; recent commits weigh more (TortoiseGit's `CoeffContribution`).
    public let percentageOfAuthorship: [String: Double]
    public let unit: TimeUnit
    /// Oldest first.
    public let buckets: [Bucket]
    public let firstDate: Date?
    public let lastDate: Date?
    public let linesAdded: Int
    public let linesRemoved: Int
    public let linesInNewFiles: Int
    public let linesInDeletedFiles: Int
    public let hasLineStats: Bool

    /// - Parameters:
    ///   - entries: the commits shown in the Log (any order).
    ///   - fileStats: optional numstat results keyed by commit hash ("Calculate" line statistics).
    public init(entries: [GitRevision], fileStats: [String: CommitFileStats]? = nil, options: Options = Options(),
                calendar: Calendar = .current) {
        func person(_ r: GitRevision) -> GitAuthor { options.useCommitterNames ? r.committer : r.author }
        func date(_ r: GitRevision) -> Date { options.useCommitDates ? r.committer.date : r.author.date }
        // Newest first, like TortoiseGit's sorted show list.
        let sorted = entries.sorted { date($0) > date($1) }
        totalCommits = sorted.count
        firstDate = sorted.last.map(date)
        lastDate = sorted.first.map(date)
        hasLineStats = fileStats != nil

        let days = (firstDate != nil && lastDate != nil) ? lastDate!.timeIntervalSince(firstDate!) / 86_400 : 0
        let weeks = Int((days / 7).rounded(.up))
        let unit: TimeUnit
        if days < 8 { unit = .day }
        else if weeks < 15 { unit = .week }
        else if weeks < 80 { unit = .month }
        else if weeks < 320 { unit = .quarter }
        else { unit = .year }
        self.unit = unit

        var commitsPerAuthor: [String: Int] = [:]
        var contribution: [String: Double] = [:]
        var totalContribution = 0.0
        var bucketsByKey: [String: Bucket] = [:]
        var bucketOrder: [String] = []
        var totalFiles = 0, added = 0, removed = 0, new = 0, deleted = 0

        for (index, revision) in sorted.enumerated() {
            var name = person(revision).name
            if name.isEmpty { name = "(unknown)" }
            if !options.authorsCaseSensitive { name = name.lowercased() }
            commitsPerAuthor[name, default: 0] += 1

            let (key, label) = Self.bucket(for: date(revision), unit: unit, calendar: calendar)
            if bucketsByKey[key] == nil {
                bucketsByKey[key] = Bucket(label: label)
                bucketOrder.append(key)
            }
            // Merges carry no file statistics (TortoiseGit only diffs commits with at most one parent).
            let stats = revision.parentHashes.count <= 1 ? fileStats?[revision.hash.string] : nil
            let files = stats?.filesChanged ?? 0
            bucketsByKey[key]!.commitsByAuthor[name, default: 0] += 1
            bucketsByKey[key]!.fileChangesByAuthor[name, default: 0] += files
            if let stats {
                let without = stats.linesAdded + stats.linesRemoved
                bucketsByKey[key]!.linesWithoutByAuthor[name, default: 0] += without
                bucketsByKey[key]!.linesWithByAuthor[name, default: 0] += without + stats.linesInNewFiles + stats.linesInDeletedFiles
                added += stats.linesAdded
                removed += stats.linesRemoved
                new += stats.linesInNewFiles
                deleted += stats.linesInDeletedFiles
            }
            totalFiles += files

            let distanceFromEnd = sorted.count - index - 1
            let coefficient = distanceFromEnd == 0 ? 1.0 : 1.0 / 2.0 * Double(distanceFromEnd)
            let weight = coefficient * Double(files == 0 ? 1 : files)
            contribution[name, default: 0] += weight
            totalContribution += weight
        }

        self.commitsPerAuthor = commitsPerAuthor
        authors = commitsPerAuthor.keys.sorted { lhs, rhs in
            let l = commitsPerAuthor[lhs]!, r = commitsPerAuthor[rhs]!
            return l != r ? l > r : lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        percentageOfAuthorship = totalContribution > 0 ? contribution.mapValues { $0 * 100 / totalContribution } : [:]
        buckets = bucketOrder.reversed().map { bucketsByKey[$0]! }
        totalFileChanges = totalFiles
        linesAdded = added
        linesRemoved = removed
        linesInNewFiles = new
        linesInDeletedFiles = deleted
    }

    /// Sort key and label of the bucket holding `date`.
    static func bucket(for date: Date, unit: TimeUnit, calendar: Calendar) -> (String, String) {
        let c = calendar.dateComponents([.year, .month, .day, .yearForWeekOfYear, .weekOfYear], from: date)
        let year = c.year ?? 0, month = c.month ?? 0, day = c.day ?? 0
        switch unit {
        case .day:
            let key = String(format: "%04d-%02d-%02d", year, month, day)
            return (key, key)
        case .week:
            let key = String(format: "%04d-W%02d", c.yearForWeekOfYear ?? year, c.weekOfYear ?? 0)
            return (key, key)
        case .month:
            let key = String(format: "%04d-%02d", year, month)
            return (key, key)
        case .quarter:
            let key = String(format: "%04d-Q%d", year, (month - 1) / 3 + 1)
            return (key, key)
        case .year:
            let key = String(format: "%04d", year)
            return (key, key)
        }
    }

    /// Commits per time unit: average / maximum / minimum over the buckets that have commits.
    public var commitsPerUnit: (average: Double, maximum: Int, minimum: Int) {
        let counts = buckets.map(\.commits)
        guard !counts.isEmpty else { return (0, 0, 0) }
        return (Double(counts.reduce(0, +)) / Double(counts.count), counts.max()!, counts.min()!)
    }

    /// The most and least active author by commits per time unit (TortoiseGit's summary page).
    public var mostAndLeastActive: (most: AuthorActivity, least: AuthorActivity)? {
        guard !authors.isEmpty, !buckets.isEmpty else { return nil }
        func activity(_ name: String) -> AuthorActivity {
            let counts = buckets.map { $0.commitsByAuthor[name] ?? 0 }
            return AuthorActivity(name: name, average: Double(counts.reduce(0, +)) / Double(counts.count),
                                  maximum: counts.max() ?? 0, minimum: counts.min() ?? 0)
        }
        return (activity(authors.first!), activity(authors.last!))
    }

    /// Splits authors into those shown individually and the rest grouped as "Others"
    /// (TortoiseGit's "# authors shown individually" slider). Leaving out a single author is
    /// pointless, so they are then shown too.
    public func individualAuthors(limit: Int, sortByCommitCount: Bool) -> (shown: [String], others: [String]) {
        var count = min(max(limit, 0), authors.count)
        if count + 1 == authors.count { count += 1 }
        var shown = Array(authors.prefix(count))
        let others = Array(authors.dropFirst(count))
        if !sortByCommitCount { shown.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
        return (shown, others)
    }
}
