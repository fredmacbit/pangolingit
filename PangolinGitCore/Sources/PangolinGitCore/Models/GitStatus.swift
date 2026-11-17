import Foundation

/// Git file status flags mirroring TortoiseGit's `git_wc_status_kind` (`src/Git/gittype.h`).
public enum GitItemStatus: String, Codable, Sendable {
    case clean          // Clean / Unmodified
    case modified       // Working tree modified
    case staged         // Staged in index
    case stagedModified // Staged and modified in working tree
    case added          // Staged as new file
    case deleted        // Deleted in index or working tree
    case renamed        // Renamed
    case copied         // Copied
    case untracked      // Untracked / unversioned
    case ignored        // Ignored by .gitignore
    case conflicted     // Merge conflict
    case missing        // Tracked but absent from disk
    case unknown        // Unknown state
}

extension GitItemStatus: CustomStringConvertible {
    /// Human-readable status as shown in status lists.
    public var description: String {
        switch self {
        case .clean: return "Unmodified"
        case .modified: return "Modified"
        case .staged: return "Staged"
        case .stagedModified: return "Staged + Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .untracked: return "Unversioned"
        case .ignored: return "Ignored"
        case .conflicted: return "Conflicted"
        case .missing: return "Missing"
        case .unknown: return "Unknown"
        }
    }
}

/// Overlay icon badge kinds mirroring TortoiseGit overlay badges.
public enum GitBadgeKind: String, Codable, Sendable {
    case normal         // Green checkmark
    case modified       // Red exclamation mark
    case conflicted     // Yellow warning / exclamation
    case added          // Plus icon
    case deleted        // Minus / X icon
    case ignored        // Grey circle / minus
    case locked         // Lock icon
    case unversioned    // Question mark
    case none           // No badge
    case needsLock      // Assume-unchanged flag (TortoiseGit's "needs-lock" overlay); `.locked` is skip-worktree
}

/// Full status description for a tracked or untracked working-tree item.
public struct GitItemStatusInfo: Codable, Hashable, Sendable {
    public let path: String
    public let status: GitItemStatus
    public let isDirectory: Bool
    public let stagedStatus: GitItemStatus?
    public let isConflicted: Bool
    public let isIgnored: Bool
    public let isSubmodule: Bool
    /// Source path for renamed or copied entries.
    public let originalPath: String?
    
    public init(
        path: String,
        status: GitItemStatus,
        isDirectory: Bool = false,
        stagedStatus: GitItemStatus? = nil,
        isConflicted: Bool = false,
        isIgnored: Bool = false,
        isSubmodule: Bool = false,
        originalPath: String? = nil
    ) {
        self.path = path
        self.status = status
        self.isDirectory = isDirectory
        self.stagedStatus = stagedStatus
        self.isConflicted = isConflicted
        self.isIgnored = isIgnored
        self.isSubmodule = isSubmodule
        self.originalPath = originalPath
    }
    
    /// True when the item has changes recorded in the index.
    public var isStaged: Bool {
        guard let staged = stagedStatus else { return false }
        return staged != .clean && staged != .conflicted
    }
    
    /// Maps the current file status to the corresponding Finder overlay badge.
    public var badgeKind: GitBadgeKind {
        if isConflicted {
            return .conflicted
        }
        if isIgnored {
            return .ignored
        }
        switch status {
        case .conflicted:
            return .conflicted
        case .modified, .stagedModified:
            return .modified
        case .added, .staged:
            return .added
        case .deleted, .missing:
            return .deleted
        case .untracked:
            return .unversioned
        case .clean:
            return .normal
        case .ignored:
            return .ignored
        case .renamed, .copied:
            return .modified
        case .unknown:
            return .none
        }
    }
}
