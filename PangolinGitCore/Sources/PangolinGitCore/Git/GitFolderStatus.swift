import Foundation

/// Aggregates file statuses within directories to calculate hierarchical folder badges.
/// Equivalent to TortoiseGit's `CGitFolderStatus` (`src/Git/GitFolderStatus.cpp`).
public enum GitFolderStatus {
    
    /// Derives the aggregate badge and status for a directory given the statuses of items within it.
    public static func aggregate(items: [GitItemStatusInfo]) -> GitBadgeKind {
        if items.isEmpty {
            return .normal
        }
        
        var hasConflicted = false
        var hasModified = false
        var hasAdded = false
        var hasDeleted = false
        var hasUntracked = false
        var allIgnored = true
        
        for item in items {
            if !item.isIgnored {
                allIgnored = false
            }
            
            switch item.badgeKind {
            case .conflicted:
                hasConflicted = true
            case .modified:
                hasModified = true
            case .added:
                hasAdded = true
            case .deleted:
                hasDeleted = true
            case .unversioned:
                hasUntracked = true
            case .normal, .ignored, .locked, .needsLock, .none:
                break
            }
        }
        
        // Priority order mirrors TortoiseGit:
        // 1. Conflicted
        // 2. Modified
        // 3. Added
        // 4. Deleted
        // 5. Unversioned
        // 6. Ignored
        // 7. Clean / Normal
        if hasConflicted {
            return .conflicted
        }
        if hasModified {
            return .modified
        }
        if hasAdded {
            return .added
        }
        if hasDeleted {
            return .deleted
        }
        if hasUntracked {
            return .unversioned
        }
        if allIgnored && !items.isEmpty {
            return .ignored
        }
        return .normal
    }
}
