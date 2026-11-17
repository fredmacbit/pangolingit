import Foundation

/// Point-in-time status of one working tree, answering per-path badge queries in O(depth).
/// Built from a single `git status` run; folder badges are pre-aggregated from their descendants.
/// Equivalent to the per-directory bookkeeping in TortoiseGit's `CCachedDirectory`.
public struct RepositoryStatusSnapshot: Sendable {
    public let root: PangolinPath
    public let createdAt: Date

    private let files: [String: GitItemStatusInfo]
    private let folderBadges: [String: GitBadgeKind]
    private let untrackedFolders: Set<String>
    private let ignoredFolders: Set<String>
    private let flaggedFiles: [String: GitBadgeKind]

    /// Aggregation switches (TortoiseGit Settings ▸ Icon Overlays) and index flags.
    public struct Options: Sendable {
        /// Unversioned files mark their folders as modified.
        public var unversionedMarksParentModified: Bool
        /// Changes inside a submodule mark the folders above it as modified.
        public var submoduleStatusInParent: Bool
        /// `.locked` (skip-worktree) / `.needsLock` (assume-unchanged) per path, from `GitIndexFlags`.
        public var flaggedFiles: [String: GitBadgeKind]

        public init(unversionedMarksParentModified: Bool = false, submoduleStatusInParent: Bool = true,
                    flaggedFiles: [String: GitBadgeKind] = [:]) {
            self.unversionedMarksParentModified = unversionedMarksParentModified
            self.submoduleStatusInParent = submoduleStatusInParent
            self.flaggedFiles = flaggedFiles
        }
    }

    public init(root: PangolinPath, items: [GitItemStatusInfo], createdAt: Date = Date(), options: Options = Options()) {
        self.root = root
        self.createdAt = createdAt

        var files: [String: GitItemStatusInfo] = [:]
        var folders: [String: GitBadgeKind] = [:]
        var untracked = Set<String>()
        var ignored = Set<String>()

        for item in items {
            if item.path.hasSuffix("/") {
                // `--untracked-files=normal` reports whole untracked folders as "dir/".
                let dir = String(item.path.dropLast())
                if item.status == .ignored { ignored.insert(dir) } else { untracked.insert(dir) }
                if item.status == .untracked && options.unversionedMarksParentModified {
                    Self.bubble(.modified, from: dir, into: &folders)
                }
                continue
            }
            files[item.path] = item
            if item.isSubmodule && !options.submoduleStatusInParent { continue }

            // By default only tracked changes bubble up; like TortoiseGit, a folder holding only
            // unversioned or ignored files keeps its normal badge.
            let folderBadge: GitBadgeKind
            switch item.badgeKind {
            case .conflicted: folderBadge = .conflicted
            case .modified, .added, .deleted: folderBadge = .modified
            case .unversioned where options.unversionedMarksParentModified: folderBadge = .modified
            default: continue
            }
            Self.bubble(folderBadge, from: item.path, into: &folders)
        }

        self.files = files
        self.folderBadges = folders
        self.untrackedFolders = untracked
        self.ignoredFolders = ignored
        self.flaggedFiles = options.flaggedFiles
    }

    /// Raises every folder above `path` to at least `folderBadge`.
    private static func bubble(_ folderBadge: GitBadgeKind, from path: String, into folders: inout [String: GitBadgeKind]) {
        var parent = (path as NSString).deletingLastPathComponent
        while true {
            if rank(folderBadge) > rank(folders[parent] ?? .normal) {
                folders[parent] = folderBadge
            }
            if parent.isEmpty { break }
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    private static func rank(_ badge: GitBadgeKind) -> Int {
        switch badge {
        case .conflicted: return 2
        case .modified: return 1
        default: return 0
        }
    }

    /// Looks up the badge for a path relative to the working-tree root ("" is the root itself).
    public func lookup(relativePath rel: String, isDirectory: Bool) -> (badge: GitBadgeKind, status: GitItemStatus) {
        if rel == ".git" || rel.hasPrefix(".git/") {
            return (.none, .unknown)
        }
        if let item = files[rel] {
            return (item.badgeKind, item.status)
        }
        if let flag = flaggedFiles[rel] {
            return (flag, .clean)
        }
        if Self.hasAncestor(rel, in: ignoredFolders) {
            return (.ignored, .ignored)
        }
        if Self.hasAncestor(rel, in: untrackedFolders) {
            return (.unversioned, .untracked)
        }
        if isDirectory, let badge = folderBadges[rel] {
            return (badge, badge == .conflicted ? .conflicted : .modified)
        }
        return (.normal, .clean)
    }

    /// True when `rel` equals or lies beneath one of `folders`.
    private static func hasAncestor(_ rel: String, in folders: Set<String>) -> Bool {
        guard !folders.isEmpty else { return false }
        var current = rel
        while !current.isEmpty {
            if folders.contains(current) { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }
}

/// Parses `git ls-files -v -z` into the skip-worktree / assume-unchanged badges (TortoiseGit's
/// "Locked" and "Needs-lock" overlays): tag `S` is skip-worktree, a lower-case tag is assume-unchanged.
public enum GitIndexFlags {
    public static let arguments = ["ls-files", "-v", "-z"]

    public static func parse(_ output: String) -> [String: GitBadgeKind] {
        var flags: [String: GitBadgeKind] = [:]
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard record.count > 2, let tag = record.first else { continue }
            let path = String(record.dropFirst(2))
            if tag == "S" || tag == "s" {
                flags[path] = .locked
            } else if tag.isLowercase {
                flags[path] = .needsLock
            }
        }
        return flags
    }
}
