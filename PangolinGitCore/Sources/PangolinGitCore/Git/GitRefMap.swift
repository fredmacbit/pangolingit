import Foundation

/// A ref pointing at a commit, drawn as a label in the Log (TortoiseGit's ref labels in
/// `GitLogListBase::DrawTagBranchMessage`).
public struct GitRefLabel: Hashable, Sendable {
    public enum Kind: Int, Hashable, Sendable, Comparable {
        // Raw values give the drawing order: current branch first, as in TortoiseGit.
        case head = 0
        case localBranch
        case remoteBranch
        case annotatedTag
        case tag
        case stash
        case bisectBad
        case bisectGood
        case other

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Full name, e.g. `refs/heads/main`; `HEAD` for a detached HEAD.
    public let fullName: String
    public let kind: Kind
    /// The checked-out branch (drawn bold).
    public let isCurrent: Bool

    public init(fullName: String, kind: Kind, isCurrent: Bool = false) {
        self.fullName = fullName
        self.kind = kind
        self.isCurrent = isCurrent
    }

    /// Name without the `refs/<namespace>/` prefix.
    public var shortName: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        if fullName.hasPrefix("refs/bisect/") {
            return kind == .bisectBad ? "bisect bad" : "bisect good"
        }
        if fullName.hasPrefix("refs/") {
            return String(fullName.dropFirst("refs/".count))
        }
        return fullName
    }

    public var isBranch: Bool { kind == .localBranch || kind == .remoteBranch }
    public var isTag: Bool { kind == .tag || kind == .annotatedTag }
}

/// Every ref of the repository keyed by the commit it points to (TortoiseGit's `MAP_HASH_NAME`,
/// from `CGit::GetMapHashToFriendName`). Tags are peeled to their commit.
public struct GitRefMap: Sendable {
    public private(set) var labelsByHash: [String: [GitRefLabel]] = [:]
    /// Commit HEAD points at, and the branch it is on (nil when detached).
    public let headHash: String?
    public let currentBranch: String?
    /// Upstream (`refs/remotes/…`) of each local branch (`refs/heads/…`) that has one.
    public let upstreams: [String: String]

    public init(labelsByHash: [String: [GitRefLabel]] = [:], headHash: String? = nil, currentBranch: String? = nil,
                upstreams: [String: String] = [:]) {
        self.labelsByHash = labelsByHash
        self.headHash = headHash
        self.currentBranch = currentBranch
        self.upstreams = upstreams
    }

    public func labels(for hash: String) -> [GitRefLabel] {
        labelsByHash[hash] ?? []
    }

    /// All labels, for the ref chooser.
    public var allLabels: [GitRefLabel] {
        labelsByHash.values.flatMap { $0 }.sorted { ($0.kind, $0.fullName) < ($1.kind, $1.fullName) }
    }

    /// Remote names seen in remote-tracking refs.
    public var remoteNames: Set<String> {
        Set(labelsByHash.values.joined().filter { $0.kind == .remoteBranch }
            .compactMap { $0.shortName.split(separator: "/").first.map(String.init) })
    }

    /// Label text. With `symbolize` (TortoiseGit's "Symbolize refs"), a remote branch drops the
    /// remote name when there is only one remote (`/main`), and the upstream of a same-named local
    /// branch becomes `≡` (`/≡` or `origin/≡`).
    public func displayName(for label: GitRefLabel, symbolize: Bool) -> String {
        guard symbolize, label.kind == .remoteBranch else { return label.shortName }
        let name = label.shortName
        guard let slash = name.firstIndex(of: "/") else { return name }
        let remote = String(name[..<slash])
        let branch = String(name[name.index(after: slash)...])
        let singleRemote = remoteNames.count == 1
        let tracked = upstreams.contains { local, upstream in
            upstream == label.fullName && local == "refs/heads/\(branch)"
        }
        if tracked { return singleRemote ? "/≡" : "\(remote)/≡" }
        return singleRemote ? "/\(branch)" : name
    }

    /// The commit a ref (full or short name) points at.
    public func hash(forRef name: String) -> String? {
        for (hash, labels) in labelsByHash where labels.contains(where: { $0.fullName == name || $0.shortName == name }) {
            return hash
        }
        return nil
    }

    /// Parses `git for-each-ref --format='%(objectname) %(*objectname) %(objecttype) %(refname) %(upstream)'`.
    /// - Parameters:
    ///   - headRef: output of `git symbolic-ref -q HEAD` (empty when detached).
    ///   - headHash: output of `git rev-parse HEAD`.
    public static func parse(forEachRef output: String, headRef: String?, headHash: String?) -> GitRefMap {
        let currentRef = headRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var map: [String: [GitRefLabel]] = [:]
        var upstreams: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { continue }
            let object = parts[0], peeled = parts[1], type = parts[2], name = parts[3]
            if parts.count >= 5, !parts[4].isEmpty, name.hasPrefix("refs/heads/") { upstreams[name] = parts[4] }
            // Symbolic remote HEADs (origin/HEAD) only duplicate the branch they point to.
            if name.hasPrefix("refs/remotes/"), name.hasSuffix("/HEAD") { continue }
            // Notes refs point at notes commits, never at commits of the shown history.
            if name.hasPrefix("refs/notes/") { continue }
            let kind: GitRefLabel.Kind
            if name.hasPrefix("refs/heads/") { kind = .localBranch }
            else if name.hasPrefix("refs/remotes/") { kind = .remoteBranch }
            else if name.hasPrefix("refs/tags/") { kind = type == "tag" ? .annotatedTag : .tag }
            else if name == "refs/stash" { kind = .stash }
            else if name == "refs/bisect/bad" { kind = .bisectBad }
            else if name.hasPrefix("refs/bisect/good") { kind = .bisectGood }
            else { kind = .other }
            let commit = peeled.isEmpty ? object : peeled
            map[commit, default: []].append(GitRefLabel(fullName: name, kind: kind, isCurrent: name == currentRef))
        }
        let head = headHash?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !head.isEmpty, currentRef.isEmpty {
            map[head, default: []].append(GitRefLabel(fullName: "HEAD", kind: .head, isCurrent: true))
        }
        for key in map.keys {
            map[key]?.sort { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                return (lhs.kind, lhs.fullName) < (rhs.kind, rhs.fullName)
            }
        }
        let branch = currentRef.hasPrefix("refs/heads/") ? String(currentRef.dropFirst("refs/heads/".count)) : nil
        return GitRefMap(labelsByHash: map, headHash: head.isEmpty ? nil : head, currentBranch: branch, upstreams: upstreams)
    }

    /// Reads the refs of the repository at `root`.
    public static func load(root: PangolinPath) async -> GitRefMap {
        let runner = GitCLIRunner()
        let refs = (try? await runner.runChecked(
            arguments: ["for-each-ref", "--format=%(objectname) %(*objectname) %(objecttype) %(refname) %(upstream)"],
            workingDirectory: root)) ?? ""
        let headRef = try? await runner.run(arguments: ["symbolic-ref", "-q", "HEAD"], workingDirectory: root).standardOutput
        let headHash = try? await runner.run(arguments: ["rev-parse", "--verify", "-q", "HEAD"], workingDirectory: root).standardOutput
        return parse(forEachRef: refs, headRef: headRef, headHash: headHash)
    }
}
