import Foundation

/// What the Log window asks git for: which refs to walk, which path, which dates and how the
/// history is simplified. Mirrors the inputs of TortoiseGit's `CGit::GetLogCmd` (`src/Git/Git.cpp`)
/// and the filter state of `CLogDlg` (`CFilterData`).
public struct GitLogQuery: Equatable, Sendable {

    /// The revisions the walk starts from (TortoiseGit's branch button + "All Branches" checkbox).
    public enum Scope: Equatable, Sendable {
        /// HEAD only.
        case current
        /// `--all`: every ref, including stash and notes.
        case allRefs
        /// Branches, remote branches, tags, stash and bisect refs (TortoiseGit's "basic refs").
        case basicRefs
        /// `--branches`: local branches only.
        case localBranches
        /// Explicit refs or ranges as typed: `main`, `A..B`, `A...B`, `A B`.
        case refs([String])
    }

    /// TortoiseGit's "Show only the last N commits / years / months / weeks" limitation.
    public enum Limit: Equatable, Sendable {
        case unlimited
        case commits(Int)
        case years(Int)
        case months(Int)
        case weeks(Int)

        /// Stable identifiers for settings storage.
        public var kind: String {
            switch self {
            case .unlimited: return "all"
            case .commits: return "commits"
            case .years: return "years"
            case .months: return "months"
            case .weeks: return "weeks"
            }
        }

        public var count: Int {
            switch self {
            case .unlimited: return 0
            case .commits(let n), .years(let n), .months(let n), .weeks(let n): return n
            }
        }

        public init(kind: String, count: Int) {
            let n = max(count, 1)
            switch kind {
            case "commits": self = .commits(n)
            case "years": self = .years(n)
            case "months": self = .months(n)
            case "weeks": self = .weeks(n)
            default: self = .unlimited
            }
        }
    }

    public var scope: Scope = .current
    /// Repository-relative path the history is limited to (Show Log on a file or folder).
    public var path: String?
    /// `--follow` (only meaningful for a single file).
    public var followRenames = false
    public var since: Date?
    public var until: Date?
    public var limit: Limit = .unlimited
    public var firstParent = false
    public var noMerges = false
    public var fullHistory = false
    /// "Show labelled commits only" / compressed graph.
    public var simplifyByDecoration = false
    /// Read author names and emails through `.mailmap` (TortoiseGit's UseMailmap, on by default).
    public var useMailmap = true

    public init() {}

    /// Field separator inside a record (\x1f) and record separator (\x1e). NUL cannot be passed in argv.
    static func format(useMailmap: Bool) -> String {
        let author = useMailmap ? "%aN%x1f%aE" : "%an%x1f%ae"
        let committer = useMailmap ? "%cN%x1f%cE" : "%cn%x1f%ce"
        // Notes before the body so a body can never be mistaken for notes.
        return "--format=%x1e%H%x1f%P%x1f\(author)%x1f%aI%x1f\(committer)%x1f%cI%x1f%D%x1f%s%x1f%N%x1f%b"
    }

    /// The `git log` command line for this query.
    /// - Parameter now: reference time for "last N years/months/weeks".
    public func arguments(now: Date = Date()) -> [String] {
        var args = ["log", "--date-order", Self.format(useMailmap: useMailmap)]
        args.append(contentsOf: walkArguments(now: now))
        return args
    }

    /// Everything after `git log` except the format: walk flags, limits, revisions and pathspec.
    /// Shared with the statistics and path-search helpers so they see the same commits.
    public func walkArguments(now: Date = Date()) -> [String] {
        var args: [String] = []
        if firstParent { args.append("--first-parent") }
        if noMerges { args.append("--no-merges") }
        // --parents turns on parent rewriting so a path-limited graph still connects (TortoiseGit #3728).
        args.append(fullHistory ? "--full-history" : "--parents")
        if simplifyByDecoration { args.append("--simplify-by-decoration") }
        if followRenames, path?.isEmpty == false { args.append("--follow") }

        var after = since
        switch limit {
        case .unlimited: break
        case .commits(let n): args.append("--max-count=\(n)")
        case .years(let n): after = Self.later(after, Self.startOfDay(now, minusDays: 365 * n))
        case .months(let n): after = Self.later(after, Self.startOfDay(now, minusDays: 30 * n))
        case .weeks(let n): after = Self.later(after, Self.startOfDay(now, minusDays: 7 * n))
        }
        if let after { args.append("--since=\(Int(after.timeIntervalSince1970))") }
        if let until { args.append("--until=\(Int(until.timeIntervalSince1970))") }

        switch scope {
        case .current:
            args.append("HEAD")
        case .allRefs:
            args.append("--all")
        case .basicRefs:
            args.append(contentsOf: ["--branches", "--tags", "--remotes", "--glob=stas[h]", "--glob=bisect"])
        case .localBranches:
            args.append("--branches")
        case .refs(let refs):
            let split = refs.flatMap { $0.split(separator: " ").map(String.init) }.filter { !$0.isEmpty }
            args.append(contentsOf: split.isEmpty ? ["HEAD"] : split)
        }
        args.append("--")
        if let path, !path.isEmpty { args.append(path) }
        return args
    }

    private static func later(_ a: Date?, _ b: Date) -> Date {
        guard let a else { return b }
        return max(a, b)
    }

    private static func startOfDay(_ date: Date, minusDays days: Int) -> Date {
        let start = Calendar.current.startOfDay(for: date)
        return start.addingTimeInterval(-Double(days) * 86_400)
    }

    /// Short human description of the scope, shown on the Log's ref button.
    public var scopeTitle: String {
        switch scope {
        case .current: return "HEAD"
        case .allRefs: return "All refs"
        case .basicRefs: return "All branches"
        case .localBranches: return "Local branches"
        case .refs(let refs): return refs.joined(separator: " ")
        }
    }
}

/// One commit of the log with the extras the Log window shows beyond `GitRevision`.
public struct GitLogEntry: Hashable, Sendable {
    public let revision: GitRevision
    /// `git notes` text (empty when the commit has none).
    public let notes: String

    public init(revision: GitRevision, notes: String = "") {
        self.revision = revision
        self.notes = notes
    }
}

public enum GitLogParser {
    /// Parses output produced with `GitLogQuery.format`. `--parents` adds the parents to `%H`'s
    /// line in some git versions only with `--format=oneline`; with a custom format `%P` already
    /// holds the (rewritten) parents.
    public static func parse(_ output: String) -> [GitLogEntry] {
        var entries: [GitLogEntry] = []
        let isoFormatter = ISO8601DateFormatter()
        for record in output.components(separatedBy: "\u{1e}") {
            let fields = record.components(separatedBy: "\u{1f}")
            guard fields.count >= 12, let hash = GitHash(hex: fields[0]) else { continue }
            let parents = fields[1].split(separator: " ").compactMap { GitHash(hex: String($0)) }
            let refs = fields[8].components(separatedBy: ", ")
                .map { $0.replacingOccurrences(of: "HEAD -> ", with: "") }
                .filter { !$0.isEmpty }
            let body = fields[11...].joined(separator: "\u{1f}").trimmingCharacters(in: .whitespacesAndNewlines)
            let revision = GitRevision(
                hash: hash,
                parentHashes: parents,
                author: GitAuthor(name: fields[2], email: fields[3], date: isoFormatter.date(from: fields[4]) ?? Date()),
                committer: GitAuthor(name: fields[5], email: fields[6], date: isoFormatter.date(from: fields[7]) ?? Date()),
                subject: fields[9],
                body: body,
                refs: refs
            )
            entries.append(GitLogEntry(revision: revision, notes: fields[10].trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return entries
    }
}

public extension GitRepository {
    /// Runs the Log window's query.
    func log(query: GitLogQuery) async throws -> [GitLogEntry] {
        let output = try await GitCLIRunner().runChecked(arguments: query.arguments(), workingDirectory: workingDirectory)
        return GitLogParser.parse(output)
    }

    /// The real (not path-rewritten) parent `index` (0-based) of a commit; nil for a root commit.
    /// A path-limited log rewrites `%P` to the previous commit touching the path, which must not
    /// be used to list what a commit changed.
    func parent(of revision: String, index: Int = 0) async -> String? {
        let result = try? await GitCLIRunner().run(arguments: ["rev-parse", "--verify", "-q", "\(revision)^\(index + 1)"],
                                                  workingDirectory: workingDirectory)
        guard let result, result.isSuccess else { return nil }
        let hash = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }
}
