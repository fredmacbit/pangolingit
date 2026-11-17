import Foundation

/// The multi-step operation a working tree is in the middle of, read from the files git leaves in
/// the git directory (TortoiseGit checks the same files to pick the right dialog: `CTGitPath::IsMergeActive`,
/// `CRebaseDlg::IsRebaseInProgress`, `GitAdminDir`'s `BISECT_START`).
public enum GitOperationInProgress: Equatable, Sendable {
    case none
    case merge
    /// `interactive` is false for the apply backend (`rebase-apply`) used by plain rebases of old gits.
    case rebase(interactive: Bool)
    case cherryPick
    case revert
    case applyMailbox
    case bisect

    public static func detect(gitDirectory: PangolinPath) -> GitOperationInProgress {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: gitDirectory.appendingPathComponent(name).rawPath) }
        if exists("rebase-merge") { return .rebase(interactive: exists("rebase-merge/interactive")) }
        if exists("rebase-apply") { return exists("rebase-apply/applying") ? .applyMailbox : .rebase(interactive: false) }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") || isSequencer("pick", gitDirectory) { return .cherryPick }
        if exists("REVERT_HEAD") || isSequencer("revert", gitDirectory) { return .revert }
        if exists("BISECT_START") { return .bisect }
        return .none
    }

    /// A multi-commit cherry-pick or revert that stopped between commits leaves only `sequencer/todo`.
    private static func isSequencer(_ verb: String, _ gitDirectory: PangolinPath) -> Bool {
        let todo = gitDirectory.appendingPathComponent("sequencer/todo").rawPath
        guard let text = try? String(contentsOfFile: todo, encoding: .utf8) else { return false }
        let first = text.split(separator: "\n").first { !$0.hasPrefix("#") }
        return first?.hasPrefix(verb) ?? false
    }

    public var displayName: String {
        switch self {
        case .none: return ""
        case .merge: return "merge"
        case .rebase: return "rebase"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        case .applyMailbox: return "patch application (am)"
        case .bisect: return "bisect"
        }
    }
}

/// One line of a rebase todo list (`git-rebase-todo` / `done`).
public struct GitRebaseTodoLine: Equatable, Sendable {
    public enum Action: String, CaseIterable, Sendable {
        case pick, reword, edit, squash, fixup, drop

        /// Accepts git's one-letter and long forms (`p`, `r`, `e`, `s`, `f`, `d`).
        public init?(word: String) {
            switch word {
            case "p", "pick": self = .pick
            case "r", "reword": self = .reword
            case "e", "edit": self = .edit
            case "s", "squash": self = .squash
            case "f", "fixup": self = .fixup
            case "d", "drop": self = .drop
            default: return nil
            }
        }
    }

    /// Raw verb as written (also `exec`, `break`, `label`, … which carry no commit).
    public let verb: String
    public let action: Action?
    public let hash: String
    public let subject: String

    public init(verb: String, hash: String, subject: String) {
        self.verb = verb
        self.action = Action(word: verb)
        self.hash = hash
        self.subject = subject
    }
}

/// State of a stopped rebase (`.git/rebase-merge/`), shown by TortoiseGit's rebase dialog when it is
/// reopened mid-rebase: steps done, steps left, the commit it stopped at and why.
public struct GitRebaseProgress: Equatable, Sendable {
    public let done: [GitRebaseTodoLine]
    public let remaining: [GitRebaseTodoLine]
    /// 1-based number of the current step and the total (`msgnum` / `end`).
    public let step: Int
    public let total: Int
    /// Commit being applied when git stopped (`stopped-sha`).
    public let stoppedHash: String?
    /// Branch being rebased (`head-name`, e.g. `refs/heads/feature`).
    public let headName: String
    public let ontoHash: String
    /// git stopped at an `edit` step after committing (the `amend` file exists): the commit can be amended.
    public let isEditStop: Bool

    public static func read(gitDirectory: PangolinPath) -> GitRebaseProgress? {
        let dir = gitDirectory.appendingPathComponent("rebase-merge")
        guard FileManager.default.fileExists(atPath: dir.rawPath) else { return nil }
        func read(_ name: String) -> String {
            ((try? String(contentsOfFile: dir.appendingPathComponent(name).rawPath, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let done = parseTodo(read("done"))
        let remaining = parseTodo(read("git-rebase-todo"))
        let stopped = read("stopped-sha")
        return GitRebaseProgress(
            done: done,
            remaining: remaining,
            step: Int(read("msgnum")) ?? done.count,
            total: Int(read("end")) ?? (done.count + remaining.count),
            stoppedHash: stopped.isEmpty ? nil : stopped,
            headName: read("head-name"),
            ontoHash: read("onto"),
            isEditStop: FileManager.default.fileExists(atPath: dir.appendingPathComponent("amend").rawPath)
        )
    }

    /// Parses todo text, skipping comments and blank lines; `exec` and other commit-less verbs keep their argument as subject.
    public static func parseTodo(_ text: String) -> [GitRebaseTodoLine] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            let verb = parts[0]
            guard GitRebaseTodoLine.Action(word: verb) != nil else {
                return GitRebaseTodoLine(verb: verb, hash: "", subject: parts.dropFirst().joined(separator: " "))
            }
            // `fixup -C <hash>` / `fixup -c <hash>` carry an option before the hash.
            var rest = Array(parts.dropFirst())
            if rest.first == "-C" || rest.first == "-c" {
                rest = Array(line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).dropFirst(2).map(String.init))
            }
            return GitRebaseTodoLine(verb: verb, hash: rest.first ?? "", subject: rest.count > 1 ? rest[1] : "")
        }
    }
}
