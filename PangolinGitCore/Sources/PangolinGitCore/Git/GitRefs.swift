import Foundation

/// One reference as listed by `git for-each-ref` with the columns TortoiseGit's Browse References
/// dialog shows (`BrowseRefsDlg.cpp`: tracked branch, last author / committer and their dates, subject).
public struct GitRefInfo: Sendable, Equatable {
    /// Full name, e.g. `refs/heads/feature/x`.
    public let fullName: String
    /// Object the ref points at (the tag object for annotated tags).
    public let objectHash: String
    /// The commit behind the ref (peeled for annotated tags).
    public let commitHash: String
    /// `%(upstream:short)` for local branches, empty otherwise.
    public let upstream: String
    /// `%(upstream:track)`, e.g. `[ahead 2, behind 1]`.
    public let tracking: String
    public let authorName: String
    public let authorDate: Date?
    public let committerName: String
    public let committerDate: Date?
    public let subject: String
    /// The ref is the checked-out branch (`%(HEAD)` is `*`).
    public let isHead: Bool
    /// Annotated tag (has its own tag object).
    public let isAnnotatedTag: Bool

    public init(fullName: String, objectHash: String, commitHash: String, upstream: String = "", tracking: String = "",
                authorName: String = "", authorDate: Date? = nil, committerName: String = "", committerDate: Date? = nil,
                subject: String = "", isHead: Bool = false, isAnnotatedTag: Bool = false) {
        self.fullName = fullName
        self.objectHash = objectHash
        self.commitHash = commitHash
        self.upstream = upstream
        self.tracking = tracking
        self.authorName = authorName
        self.authorDate = authorDate
        self.committerName = committerName
        self.committerDate = committerDate
        self.subject = subject
        self.isHead = isHead
        self.isAnnotatedTag = isAnnotatedTag
    }

    public enum Kind: Sendable {
        case localBranch, remoteBranch, tag, stash, notes, other
    }

    public var kind: Kind {
        if fullName.hasPrefix("refs/heads/") { return .localBranch }
        if fullName.hasPrefix("refs/remotes/") { return .remoteBranch }
        if fullName.hasPrefix("refs/tags/") { return .tag }
        if fullName == "refs/stash" { return .stash }
        if fullName.hasPrefix("refs/notes/") { return .notes }
        return .other
    }

    /// The name git accepts on the command line (`feature/x`, `origin/main`, `v1.0`, `stash`).
    public var shortName: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        if fullName.hasPrefix("refs/") { return String(fullName.dropFirst(5)) }
        return fullName
    }

    /// Last path component, as shown in the list under its namespace node.
    public var leafName: String {
        fullName.split(separator: "/").last.map(String.init) ?? fullName
    }
}

/// Parsing helpers for reference listings.
public enum GitRefs {
    private static let fieldSeparator: Character = "\u{1f}"

    /// `for-each-ref` format matching `parseForEachRef`; fields are separated by U+001F so subjects
    /// containing tabs or pipes survive.
    public static let forEachRefFormat = [
        "%(refname)", "%(objectname)", "%(*objectname)", "%(upstream:short)", "%(upstream:track)",
        "%(authorname)", "%(authordate:unix)", "%(committername)", "%(committerdate:unix)",
        "%(creatordate:unix)", "%(contents:subject)", "%(HEAD)", "%(objecttype)"
    ].joined(separator: "%1f")

    public static func parseForEachRef(_ output: String) -> [GitRefInfo] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 13, !fields[0].isEmpty else { return nil }
            func date(_ value: String) -> Date? {
                TimeInterval(value).map { Date(timeIntervalSince1970: $0) }
            }
            let peeled = fields[2]
            let isTagObject = fields[12] == "tag"
            // Tags carry no author: fall back to the creator (tagger) date so date columns stay filled.
            let creatorDate = date(fields[9])
            return GitRefInfo(
                fullName: fields[0],
                objectHash: fields[1],
                commitHash: peeled.isEmpty ? fields[1] : peeled,
                upstream: fields[3],
                tracking: fields[4],
                authorName: fields[5],
                authorDate: date(fields[6]) ?? creatorDate,
                committerName: fields[7],
                committerDate: date(fields[8]) ?? creatorDate,
                subject: fields[10],
                isHead: fields[11] == "*",
                isAnnotatedTag: isTagObject
            )
        }
    }

    /// Parses `git config -z --get-regexp '^branch\..*\.description$'` into branch → description.
    /// Run with `-z` (entries `key\nvalue\0`) so multi-line descriptions stay intact.
    public static func parseBranchDescriptions(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for entry in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            guard key.hasPrefix("branch."), key.hasSuffix(".description") else { continue }
            let branch = String(key.dropFirst("branch.".count).dropLast(".description".count))
            result[branch] = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .newlines) : ""
        }
        return result
    }

    /// The remote a remote-tracking branch belongs to: the longest configured remote name that prefixes it
    /// (remote names may contain slashes).
    public static func remote(ofRemoteBranch shortName: String, remotes: [String]) -> String? {
        remotes.filter { shortName.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }
}

/// A namespace node of the reference tree (`refs` ▸ `heads` ▸ `feature` …), TortoiseGit's left pane.
public final class GitRefTreeNode: @unchecked Sendable {
    public let name: String
    /// Full path of the namespace, e.g. `refs/heads/feature`.
    public let path: String
    public private(set) var children: [GitRefTreeNode] = []
    /// Refs that live directly in this namespace.
    public private(set) var refs: [GitRefInfo] = []

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    /// This node's refs plus, when `nested`, those of every namespace below it (*Show nested refs*).
    public func allRefs(nested: Bool) -> [GitRefInfo] {
        guard nested else { return refs }
        return refs + children.flatMap { $0.allRefs(nested: true) }
    }

    public func child(named name: String) -> GitRefTreeNode? {
        children.first { $0.name == name }
    }

    /// Finds the node at `path` (e.g. `refs/remotes/origin`).
    public func node(atPath path: String) -> GitRefTreeNode? {
        if self.path == path { return self }
        for child in children where path == child.path || path.hasPrefix(child.path + "/") {
            return child.node(atPath: path)
        }
        return nil
    }

    fileprivate func insert(_ ref: GitRefInfo, components: ArraySlice<Substring>) {
        guard components.count > 1, let first = components.first else {
            refs.append(ref)
            return
        }
        let name = String(first)
        let node: GitRefTreeNode
        if let existing = child(named: name) {
            node = existing
        } else {
            node = GitRefTreeNode(name: name, path: path + "/" + name)
            children.append(node)
        }
        node.insert(ref, components: components.dropFirst())
    }

    fileprivate func sortRecursively() {
        children.sort { lhs, rhs in
            // Keep git's own namespaces in TortoiseGit's order; everything else alphabetically.
            let order = ["heads", "remotes", "tags"]
            let l = order.firstIndex(of: lhs.name) ?? order.count
            let r = order.firstIndex(of: rhs.name) ?? order.count
            return l != r ? l < r : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        refs.sort { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
        children.forEach { $0.sortRecursively() }
    }

    /// Builds the tree from full ref names: `refs/heads/feature/x` lands in `refs ▸ heads ▸ feature`.
    /// Remote HEAD pointers (`refs/remotes/origin/HEAD`) are left out, as in TortoiseGit.
    public static func build(from refs: [GitRefInfo]) -> GitRefTreeNode {
        let root = GitRefTreeNode(name: "refs", path: "refs")
        for ref in refs where ref.fullName.hasPrefix("refs/") {
            if ref.kind == .remoteBranch && ref.fullName.hasSuffix("/HEAD") { continue }
            let components = ref.fullName.split(separator: "/").dropFirst()
            root.insert(ref, components: components)
        }
        // The three main namespaces always exist so the tree has a stable shape.
        for name in ["heads", "remotes", "tags"] where root.child(named: name) == nil {
            root.children.append(GitRefTreeNode(name: name, path: "refs/\(name)"))
        }
        root.sortRecursively()
        return root
    }
}

/// Branch / tag name rules of `git check-ref-format` (TortoiseGit validates names before running git).
public enum GitRefName {
    /// Why `name` is not a valid branch or tag name, or nil if it is.
    public static func validationError(_ name: String) -> String? {
        if name.isEmpty { return "The name is empty." }
        if name == "@" { return "“@” is not a valid name." }
        if name.hasPrefix("-") { return "The name must not start with “-”." }
        if name.hasPrefix("/") || name.hasSuffix("/") { return "The name must not start or end with “/”." }
        if name.hasSuffix(".") { return "The name must not end with “.”." }
        if name.contains("..") { return "The name must not contain “..”." }
        if name.contains("//") { return "The name must not contain “//”." }
        if name.contains("@{") { return "The name must not contain “@{”." }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f {
                return "The name must not contain control characters."
            }
            if " ~^:?*[\\".unicodeScalars.contains(scalar) {
                return "The name must not contain spaces or any of ~ ^ : ? * [ \\."
            }
        }
        for component in name.split(separator: "/") {
            if component.hasPrefix(".") { return "No part of the name may start with “.”." }
            if component.hasSuffix(".lock") { return "No part of the name may end with “.lock”." }
        }
        return nil
    }

    public static func isValid(_ name: String) -> Bool {
        validationError(name) == nil
    }
}
