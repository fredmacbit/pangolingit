import Foundation

/// How a submodule pointer moved between two revisions — TortoiseGit's `CGitDiff::ChangeType`
/// shown in the Submodule Diff dialog (`SubmoduleDiffDlg.cpp`, `GitDiff::GetSubmoduleChangeType`).
public enum SubmoduleChange: String, Sendable, Equatable {
    case newSubmodule = "New submodule"
    case deletedSubmodule = "Deleted submodule"
    case identical = "Identical"
    case fastForward = "Fast-forward"
    case rewind = "Rewind"
    case newerTime = "Newer commit time (diverged)"
    case olderTime = "Older commit time (diverged)"
    case sameTime = "Same commit time (diverged)"
    case unknown = "Unknown (commit not available locally)"

    /// - Parameters:
    ///   - mergeBase: `git merge-base old new` inside the submodule, nil when it could not be computed.
    ///   - oldTime/newTime: committer timestamps, nil when the commit is not available.
    public static func classify(old: String?, new: String?, mergeBase: String?, oldTime: Int?, newTime: Int?) -> SubmoduleChange {
        guard let old, !old.isEmpty else { return .newSubmodule }
        guard let new, !new.isEmpty else { return .deletedSubmodule }
        if old == new { return .identical }
        if let mergeBase {
            if mergeBase == old { return .fastForward }
            if mergeBase == new { return .rewind }
        }
        guard let oldTime, let newTime else { return .unknown }
        if newTime > oldTime { return .newerTime }
        if newTime < oldTime { return .olderTime }
        return .sameTime
    }
}
