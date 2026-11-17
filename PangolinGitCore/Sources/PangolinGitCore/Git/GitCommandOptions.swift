import Foundation

/// Options of TortoiseGit's Merge dialog (`MergeDlg.cpp`) turned into a `git merge` command line.
public struct GitMergeOptions: Equatable, Sendable {
    public var revision: String
    public var squash = false
    public var noFastForward = false
    public var fastForwardOnly = false
    public var noCommit = false
    /// `--log=<n>`: include up to n one-line commit messages in the merge message; nil = git's default.
    public var logMessages: Int?
    /// `-s <strategy>`; empty = git's default.
    public var strategy = ""
    /// `-X <option>`, e.g. `ours`, `patience`, `rename-threshold=50`; empty = none.
    public var strategyOption = ""
    public var message = ""
    public var allowUnrelatedHistories = false

    public init(revision: String) {
        self.revision = revision
    }

    /// Strategies offered by TortoiseGit (plus git's current default `ort`).
    public static let strategies = ["ort", "recursive", "resolve", "octopus", "ours", "subtree"]
    /// `-X` options; those ending in `=` take a value.
    public static let strategyOptions = ["ours", "theirs", "patience", "diff-algorithm=histogram", "ignore-space-change",
                                         "ignore-all-space", "ignore-space-at-eol", "ignore-cr-at-eol", "renormalize",
                                         "no-renormalize", "find-renames=", "rename-threshold=", "subtree="]

    /// Why the combination cannot run, or nil.
    public var validationError: String? {
        if revision.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose what to merge." }
        if squash && noFastForward { return "“Squash” and “No Fast Forward” cannot be combined." }
        if noFastForward && fastForwardOnly { return "“No Fast Forward” and “Fast Forward Only” cannot be combined." }
        if squash && fastForwardOnly { return "“Squash” and “Fast Forward Only” cannot be combined." }
        if strategyOption.hasSuffix("=") { return "Enter a value for the strategy option “\(strategyOption.dropLast())”." }
        return nil
    }

    public var arguments: [String] {
        var args = ["merge"]
        if squash { args.append("--squash") }
        if noFastForward { args.append("--no-ff") }
        if fastForwardOnly { args.append("--ff-only") }
        if noCommit && !squash { args.append("--no-commit") }
        if let logMessages { args.append(logMessages > 0 ? "--log=\(logMessages)" : "--no-log") }
        if !strategy.isEmpty { args += ["-s", strategy] }
        if !strategyOption.isEmpty { args += ["-X", strategyOption] }
        if allowUnrelatedHistories { args.append("--allow-unrelated-histories") }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { args += ["-m", trimmed] }
        args.append(revision.trimmingCharacters(in: .whitespaces))
        return args
    }
}

/// Options of TortoiseGit's Switch/Checkout dialog (`GitSwitchDlg.cpp`).
public struct GitSwitchOptions: Equatable, Sendable {
    public var target: String
    /// Create this branch at `target` (`-b`), or reset it there if it exists (`-B`, *Override branch if exists*).
    public var newBranch: String?
    public var overrideExistingBranch = false
    /// TortoiseGit's tri-state *Track*: nil = git's default, true = `--track`, false = `--no-track`.
    public var track: Bool?
    public var force = false
    /// `--merge`: carry local changes over with a three-way merge.
    public var merge = false

    public init(target: String) {
        self.target = target
    }

    public var arguments: [String] {
        var args = ["checkout"]
        if force { args.append("--force") }
        if merge { args.append("--merge") }
        if let newBranch, !newBranch.isEmpty {
            if let track { args.append(track ? "--track" : "--no-track") }
            args += [overrideExistingBranch ? "-B" : "-b", newBranch]
        }
        args.append(target)
        // A target that is also a file name must not be read as a path.
        args.append("--")
        return args
    }
}

/// Options of TortoiseGit's rebase dialog (`RebaseDlg.cpp`) for `git rebase`.
public struct GitRebaseOptions: Equatable, Sendable {
    public var upstream: String
    /// Branch to rebase (checked out first by git); nil = the current branch.
    public var branch: String?
    /// `--onto <newbase>`; nil = onto `upstream`.
    public var onto: String?
    public var interactive = true
    public var forceRebase = false
    public var rebaseMerges = false
    public var autostash = false
    public var autosquash = false

    public init(upstream: String) {
        self.upstream = upstream
    }

    public var arguments: [String] {
        var args = ["rebase"]
        if interactive { args.append("--interactive") }
        if forceRebase { args.append("--force-rebase") }
        if rebaseMerges { args.append("--rebase-merges") }
        args.append(autostash ? "--autostash" : "--no-autostash")
        if interactive { args.append(autosquash ? "--autosquash" : "--no-autosquash") }
        if let onto, !onto.isEmpty { args += ["--onto", onto] }
        args.append(upstream)
        if let branch, !branch.isEmpty { args.append(branch) }
        return args
    }
}

/// One entry of the rebase / cherry-pick list as the user arranged it.
public struct GitRebaseStep: Equatable, Sendable {
    public var action: GitRebaseTodoLine.Action
    public let hash: String
    public let subject: String
    /// New message for `reword` (and an `edit`-free message change on `pick`), applied after the pick.
    public var newMessage: String?

    public init(action: GitRebaseTodoLine.Action = .pick, hash: String, subject: String, newMessage: String? = nil) {
        self.action = action
        self.hash = hash
        self.subject = subject
        self.newMessage = newMessage
    }
}

public enum GitRebaseTodo {
    /// Renders the todo list git reads (oldest first). A reworded step becomes `pick` followed by
    /// `exec git commit --amend -F <file>`, because there is no terminal for git to open an editor in;
    /// `messageFile` returns the file holding the step's message.
    public static func render(_ steps: [GitRebaseStep], messageFile: (GitRebaseStep) -> String?) -> String {
        var lines: [String] = []
        for step in steps {
            let subject = step.subject.replacingOccurrences(of: "\n", with: " ")
            if step.action == .reword || (step.action == .pick && step.newMessage != nil) {
                lines.append("pick \(step.hash) \(subject)")
                if let file = messageFile(step) {
                    let quoted = "'" + file.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    lines.append("exec git commit --amend --allow-empty -F \(quoted)")
                }
            } else {
                lines.append("\(step.action.rawValue) \(step.hash) \(subject)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Why the list cannot run, or nil: the first kept step cannot be squashed into nothing.
    public static func validationError(_ steps: [GitRebaseStep]) -> String? {
        guard let first = steps.first(where: { $0.action != .drop }) else {
            return steps.isEmpty ? "There are no commits to rebase." : nil
        }
        if first.action == .squash || first.action == .fixup {
            return "The first commit cannot be squashed or fixed up — there is nothing before it."
        }
        return nil
    }

    /// git's `--autosquash` applied to the list the user sees (our todo replaces git's, so git's own
    /// rearranging would be lost): `fixup! X` / `squash! X` commits move right after the commit whose
    /// subject is X (or whose hash starts with X) and get the matching action.
    public static func autosquash(_ steps: [GitRebaseStep]) -> [GitRebaseStep] {
        var result: [GitRebaseStep] = []
        var pending = steps
        while !pending.isEmpty {
            // A marker whose target comes later (or not at all) stays where it is, as in git.
            let step = pending.removeFirst()
            result.append(step)
            // Pull every later fixup!/squash! aimed at this commit (and at those, recursively) after it.
            var insertAt = result.count
            var targets = [step]
            while let current = targets.popLast() {
                for candidate in pending {
                    guard let (action, target) = autosquashMarker(candidate.subject), matches(current, target) else { continue }
                    var moved = candidate
                    moved.action = action
                    result.insert(moved, at: insertAt)
                    insertAt += 1
                    targets.append(moved)
                }
                pending.removeAll { candidate in result.contains { $0.hash == candidate.hash } }
            }
        }
        return result
    }

    private static func autosquashMarker(_ subject: String) -> (GitRebaseTodoLine.Action, String)? {
        for (prefix, action) in [("fixup! ", GitRebaseTodoLine.Action.fixup), ("squash! ", .squash), ("amend! ", .fixup)]
            where subject.hasPrefix(prefix) {
            return (action, String(subject.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func matches(_ step: GitRebaseStep, _ target: String) -> Bool {
        step.subject == target || (target.count >= 4 && step.hash.hasPrefix(target))
    }
}

/// Options of TortoiseGit's Stash Save dialog (`StashSaveDlg.cpp`).
public struct GitStashPushOptions: Equatable, Sendable {
    public var message = ""
    public var includeUntracked = false
    /// `--all`: also ignored files.
    public var includeIgnored = false
    public var keepIndex = false
    /// Repository-relative paths; empty = everything.
    public var paths: [String] = []

    public init() {}

    public var arguments: [String] {
        var args = ["stash", "push"]
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { args += ["-m", trimmed] }
        if includeIgnored {
            args.append("--all")
        } else if includeUntracked {
            args.append("--include-untracked")
        }
        if keepIndex { args.append("--keep-index") }
        if !paths.isEmpty { args += ["--"] + paths }
        return args
    }
}

/// Options of TortoiseGit's cherry-pick flow (Log ▸ *Cherry Pick*; `RebaseDlg` in cherry-pick mode).
public struct GitCherryPickOptions: Equatable, Sendable {
    /// Commits oldest first.
    public var commits: [String]
    /// `-x`: append "(cherry picked from commit …)".
    public var recordOrigin = false
    /// `-m <n>` for merge commits.
    public var mainline: Int?
    public var noCommit = false
    public var signOff = false

    public init(commits: [String]) {
        self.commits = commits
    }

    public var arguments: [String] {
        var args = ["cherry-pick"]
        if recordOrigin { args.append("-x") }
        if let mainline { args += ["-m", String(mainline)] }
        if noCommit { args.append("--no-commit") }
        if signOff { args.append("--signoff") }
        return args + commits
    }
}
