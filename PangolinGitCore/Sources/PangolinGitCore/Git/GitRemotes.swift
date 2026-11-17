import Foundation

/// One `[remote "<name>"]` section as the Remote settings page of TortoiseGit edits it
/// (`src/TortoiseProc/Settings/SettingGitRemote.cpp`).
public struct GitRemoteConfig: Equatable, Sendable {

    /// `remote.<name>.tagopt`: which tags a plain fetch downloads.
    public enum TagOption: String, CaseIterable, Sendable {
        /// Unset: tags pointing into fetched history ("Reachable" in TortoiseGit).
        case reachable = ""
        case none = "--no-tags"
        case all = "--tags"

        public var title: String {
            switch self {
            case .reachable: return "Reachable"
            case .none: return "None"
            case .all: return "All"
            }
        }
    }

    public var name: String
    public var url: String
    /// `remote.<name>.pushurl`; empty means pushes go to `url`.
    public var pushURL: String
    public var tagOption: TagOption
    /// `remote.<name>.prune`; nil inherits `fetch.prune`.
    public var prune: Bool?
    /// Private key used for this remote (`remote.<name>.sshkey`, TortoiseGit's `puttykeyfile`).
    public var sshKey: String

    public init(name: String, url: String = "", pushURL: String = "", tagOption: TagOption = .reachable,
                prune: Bool? = nil, sshKey: String = "") {
        self.name = name
        self.url = url
        self.pushURL = pushURL
        self.tagOption = tagOption
        self.prune = prune
        self.sshKey = sshKey
    }
}

/// How a ref moved between two snapshots (TortoiseGit's `CGitRefCompareList` change types).
public enum GitRefChangeKind: Equatable, Sendable {
    case same
    case new
    case deleted
    /// The new commit contains the old one; `n` commits were added.
    case fastForward(Int)
    /// The new commit is an ancestor of the old one; `n` commits were dropped.
    case rewind(Int)
    /// History was rewritten: commits were both added and dropped.
    case diverged(ahead: Int, behind: Int)
    /// Changed, but the commits are not available to count (e.g. a pruned object).
    case changed

    public var title: String {
        switch self {
        case .same: return "Same"
        case .new: return "New"
        case .deleted: return "Deleted"
        case .fastForward(let n): return "Fast-forward (\(n))"
        case .rewind(let n): return "Rewind (\(n))"
        case .diverged(let ahead, let behind): return "Rewritten (+\(ahead) / −\(behind))"
        case .changed: return "Changed"
        }
    }
}

public struct GitRefChange: Equatable, Sendable {
    public let ref: String
    public let oldHash: String?
    public let newHash: String?
    public var kind: GitRefChangeKind

    /// `refs/remotes/origin/main` → `origin/main`.
    public var shortName: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    /// "Branch", "Remote branch", "Tag" or "Ref" for the type column.
    public var typeTitle: String {
        if ref.hasPrefix("refs/heads/") { return "Branch" }
        if ref.hasPrefix("refs/remotes/") { return "Remote branch" }
        if ref.hasPrefix("refs/tags/") { return "Tag" }
        return "Ref"
    }
}

/// A tag compared between the local repository and a remote (Sync ▸ Compare tags).
public struct GitTagComparison: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case same, localOnly, remoteOnly, differs

        public var title: String {
            switch self {
            case .same: return "Same"
            case .localOnly: return "Only local"
            case .remoteOnly: return "Only remote"
            case .differs: return "Different"
            }
        }
    }

    public let name: String
    public let localHash: String?
    public let remoteHash: String?

    public var state: State {
        switch (localHash, remoteHash) {
        case let (local?, remote?): return local == remote ? .same : .differs
        case (_?, nil): return .localOnly
        case (nil, _?): return .remoteOnly
        case (nil, nil): return .same
        }
    }
}

/// Remote, upstream, ref-snapshot and tag helpers shared by Pull/Fetch, Push, Sync, Clone and the
/// Remotes editor. Parsing is kept in pure functions so it can be unit-tested.
public enum GitRemotes {

    /// The config variable holding a remote's private key (`remote.<name>.sshkey`).
    public static let sshKeyVariable = "sshkey"

    // MARK: - Remote configuration

    /// Parses `git config --get-regexp ^remote\.` (one `key value` per line) into remotes in the
    /// order they first appear. Remote names may contain dots, so the variable is the last component.
    public static func parseRemoteConfig(_ output: String) -> [GitRemoteConfig] {
        var order: [String] = []
        var remotes: [String: GitRemoteConfig] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            guard key.lowercased().hasPrefix("remote."), let lastDot = key.lastIndex(of: ".") else { continue }
            let nameStart = key.index(key.startIndex, offsetBy: "remote.".count)
            guard nameStart < lastDot else { continue }
            let name = String(key[nameStart..<lastDot])
            let variable = key[key.index(after: lastDot)...].lowercased()
            if remotes[name] == nil {
                order.append(name)
                remotes[name] = GitRemoteConfig(name: name)
            }
            switch variable {
            case "url": remotes[name]?.url = value
            case "pushurl": remotes[name]?.pushURL = value
            case "tagopt": remotes[name]?.tagOption = GitRemoteConfig.TagOption(rawValue: value) ?? .reachable
            case "prune": remotes[name]?.prune = parseBool(value)
            case sshKeyVariable: remotes[name]?.sshKey = value
            default: break
            }
        }
        // Sections without a URL (e.g. only `remote.pushDefault`-like leftovers) are not remotes.
        return order.compactMap { remotes[$0] }.filter { !$0.url.isEmpty }
    }

    /// git's boolean spellings; nil for anything else.
    public static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0", "": return false
        default: return nil
        }
    }

    /// All remotes of the repository with their settings.
    public static func loadRemotes(in repository: PangolinPath) async -> [GitRemoteConfig] {
        let output = (try? await GitCLIRunner.runAsync(arguments: ["config", "--get-regexp", "^remote\\."],
                                                       workingDirectory: repository)) ?? ""
        return parseRemoteConfig(output)
    }

    /// Names of the configured remotes (`git remote`).
    public static func remoteNames(in repository: PangolinPath) async -> [String] {
        let output = (try? await GitCLIRunner.runAsync(arguments: ["remote"], workingDirectory: repository)) ?? ""
        return output.split(separator: "\n").map(String.init)
    }

    /// Reads a single config value; nil when it is unset.
    public static func configValue(_ key: String, in repository: PangolinPath) async -> String? {
        let value = try? await GitCLIRunner.runAsync(arguments: ["config", "--get", key], workingDirectory: repository)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Branches

    /// Branch names of `remote` as they are on the remote (`refs/remotes/origin/feature/x` →
    /// `feature/x`), without the symbolic `HEAD`.
    public static func parseRemoteBranches(_ output: String, remote: String) -> [String] {
        let prefix = "refs/remotes/\(remote)/"
        return output.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .filter { $0 != "HEAD" && !$0.isEmpty }
    }

    public static func remoteBranches(of remote: String, in repository: PangolinPath) async -> [String] {
        let output = (try? await GitCLIRunner.runAsync(
            arguments: ["for-each-ref", "--format=%(refname)", "refs/remotes/\(remote)/"], workingDirectory: repository)) ?? ""
        return parseRemoteBranches(output, remote: remote)
    }

    public static func localBranches(in repository: PangolinPath) async -> [String] {
        let output = (try? await GitCLIRunner.runAsync(
            arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads/"], workingDirectory: repository)) ?? ""
        return output.split(separator: "\n").map(String.init)
    }

    public static func tags(in repository: PangolinPath) async -> [String] {
        let output = (try? await GitCLIRunner.runAsync(
            arguments: ["for-each-ref", "--sort=-creatordate", "--format=%(refname:short)", "refs/tags/"], workingDirectory: repository)) ?? ""
        return output.split(separator: "\n").map(String.init)
    }

    /// The checked-out branch, or nil on a detached HEAD.
    public static func currentBranch(in repository: PangolinPath) async -> String? {
        let output = try? await GitCLIRunner.runAsync(arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
                                                      workingDirectory: repository)
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `branch.<b>.merge` without `refs/heads/` (`refs/heads/main` → `main`).
    public static func mergeBranchName(_ mergeRef: String) -> String {
        mergeRef.hasPrefix("refs/heads/") ? String(mergeRef.dropFirst("refs/heads/".count)) : mergeRef
    }

    /// The configured upstream of `branch` (`branch.<b>.remote` / `branch.<b>.merge`), as
    /// TortoiseGit's Pull/Push/Sync dialogs preselect it.
    public static func upstream(of branch: String, in repository: PangolinPath) async -> (remote: String, branch: String)? {
        guard let remote = await configValue("branch.\(branch).remote", in: repository),
              let merge = await configValue("branch.\(branch).merge", in: repository) else { return nil }
        return (remote, mergeBranchName(merge))
    }

    // MARK: - Ahead / behind

    /// Parses `git rev-list --left-right --count A...B` (`"<left>\t<right>"`).
    public static func parseLeftRight(_ output: String) -> (left: Int, right: Int)? {
        let parts = output.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
        guard parts.count == 2, let left = Int(parts[0]), let right = Int(parts[1]) else { return nil }
        return (left, right)
    }

    /// Commits only in `a` and only in `b`; nil when either cannot be resolved.
    public static func aheadBehind(_ a: String, _ b: String, in repository: PangolinPath) async -> (ahead: Int, behind: Int)? {
        guard let output = try? await GitCLIRunner.runAsync(arguments: ["rev-list", "--left-right", "--count", "\(a)...\(b)"],
                                                            workingDirectory: repository),
              let counts = parseLeftRight(output) else { return nil }
        return (counts.left, counts.right)
    }

    // MARK: - Ref snapshots (Sync ▸ Ref List)

    /// Parses `git for-each-ref --format=%(objectname) %(refname)` into ref → hash.
    public static func parseRefSnapshot(_ output: String) -> [String: String] {
        var refs: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            refs[String(parts[1])] = String(parts[0])
        }
        return refs
    }

    public static func refSnapshot(in repository: PangolinPath) async -> [String: String] {
        let output = (try? await GitCLIRunner.runAsync(arguments: ["for-each-ref", "--format=%(objectname) %(refname)"],
                                                       workingDirectory: repository)) ?? ""
        return parseRefSnapshot(output)
    }

    /// Ref differences between two snapshots, sorted by ref name. Moved refs get `.changed`;
    /// `classify` refines them into fast-forward / rewind / rewritten.
    public static func compareSnapshots(old: [String: String], new: [String: String]) -> [GitRefChange] {
        let names = Set(old.keys).union(new.keys).sorted()
        return names.map { ref in
            let before = old[ref]
            let after = new[ref]
            let kind: GitRefChangeKind
            switch (before, after) {
            case let (b?, a?): kind = b == a ? .same : .changed
            case (nil, _?): kind = .new
            default: kind = .deleted
            }
            return GitRefChange(ref: ref, oldHash: before, newHash: after, kind: kind)
        }
    }

    /// Maps ahead/behind counts of `new` relative to `old` to a change kind.
    public static func changeKind(ahead: Int, behind: Int) -> GitRefChangeKind {
        switch (ahead, behind) {
        case (0, 0): return .same
        case (_, 0): return .fastForward(ahead)
        case (0, _): return .rewind(behind)
        default: return .diverged(ahead: ahead, behind: behind)
        }
    }

    /// Counts commits for every moved ref.
    public static func classify(_ changes: [GitRefChange], in repository: PangolinPath) async -> [GitRefChange] {
        var result = changes
        for index in result.indices where result[index].kind == .changed {
            guard let old = result[index].oldHash, let new = result[index].newHash,
                  let counts = await aheadBehind(new, old, in: repository) else { continue }
            result[index].kind = changeKind(ahead: counts.ahead, behind: counts.behind)
        }
        return result
    }

    // MARK: - Tags (Sync ▸ Compare tags)

    /// Parses `git ls-remote --tags` or `git show-ref --tags -d` output into tag → commit. For
    /// annotated tags the peeled `^{}` line (the tagged commit) wins over the tag object.
    public static func parseTagList(_ output: String) -> [String: String] {
        var tags: [String: String] = [:]
        var peeled: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count == 2 else { continue }
            var ref = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard ref.hasPrefix("refs/tags/") else { continue }
            ref.removeFirst("refs/tags/".count)
            if ref.hasSuffix("^{}") {
                peeled[String(ref.dropLast(3))] = String(parts[0])
            } else {
                tags[ref] = String(parts[0])
            }
        }
        return tags.merging(peeled) { _, peeledHash in peeledHash }
    }

    /// Every tag known on either side, sorted by name.
    public static func compareTags(local: [String: String], remote: [String: String]) -> [GitTagComparison] {
        Set(local.keys).union(remote.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { GitTagComparison(name: $0, localHash: local[$0], remoteHash: remote[$0]) }
    }

    // MARK: - SSH keys

    /// Single-quotes `value` for `/bin/sh`.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Environment that makes git's ssh use `keyPath` only — the macOS stand-in for TortoiseGit's
    /// "Autoload Putty key". The passphrase prompt still goes through `pangolin-askpass`.
    public static func sshEnvironment(keyPath: String) -> [String: String] {
        let expanded = (keyPath as NSString).expandingTildeInPath
        return ["GIT_SSH_COMMAND": "ssh -i \(shellQuote(expanded)) -o IdentitiesOnly=yes"]
    }

    /// The SSH environment for operations on `remote`, or nil when it has no key configured.
    public static func sshEnvironment(remote: String, in repository: PangolinPath) async -> [String: String]? {
        guard let key = await configValue("remote.\(remote).\(sshKeyVariable)", in: repository) else { return nil }
        return sshEnvironment(keyPath: key)
    }

    // MARK: - Misc

    /// Whether the repository is a shallow clone (enables *Unshallow* in Fetch).
    public static func isShallow(_ repository: PangolinPath) async -> Bool {
        let output = try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "--is-shallow-repository"], workingDirectory: repository)
        return output?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Paths with unresolved conflicts (`git diff --name-only --diff-filter=U`).
    public static func conflictedPaths(in repository: PangolinPath) async -> [String] {
        let output = (try? await GitCLIRunner.runAsync(arguments: ["diff", "--name-only", "--diff-filter=U"],
                                                       workingDirectory: repository)) ?? ""
        return output.split(separator: "\n").map(String.init)
    }

    /// Parses `git diff --name-status` into (status letter, path) pairs; renames keep the new path.
    public static func parseNameStatus(_ output: String) -> [(status: String, path: String)] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, let letter = fields[0].first else { return nil }
            return (String(letter), fields[fields.count - 1])
        }
    }
}
