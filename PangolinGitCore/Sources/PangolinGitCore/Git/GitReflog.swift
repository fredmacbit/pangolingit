import Foundation

/// One reflog entry (a row of TortoiseGit's RefLog dialog, `RefLogDlg.cpp`: Ref, Action, Message, Date).
public struct GitReflogEntry: Sendable, Equatable {
    /// `HEAD@{2}`, `main@{0}`, `stash@{1}` — usable wherever git takes a revision.
    public let selector: String
    public let index: Int
    public let hash: String
    /// What moved the ref, e.g. `commit`, `checkout`, `rebase (finish)`, `reset`.
    public let action: String
    /// The rest of the reflog subject (for stashes the stash message).
    public let message: String
    public let date: Date?

    public init(selector: String, index: Int, hash: String, action: String, message: String, date: Date?) {
        self.selector = selector
        self.index = index
        self.hash = hash
        self.action = action
        self.message = message
        self.date = date
    }
}

public enum GitReflog {
    /// Arguments for `git reflog show` of `ref`; `limit` nil lists every entry. Fields are separated
    /// by U+001F so subjects containing `|` or `:` are kept whole.
    public static func arguments(ref: String, limit: Int? = nil) -> [String] {
        var args = ["reflog", "show", "--date=unix", "--format=%gd%x1f%H%x1f%gs"]
        if let limit { args.append("-n\(limit)") }
        args += [ref, "--"]
        return args
    }

    /// Parses the output of `arguments(ref:)`. With `--date=unix` git prints the date instead of the
    /// index inside `@{…}`; entries come in index order, so the index is the position.
    public static func parse(_ output: String, ref: String) -> [GitReflogEntry] {
        let shortRef = shortName(ref)
        var entries: [GitReflogEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            let index = entries.count
            let (action, message) = splitSubject(fields[2])
            entries.append(GitReflogEntry(selector: "\(shortRef)@{\(index)}", index: index, hash: fields[1],
                                          action: action, message: message, date: date(fromSelector: fields[0])))
        }
        return entries
    }

    /// `checkout: moving from a to b` → (`checkout`, `moving from a to b`). Stash subjects
    /// (`On main: message`, `WIP on main: …`) are kept as the message with the action `stash`.
    static func splitSubject(_ subject: String) -> (String, String) {
        if subject.hasPrefix("On ") || subject.hasPrefix("WIP on ") {
            return ("stash", subject)
        }
        guard let range = subject.range(of: ": ") else { return (subject, "") }
        return (String(subject[..<range.lowerBound]), String(subject[range.upperBound...]))
    }

    static func date(fromSelector selector: String) -> Date? {
        guard let open = selector.range(of: "@{", options: .backwards) else { return nil }
        let inside = selector[open.upperBound...].prefix { $0.isNumber }
        return TimeInterval(String(inside)).map { Date(timeIntervalSince1970: $0) }
    }

    /// `refs/heads/main` → `main`; `refs/stash` → `stash`.
    public static func shortName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/", "refs/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }
}
