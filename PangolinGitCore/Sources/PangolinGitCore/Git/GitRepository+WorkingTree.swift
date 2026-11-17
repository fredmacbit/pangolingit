import Foundation

/// Conflict-handling helpers for the operation state defined in `GitSequencer.swift`. TortoiseGit looks
/// at the same marker files to offer *Abort Merge* and to label the conflict sides
/// (`CAppUtils::MergeAbort`, `CGitStatusListCtrl` "Resolve using mine/theirs").
extension GitOperationInProgress {
    public var title: String {
        switch self {
        case .none: return ""
        case .merge: return "Merge"
        case .cherryPick: return "Cherry-pick"
        case .revert: return "Revert"
        case .rebase: return "Rebase"
        case .applyMailbox: return "Apply patches"
        case .bisect: return "Bisect"
        }
    }

    /// The command that cancels the operation and restores the pre-operation state. A merge is
    /// aborted with `git reset` (see `AbortMergeWindowController`) so it is not listed here.
    public var abortArguments: [String]? {
        switch self {
        case .none, .merge: return nil
        case .cherryPick: return ["cherry-pick", "--abort"]
        case .revert: return ["revert", "--abort"]
        case .rebase: return ["rebase", "--abort"]
        case .applyMailbox: return ["am", "--abort"]
        case .bisect: return ["bisect", "reset"]
        }
    }

    /// Detects a conflict-producing operation from the names of the entries that exist in the
    /// (per-worktree) git directory; nil when there is none.
    static func detect(existing: Set<String>) -> GitOperationInProgress? {
        if existing.contains("rebase-merge") { return .rebase(interactive: existing.contains("rebase-merge/interactive")) }
        if existing.contains("rebase-apply") {
            return existing.contains("rebase-apply/applying") ? .applyMailbox : .rebase(interactive: false)
        }
        if existing.contains("MERGE_HEAD") { return .merge }
        if existing.contains("CHERRY_PICK_HEAD") { return .cherryPick }
        if existing.contains("REVERT_HEAD") { return .revert }
        return nil
    }
}

/// Which version wins when resolving a conflict without the editor.
public enum GitConflictSide: Sendable {
    /// `--ours`: the checked-out side (the upstream during a rebase).
    case mine
    /// `--theirs`: the side being merged in (your own commit during a rebase).
    case theirs

    var checkoutFlag: String { self == .mine ? "--ours" : "--theirs" }
    /// Index stage holding this side's version.
    var stage: Int { self == .mine ? 2 : 3 }
}

/// Human-readable names of the two conflict sides, shown in menu titles.
public struct GitConflictSideNames: Sendable, Equatable {
    public let mine: String
    public let theirs: String

    public init(mine: String, theirs: String) {
        self.mine = mine
        self.theirs = theirs
    }
}

/// Local-change flags shown by `git ls-files -v` (TortoiseGit's "ignore local changes" group).
public enum GitLocalChangeFlag: String, Sendable {
    case assumeUnchanged
    case skipWorktree

    public var title: String {
        self == .assumeUnchanged ? "Assume Unchanged" : "Skip Worktree"
    }
}

/// Lines added and removed for one file (`git diff --numstat`); nil counts mean binary.
public struct GitLineCount: Sendable, Equatable {
    public let added: Int?
    public let removed: Int?
    public init(added: Int?, removed: Int?) {
        self.added = added
        self.removed = removed
    }
}

/// One `git check-ignore -v` hit: the line of which ignore file matches the path.
public struct GitIgnoreMatch: Sendable, Equatable {
    /// Ignore file as git reports it (relative to the repository root or absolute).
    public let source: String
    public let lineNumber: Int
    public let pattern: String
    public let path: String

    /// A negated pattern (`!foo`) re-includes the path, so it is not ignored by this line.
    public var isNegation: Bool { pattern.hasPrefix("!") }
}

/// Options of the Clean up dialog (TortoiseGit's `CCleanTypeDlg`).
public struct GitCleanOptions: Sendable, Equatable {
    public enum Scope: Int, Sendable {
        /// `-x`: untracked and ignored files.
        case allUntracked = 0
        /// Untracked files that are not ignored (git's default).
        case nonIgnored = 1
        /// `-X`: ignored files only.
        case ignoredOnly = 2
    }

    public var scope: Scope = .nonIgnored
    /// `-d`: also remove untracked directories.
    public var directories = true
    /// Second `-f`: also remove untracked nested repositories.
    public var nestedRepositories = false
    /// Run the same clean in every (recursive) submodule.
    public var submodules = false

    public init(scope: Scope = .nonIgnored, directories: Bool = true, nestedRepositories: Bool = false, submodules: Bool = false) {
        self.scope = scope
        self.directories = directories
        self.nestedRepositories = nestedRepositories
        self.submodules = submodules
    }
}

extension GitRepository {

    // MARK: - Operation state

    /// The merge / cherry-pick / revert / rebase that is waiting for conflicts to be resolved, if any.
    public var operationInProgress: GitOperationInProgress? {
        let fm = FileManager.default
        let names = ["rebase-merge", "rebase-merge/interactive", "rebase-apply", "rebase-apply/applying",
                     "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"]
        let existing = Set(names.filter { fm.fileExists(atPath: gitDirectory.appending($0).rawPath) })
        return GitOperationInProgress.detect(existing: existing)
    }

    /// Names for the "mine" and "theirs" sides of the current conflict, e.g. `main` / `feature`.
    /// During a rebase git's "ours" is the upstream being rebased onto, so the labels follow that.
    public func conflictSideNames() -> GitConflictSideNames {
        let branch = (try? currentBranch()) ?? "HEAD"
        func read(_ name: String) -> String {
            let raw = (try? String(contentsOfFile: gitDirectory.appending(name).rawPath, encoding: .utf8)) ?? ""
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func short(_ hash: String) -> String { String(hash.prefix(7)) }

        switch operationInProgress {
        case .merge:
            let theirs = Self.mergeSourceName(fromMergeMessage: read("MERGE_MSG")) ?? short(read("MERGE_HEAD"))
            return GitConflictSideNames(mine: branch, theirs: theirs.isEmpty ? "theirs" : theirs)
        case .rebase:
            let headName = read("rebase-merge/head-name").isEmpty ? read("rebase-apply/head-name") : read("rebase-merge/head-name")
            let onto = read("rebase-merge/onto").isEmpty ? read("rebase-apply/onto") : read("rebase-merge/onto")
            let mine = headName.replacingOccurrences(of: "refs/heads/", with: "")
            return GitConflictSideNames(mine: onto.isEmpty ? "upstream" : "upstream \(short(onto))",
                                        theirs: mine.isEmpty ? "your commit" : mine)
        case .cherryPick:
            return GitConflictSideNames(mine: branch, theirs: short(read("CHERRY_PICK_HEAD")))
        case .revert:
            return GitConflictSideNames(mine: branch, theirs: "revert of \(short(read("REVERT_HEAD")))")
        default:
            return GitConflictSideNames(mine: branch, theirs: "theirs")
        }
    }

    /// The merged branch named in the first line of `MERGE_MSG` ("Merge branch 'x' into y",
    /// "Merge remote-tracking branch 'origin/x'", "Merge tag 'v1'", "Merge commit 'abc'").
    static func mergeSourceName(fromMergeMessage message: String) -> String? {
        guard let first = message.components(separatedBy: .newlines).first, first.hasPrefix("Merge "),
              let open = first.firstIndex(of: "'") else { return nil }
        let rest = first[first.index(after: open)...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        let name = String(rest[..<close])
        return name.isEmpty ? nil : name
    }

    // MARK: - Resolve

    /// Index stages (1 = base, 2 = ours, 3 = theirs) present for each conflicted path.
    public func conflictStages(paths: [String]) throws -> [String: Set<Int>] {
        Self.parseUnmergedStages(try GitCLIRunner.run(arguments: ["ls-files", "-u", "-z", "--"] + paths, workingDirectory: workingDirectory))
    }

    /// Parses `git ls-files -u -z`: `<mode> <hash> <stage>\t<path>` records.
    static func parseUnmergedStages(_ output: String) -> [String: Set<Int>] {
        var stages: [String: Set<Int>] = [:]
        for record in output.split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]) else { continue }
            stages[String(record[record.index(after: tab)...]), default: []].insert(stage)
        }
        return stages
    }

    /// Commands that resolve the conflicted `paths` with one side's version (TortoiseGit's
    /// "Resolve conflict using mine/theirs"): check that version out and stage it. A side that deleted
    /// the file has no version to check out, so the file is removed instead.
    static func resolveCommands(paths: [String], side: GitConflictSide, stages: [String: Set<Int>]) -> [[String]] {
        var keep: [String] = []
        var delete: [String] = []
        for path in paths {
            if let present = stages[path], !present.contains(side.stage) {
                delete.append(path)
            } else {
                keep.append(path)
            }
        }
        var commands: [[String]] = []
        if !keep.isEmpty {
            commands.append(["checkout", side.checkoutFlag, "--"] + keep)
            commands.append(["add", "-v", "--"] + keep)
        }
        if !delete.isEmpty {
            commands.append(["rm", "-f", "--"] + delete)
        }
        return commands
    }

    /// Commands for "Resolve using mine/theirs" on the given conflicted paths.
    public func resolveCommands(paths: [String], side: GitConflictSide) -> [[String]] {
        let stages = (try? conflictStages(paths: paths)) ?? [:]
        return Self.resolveCommands(paths: paths, side: side, stages: stages)
    }

    /// Marks conflicted paths resolved as they are on disk (`git add`; a deleted file is staged as deleted).
    public static func markResolvedCommand(paths: [String]) -> [String] {
        ["add", "-A", "-v", "--"] + paths
    }

    // MARK: - Revert

    /// Commands that discard local changes for `items` (TortoiseGit's Revert): restore modified,
    /// deleted and conflicted files from HEAD, and unstage additions (kept on disk). Untracked and
    /// ignored items are skipped. Same rules as `discardChanges`, as a list for the progress window.
    public static func revertCommands(for items: [GitItemStatusInfo], hasHead: Bool = true) -> [[String]] {
        let plan = revertPlan(for: items)
        var commands: [[String]] = []
        if !plan.unstage.isEmpty {
            commands.append(["rm", "--cached", "-r", "--"] + plan.unstage)
        }
        if !plan.restore.isEmpty {
            if hasHead {
                commands.append(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + plan.restore)
            } else {
                // Unborn branch: only the index can bring files back.
                commands.append(["checkout", "--"] + plan.restore)
            }
        }
        return commands
    }

    /// Paths restored from HEAD and paths only removed from the index.
    static func revertPlan(for items: [GitItemStatusInfo]) -> (restore: [String], unstage: [String]) {
        var restore: [String] = []
        var unstage: [String] = []
        for item in items {
            switch item.status {
            case .untracked, .ignored, .clean:
                continue
            case .added:
                unstage.append(item.path)
            case .renamed, .copied:
                unstage.append(item.path)
                if item.status == .renamed, let original = item.originalPath {
                    restore.append(original)
                }
            default:
                if item.stagedStatus == .added {
                    unstage.append(item.path)
                } else {
                    restore.append(item.path)
                }
            }
        }
        return (restore, unstage)
    }

    /// Working-tree files that a revert overwrites (they still exist and differ from HEAD); these are
    /// moved to the Trash first when *Use Trash when reverting* is on.
    public static func filesOverwrittenByRevert(_ items: [GitItemStatusInfo]) -> [String] {
        let restore = Set(revertPlan(for: items).restore)
        return items.filter { restore.contains($0.path) && $0.status != .missing && $0.status != .deleted && !$0.isSubmodule }
            .map(\.path)
    }

    // MARK: - Clean up

    /// `git clean` arguments for the options; `dryRun` lists instead of deleting.
    public static func cleanArguments(_ options: GitCleanOptions, dryRun: Bool, paths: [String] = []) -> [String] {
        var args = ["clean"]
        if dryRun { args.append("-n") }
        if options.directories { args.append("-d") }
        switch options.scope {
        case .allUntracked: args.append("-fx")
        case .nonIgnored: args.append("-f")
        case .ignoredOnly: args.append("-fX")
        }
        if options.nestedRepositories { args.append("-f") }
        let scoped = paths.filter { !$0.isEmpty }
        if !scoped.isEmpty {
            args.append("--")
            args.append(contentsOf: scoped)
        }
        return args
    }

    /// The same clean run inside every submodule, recursively.
    public static func submoduleCleanArguments(_ options: GitCleanOptions, dryRun: Bool) -> [String] {
        ["submodule", "foreach", "--recursive", "git"] + cleanArguments(options, dryRun: dryRun)
    }

    /// Repository-relative paths that a `git clean -n` would remove. Understands the "Entering 'sub'"
    /// lines of `git submodule foreach` (paths below it are prefixed) and git's C-style quoting.
    public static func parseCleanDryRun(_ output: String) -> [String] {
        var prefix = ""
        var paths: [String] = []
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("Entering '"), line.hasSuffix("'") {
                let sub = String(line.dropFirst("Entering '".count).dropLast())
                prefix = sub.isEmpty ? "" : sub + "/"
            } else if line.hasPrefix("Would remove ") {
                let path = unquoteGitPath(String(line.dropFirst("Would remove ".count)))
                if !path.isEmpty { paths.append(prefix + path) }
            }
        }
        return paths
    }

    /// Undoes git's C-style quoting of a path (`"a\tb"`, `"\303\251"`); unquoted paths are returned as is.
    public static func unquoteGitPath(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        var bytes: [UInt8] = []
        let inner = Array(raw.dropFirst().dropLast().utf8)
        var index = 0
        while index < inner.count {
            let byte = inner[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < inner.count else {
                bytes.append(byte)
                index += 1
                continue
            }
            let next = inner[index + 1]
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A); index += 2
            case UInt8(ascii: "t"): bytes.append(0x09); index += 2
            case UInt8(ascii: "\""), UInt8(ascii: "\\"): bytes.append(next); index += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0
                var length = 0
                while length < 3, index + 1 + length < inner.count,
                      (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(inner[index + 1 + length]) {
                    value = value * 8 + Int(inner[index + 1 + length] - UInt8(ascii: "0"))
                    length += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                index += 1 + length
            default:
                bytes.append(next); index += 2
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Ignore rules

    /// Which ignore-file line ignores each path (`git check-ignore -v --no-index`, so tracked files
    /// are reported too). Paths that are not ignored are absent.
    public func ignoreMatches(paths: [String]) throws -> [GitIgnoreMatch] {
        guard !paths.isEmpty else { return [] }
        let result = try GitCLIRunner().runSync(arguments: ["-c", "core.quotepath=false", "check-ignore", "-v", "--no-index", "--"] + paths,
                                                workingDirectory: workingDirectory)
        // Exit status 1 just means "nothing ignored".
        return Self.parseCheckIgnore(result.standardOutput).filter { !$0.isNegation }
    }

    /// Parses `git check-ignore -v` lines: `<source>:<line>:<pattern>\t<path>` (`-z` needs `--stdin`).
    static func parseCheckIgnore(_ output: String) -> [GitIgnoreMatch] {
        var matches: [GitIgnoreMatch] = []
        for line in output.components(separatedBy: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let head = line[..<tab]
            let path = unquoteGitPath(String(line[line.index(after: tab)...]))
            // The first ":<digits>:" separates the source from the line number and pattern.
            guard let range = head.range(of: ":[0-9]+:", options: .regularExpression),
                  let number = Int(head[range].dropFirst().dropLast()) else { continue }
            matches.append(GitIgnoreMatch(source: String(head[..<range.lowerBound]), lineNumber: number,
                                          pattern: String(head[range.upperBound...]), path: path))
        }
        return matches
    }

    /// The subset of `paths` that git tracks (`git ls-files`), for warnings before ignoring them.
    public func trackedPaths(among paths: [String]) -> [String] {
        let relevant = paths.filter { !$0.isEmpty }
        guard !relevant.isEmpty,
              let output = try? GitCLIRunner.run(arguments: ["ls-files", "-z", "--"] + relevant, workingDirectory: workingDirectory) else {
            return []
        }
        let tracked = output.split(separator: "\0").map(String.init)
        // A folder counts as tracked when something inside it is.
        return relevant.filter { path in
            let folder = path.hasSuffix("/") ? path : path + "/"
            return tracked.contains { $0 == path || $0.hasPrefix(folder) }
        }
    }

    // MARK: - Local-change flags

    /// Tracked files flagged assume-unchanged or skip-worktree (`git ls-files -v`).
    public func localChangeFlags(pathspec: [String] = []) throws -> [String: GitLocalChangeFlag] {
        var args = ["ls-files", "-v", "-z"]
        if !pathspec.isEmpty { args += ["--"] + pathspec }
        return Self.parseLocalChangeFlags(try GitCLIRunner.run(arguments: args, workingDirectory: workingDirectory))
    }

    /// `ls-files -v` tags: lowercase = assume-unchanged, `S` = skip-worktree.
    static func parseLocalChangeFlags(_ output: String) -> [String: GitLocalChangeFlag] {
        var flags: [String: GitLocalChangeFlag] = [:]
        for record in output.split(separator: "\0") {
            guard record.count > 2, let tag = record.first else { continue }
            let path = String(record.dropFirst(2))
            if tag == "S" || tag == "s" {
                flags[path] = .skipWorktree
            } else if tag.isLowercase {
                flags[path] = .assumeUnchanged
            }
        }
        return flags
    }

    /// `git update-index` commands setting (or with nil clearing both) the flag on `paths`.
    /// update-index honours only the last mode option per run, so clearing takes two.
    public static func flagCommands(_ flag: GitLocalChangeFlag?, paths: [String]) -> [[String]] {
        switch flag {
        case .assumeUnchanged: return [["update-index", "--assume-unchanged", "--"] + paths]
        case .skipWorktree: return [["update-index", "--skip-worktree", "--"] + paths]
        case nil: return [["update-index", "--no-assume-unchanged", "--"] + paths, ["update-index", "--no-skip-worktree", "--"] + paths]
        }
    }

    // MARK: - Line counts

    /// Lines added/removed per path in the working tree against HEAD (or the index on an unborn branch).
    public func lineCounts(pathspec: [String] = []) throws -> [String: GitLineCount] {
        var args = ["diff", "--numstat", "-z", "--no-ext-diff", "--no-renames"]
        args.append(hasHead ? "HEAD" : "--cached")
        if !pathspec.isEmpty { args += ["--"] + pathspec }
        return Self.parseNumstat(try GitCLIRunner.run(arguments: args, workingDirectory: workingDirectory))
    }

    /// Parses `git diff --numstat -z`: `added\tremoved\tpath\0`, or for renames
    /// `added\tremoved\t\0old\0new\0`; binary files report `-`.
    static func parseNumstat(_ output: String) -> [String: GitLineCount] {
        var counts: [String: GitLineCount] = [:]
        var records = output.components(separatedBy: "\0")[...]
        while let record = records.popFirst() {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let count = GitLineCount(added: Int(parts[0]), removed: Int(parts[1]))
            if parts[2].isEmpty {
                _ = records.popFirst()
                if let new = records.popFirst() { counts[new] = count }
            } else {
                counts[String(parts[2])] = count
            }
        }
        return counts
    }

    // MARK: - LFS

    /// True when `.gitattributes` routes some files through Git LFS.
    public var usesLFS: Bool {
        let attributes = (try? String(contentsOfFile: workingDirectory.appending(".gitattributes").rawPath, encoding: .utf8)) ?? ""
        return attributes.contains("filter=lfs")
    }
}
