import Foundation

/// A ref shown on a revision-graph node, classified the way TortoiseGit colours them
/// (`RevisionGraphDlg` / `RevisionGraphWnd.cpp`: local branch, remote branch, tag, HEAD, stash, notes).
public struct RevisionGraphRef: Hashable, Sendable {
    public enum Kind: Int, Sendable, Comparable {
        case head, localBranch, remoteBranch, tag, stash, notes, other

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Full ref name (`refs/heads/main`), or `HEAD` for a detached HEAD.
    public let fullName: String
    public let kind: Kind
    /// True for the branch HEAD points at (`HEAD -> refs/heads/main`).
    public let isCurrent: Bool

    public init(fullName: String, kind: Kind, isCurrent: Bool = false) {
        self.fullName = fullName
        self.kind = kind
        self.isCurrent = isCurrent
    }

    /// Name as the user knows it: `main`, `origin/main`, `v1.0`, `stash`.
    public var shortName: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/", "refs/notes/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        return fullName.hasPrefix("refs/") ? String(fullName.dropFirst(5)) : fullName
    }
}

/// One commit as read from `git log` for the revision graph.
public struct RevisionGraphCommit: Hashable, Sendable {
    public let hash: String
    public var parents: [String]
    public let refs: [RevisionGraphRef]
    public let subject: String
    public let author: String
    public let timestamp: TimeInterval

    public init(hash: String, parents: [String], refs: [RevisionGraphRef] = [], subject: String = "",
                author: String = "", timestamp: TimeInterval = 0) {
        self.hash = hash
        self.parents = parents
        self.refs = refs
        self.subject = subject
        self.author = author
        self.timestamp = timestamp
    }
}

/// A placed node: `row` grows downwards (newest first), `lane` grows to the right.
public struct RevisionGraphNode: Hashable, Sendable {
    public let commit: RevisionGraphCommit
    public let row: Int
    public let lane: Int
}

/// Builds TortoiseGit's Revision Graph: only commits that carry refs (plus, optionally, the
/// branch and merge points between them), each connected to its nearest shown ancestor.
/// TortoiseGit gets the same set from `git log --simplify-by-decoration` and lays it out with OGDF;
/// here the lane engine of the Log (`CommitGraphLaneEngine`, a port of `lanes.cpp`) places the nodes.
public enum RevisionGraphBuilder {

    /// `git log` arguments that produce input for `parseLog` (fields separated by 0x1F, records by 0x1E).
    public static func logArguments(scope: Scope) -> [String] {
        var args = ["log", "--topo-order", "--decorate=full", "--format=%H%x1f%P%x1f%D%x1f%s%x1f%an%x1f%at%x1e"]
        switch scope {
        case .all: args.append("--all")
        case .localBranches: args += ["--branches", "--tags", "HEAD"]
        case .currentBranch: args.append("HEAD")
        }
        return args
    }

    /// Which history the graph covers (TortoiseGit: *Show all branches* / *Local branches only* / current branch).
    public enum Scope: Int, Sendable {
        case all, localBranches, currentBranch
    }

    public static func parseLog(_ output: String) -> [RevisionGraphCommit] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard fields.count >= 6, !fields[0].isEmpty else { return nil }
            return RevisionGraphCommit(
                hash: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                refs: parseDecorations(fields[2]),
                subject: fields[3],
                author: fields[4],
                timestamp: TimeInterval(fields[5]) ?? 0
            )
        }
    }

    /// Parses a `%D` value produced with `--decorate=full`:
    /// `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0, refs/stash`.
    public static func parseDecorations(_ value: String) -> [RevisionGraphRef] {
        var refs: [RevisionGraphRef] = []
        for raw in value.components(separatedBy: ", ") {
            let item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if item.hasPrefix("HEAD -> ") {
                let name = String(item.dropFirst("HEAD -> ".count))
                refs.append(RevisionGraphRef(fullName: name, kind: kind(of: name), isCurrent: true))
            } else if item == "HEAD" {
                refs.append(RevisionGraphRef(fullName: "HEAD", kind: .head, isCurrent: true))
            } else if item.hasPrefix("tag: ") {
                refs.append(RevisionGraphRef(fullName: String(item.dropFirst("tag: ".count)), kind: .tag))
            } else if item.hasSuffix("/HEAD") && item.hasPrefix("refs/remotes/") {
                continue // origin/HEAD is only an alias of the remote's default branch
            } else {
                refs.append(RevisionGraphRef(fullName: item, kind: kind(of: item)))
            }
        }
        return refs.sorted { ($0.kind, $0.fullName) < ($1.kind, $1.fullName) }
    }

    private static func kind(of name: String) -> RevisionGraphRef.Kind {
        if name.hasPrefix("refs/heads/") { return .localBranch }
        if name.hasPrefix("refs/remotes/") { return .remoteBranch }
        if name.hasPrefix("refs/tags/") { return .tag }
        if name == "refs/stash" { return .stash }
        if name.hasPrefix("refs/notes/") { return .notes }
        return .other
    }

    /// Keeps commits that carry refs, the root commits and, when `branchPoints` is set, commits with
    /// several parents or several children (TortoiseGit's *Show branchings and merges*). Parents are
    /// rewritten to the nearest kept ancestors. Input and output are newest first (topological order).
    public static func simplify(_ commits: [RevisionGraphCommit], branchPoints: Bool,
                                includeTags: Bool = true) -> [RevisionGraphCommit] {
        let index = Dictionary(commits.enumerated().map { ($1.hash, $0) }, uniquingKeysWith: { first, _ in first })
        var childCount: [String: Int] = [:]
        for commit in commits {
            for parent in commit.parents { childCount[parent, default: 0] += 1 }
        }

        func isKept(_ commit: RevisionGraphCommit) -> Bool {
            let refs = includeTags ? commit.refs : commit.refs.filter { $0.kind != .tag }
            if !refs.isEmpty { return true }
            if commit.parents.isEmpty { return true }
            if branchPoints && (commit.parents.count > 1 || childCount[commit.hash, default: 0] > 1) { return true }
            return false
        }
        let kept = commits.map(isKept)

        // Nearest kept ancestors of each commit, computed oldest first so parents are already known.
        var nearest: [Int: [String]] = [:]
        for position in commits.indices.reversed() {
            var result: [String] = []
            for parent in commits[position].parents {
                guard let parentIndex = index[parent] else { continue }
                let candidates = kept[parentIndex] ? [parent] : (nearest[parentIndex] ?? [])
                for candidate in candidates where !result.contains(candidate) {
                    result.append(candidate)
                }
            }
            nearest[position] = result
        }

        var result: [RevisionGraphCommit] = []
        for position in commits.indices where kept[position] {
            var commit = commits[position]
            commit.parents = removeTransitiveParents(nearest[position] ?? [], nearest: nearest, index: index)
            result.append(commit)
        }
        return result
    }

    /// Drops a second or later parent P when another parent already leads to P, so a merge does not
    /// get an extra edge straight to the fork point. The first parent (the mainline) always stays.
    private static func removeTransitiveParents(_ parents: [String], nearest: [Int: [String]], index: [String: Int]) -> [String] {
        guard parents.count > 1 else { return parents }
        func reaches(_ from: String, _ target: String) -> Bool {
            var stack = [from]
            var seen = Set<String>()
            while let hash = stack.popLast() {
                guard seen.insert(hash).inserted, let position = index[hash] else { continue }
                for next in nearest[position] ?? [] {
                    if next == target { return true }
                    stack.append(next)
                }
            }
            return false
        }
        return parents.enumerated().filter { position, candidate in
            position == 0 || !parents.contains { other in other != candidate && reaches(other, candidate) }
        }.map(\.element)
    }

    /// Places nodes on rows (one per commit, newest on top) and lanes (from the Log's lane engine).
    public static func layout(_ commits: [RevisionGraphCommit]) -> [RevisionGraphNode] {
        let revisions = commits.map { commit in
            GitRevision(
                hash: GitHash(uncheckedHex: commit.hash),
                parentHashes: commit.parents.map { GitHash(uncheckedHex: $0) },
                author: GitAuthor(name: commit.author, email: "", date: Date(timeIntervalSince1970: commit.timestamp)),
                committer: GitAuthor(name: commit.author, email: "", date: Date(timeIntervalSince1970: commit.timestamp)),
                subject: commit.subject
            )
        }
        let lanes = CommitGraphLaneEngine().computeLanes(revisions: revisions)
        return zip(commits, lanes).enumerated().map { row, pair in
            RevisionGraphNode(commit: pair.0, row: row, lane: pair.1.nodeLane)
        }
    }
}
