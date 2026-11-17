import Foundation
import PangolinGitCore

/// Footer text of a status list, like TortoiseGit's "lines: +n -m, files: N modified, N added, …".
enum StatusSummary {
    static func text(for items: [GitItemStatusInfo], lineCounts: [String: GitLineCount]) -> String {
        guard !items.isEmpty else { return "No changes" }
        var added = 0
        var removed = 0
        for item in items {
            if let count = lineCounts[item.path] {
                added += count.added ?? 0
                removed += count.removed ?? 0
            }
        }
        let groups: [(String, (GitItemStatusInfo) -> Bool)] = [
            ("modified", { [.modified, .stagedModified].contains($0.status) }),
            ("added", { $0.status == .added || ($0.status == .staged && $0.stagedStatus == .added) }),
            ("deleted", { [.deleted, .missing].contains($0.status) }),
            ("renamed", { [.renamed, .copied].contains($0.status) }),
            ("conflicted", { $0.status == .conflicted || $0.isConflicted }),
            ("unversioned", { $0.status == .untracked }),
            ("ignored", { $0.status == .ignored }),
            ("unmodified", { $0.status == .clean })
        ]
        let files = groups.compactMap { name, matches -> String? in
            let count = items.filter(matches).count
            return count > 0 ? "\(count) \(name)" : nil
        }
        let lines = lineCounts.isEmpty ? "" : "Lines: +\(added) −\(removed) · "
        return lines + "Files: " + (files.isEmpty ? "\(items.count)" : files.joined(separator: ", "))
    }
}
