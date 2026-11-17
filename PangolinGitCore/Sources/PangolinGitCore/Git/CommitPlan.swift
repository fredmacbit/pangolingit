import Foundation

/// The git commands one press of Commit runs (`CCommitDlg::OnOK`): optional new branch, staging
/// of the checked files, then `git commit -F <file>`.
public struct CommitPlan: Equatable, Sendable {
    /// `git checkout -b <name>` first (TortoiseGit's "Commit to new branch").
    public var newBranch: String?
    /// Checked files that exist on disk and need `git add -A` (untracked ones in particular).
    public var pathsToStage: [String] = []
    /// Exactly these paths are committed (`--only`); an empty list commits no file changes
    /// (rewording with Amend, or Message only). nil commits the index as it is (staging support,
    /// concluding a merge).
    public var commitPaths: [String]?
    public var messageFile: String
    public var amend = false
    /// Message only (`--allow-empty`).
    public var allowEmpty = false
    /// `Name <email>`.
    public var author: String?
    /// Anything `--date` accepts (`now`, ISO 8601).
    public var date: String?

    public init(messageFile: String) {
        self.messageFile = messageFile
    }

    public func commands() -> [[String]] {
        var commands: [[String]] = []
        if let newBranch {
            commands.append(["checkout", "-b", newBranch])
        }
        if !pathsToStage.isEmpty {
            commands.append(["add", "-A", "--"] + pathsToStage)
        }
        var commit = ["commit", "-F", messageFile]
        if amend { commit.append("--amend") }
        if allowEmpty { commit.append("--allow-empty") }
        if let author { commit.append("--author=\(author)") }
        if let date { commit.append("--date=\(date)") }
        if let commitPaths {
            commit.append("--only")
            if !commitPaths.isEmpty {
                commit.append("--")
                commit.append(contentsOf: commitPaths)
            }
        }
        commands.append(commit)
        return commands
    }

    /// `--date` value for a picked date: local time with its UTC offset.
    public static func dateArgument(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }
}
