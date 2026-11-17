import Foundation

public enum GitRepositoryError: LocalizedError, Sendable {
    case notARepository(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository(let path):
            return "'\(path)' is not inside a Git working tree."
        }
    }
}

/// Primary Git repository controller providing high-level Git operations.
/// Equivalent to TortoiseGit's `CGit` (`src/Git/Git.cpp` / `Git.h`).
public final class GitRepository: Sendable {
    public let workingDirectory: PangolinPath
    public let gitDirectory: PangolinPath
    private let cliRunner: GitCLIRunner

    public var rootPath: PangolinPath {
        return workingDirectory
    }

    public init(
        workingDirectory: PangolinPath,
        gitDirectory: PangolinPath,
        cliRunner: GitCLIRunner = GitCLIRunner()
    ) {
        self.workingDirectory = workingDirectory
        self.gitDirectory = gitDirectory
        self.cliRunner = cliRunner
    }

    /// Opens the repository enclosing `rootPath` (which may be any file or folder inside the working tree).
    public init(rootPath: PangolinPath, cliRunner: GitCLIRunner = GitCLIRunner()) throws {
        guard let locations = GitAdminDir.findRepository(startingAt: rootPath) else {
            throw GitRepositoryError.notARepository(rootPath.rawPath)
        }
        self.workingDirectory = locations.workingTreeRoot
        self.gitDirectory = locations.gitDirectory
        self.cliRunner = cliRunner
    }

    /// git's well-known empty tree; diffing against it shows a root commit's files as added.
    public static let emptyTreeHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Factory initializer discovering repository root from any subpath.
    public static func open(at path: PangolinPath, cliRunner: GitCLIRunner = GitCLIRunner()) -> GitRepository? {
        return try? GitRepository(rootPath: path, cliRunner: cliRunner)
    }

    // MARK: - Execution helpers

    @discardableResult
    private func git(_ arguments: [String]) async throws -> String {
        return try await cliRunner.runChecked(arguments: arguments, workingDirectory: workingDirectory)
    }

    @discardableResult
    private func gitSync(_ arguments: [String]) throws -> String {
        let result = try cliRunner.runSync(arguments: arguments, workingDirectory: workingDirectory)
        return try GitCLIRunner.checked(result, arguments: arguments)
    }

    private static func nonEmptyLines(_ output: String) -> [String] {
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Status Operations

    private static func statusArguments(untrackedFiles: String, includeIgnored: Bool, pathspec: [String]) -> [String] {
        var args = ["status", "--porcelain=v2", "-z", "--untracked-files=\(untrackedFiles)"]
        if includeIgnored { args.append("--ignored=matching") }
        if !pathspec.isEmpty {
            args.append("--")
            args.append(contentsOf: pathspec)
        }
        return args
    }

    /// Queries the working-tree status using `git status --porcelain=v2 -z`.
    /// - Parameters:
    ///   - untrackedFiles: `all` lists every untracked file, `normal` collapses untracked folders.
    ///   - includeIgnored: also report ignored items (needed for the ignored overlay).
    public func getStatus(
        untrackedFiles: String = "all",
        includeIgnored: Bool = false,
        pathspec: [String] = []
    ) async throws -> [GitItemStatusInfo] {
        let output = try await git(Self.statusArguments(untrackedFiles: untrackedFiles, includeIgnored: includeIgnored, pathspec: pathspec))
        return Self.parsePorcelainV2(output: output)
    }

    /// Synchronous status query.
    public func status(untrackedFiles: String = "all", includeIgnored: Bool = false) throws -> [GitItemStatusInfo] {
        let output = try gitSync(Self.statusArguments(untrackedFiles: untrackedFiles, includeIgnored: includeIgnored, pathspec: []))
        return Self.parsePorcelainV2(output: output)
    }

    /// Parses NUL-delimited `git status --porcelain=v2 -z` output.
    static func parsePorcelainV2(output: String) -> [GitItemStatusInfo] {
        var items: [GitItemStatusInfo] = []
        var records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]

        while let record = records.popFirst() {
            guard let kind = record.first else { continue }
            switch kind {
            case "1":
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { continue }
                items.append(makeChangedEntry(xy: String(parts[1]), sub: String(parts[2]), path: String(parts[8]), originalPath: nil))
            case "2":
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\0<origPath>
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let originalPath = records.popFirst()
                guard parts.count == 10 else { continue }
                items.append(makeChangedEntry(xy: String(parts[1]), sub: String(parts[2]), path: String(parts[9]), originalPath: originalPath))
            case "u":
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                items.append(GitItemStatusInfo(
                    path: String(parts[10]),
                    status: .conflicted,
                    stagedStatus: .conflicted,
                    isConflicted: true
                ))
            case "?":
                let path = String(record.dropFirst(2))
                items.append(GitItemStatusInfo(
                    path: path,
                    status: .untracked,
                    isDirectory: path.hasSuffix("/")
                ))
            case "!":
                let path = String(record.dropFirst(2))
                items.append(GitItemStatusInfo(
                    path: path,
                    status: .ignored,
                    isDirectory: path.hasSuffix("/"),
                    isIgnored: true
                ))
            default:
                continue // "#" headers
            }
        }
        return items
    }

    private static func makeChangedEntry(xy: String, sub: String, path: String, originalPath: String?) -> GitItemStatusInfo {
        let staged = parseStatusCode(xy.first ?? ".")
        let work = parseStatusCode(xy.last ?? ".")

        let effectiveStatus: GitItemStatus
        if work != .clean {
            effectiveStatus = (staged != .clean && staged != .added) ? .stagedModified : (work == .deleted ? .missing : work)
        } else {
            effectiveStatus = staged
        }
        return GitItemStatusInfo(
            path: path,
            status: staged == .renamed || staged == .copied ? staged : effectiveStatus,
            stagedStatus: staged != .clean ? staged : nil,
            isSubmodule: sub.hasPrefix("S"),
            originalPath: originalPath
        )
    }

    private static func parseStatusCode(_ char: Character) -> GitItemStatus {
        switch char {
        case ".": return .clean
        case "M", "T": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "U": return .conflicted
        case "?": return .untracked
        case "!": return .ignored
        default: return .clean
        }
    }

    // MARK: - Branch & Log Operations

    public func getCurrentBranch() async throws -> String {
        return try await git(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func currentBranch() throws -> String {
        return try gitSync(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func getBranches() async throws -> [String] {
        return Self.nonEmptyLines(try await git(["branch", "--list", "--format=%(refname:short)"]))
    }

    public func branches() throws -> [String] {
        return Self.nonEmptyLines(try gitSync(["branch", "--list", "--format=%(refname:short)"]))
    }

    // Record separator \x1e between commits, \x1f between fields (NUL cannot be passed in argv).
    private static let logFormat = "--format=%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI%x1f%D%x1f%s%x1f%b"

    private static func logArguments(limit: Int, range: String?, path: String?) -> [String] {
        var args = ["log", "-n", "\(limit)", "--date-order", logFormat]
        if let range = range, !range.isEmpty {
            args.append(range)
        }
        if let path = path, !path.isEmpty {
            args.append("--")
            args.append(path)
        }
        return args
    }

    public func getLog(limit: Int = 100, range: String? = nil, path: String? = nil) async throws -> [GitRevision] {
        return Self.parseLogOutput(try await git(Self.logArguments(limit: limit, range: range, path: path)))
    }

    public func log(limit: Int = 100, range: String? = nil, path: String? = nil) throws -> [GitRevision] {
        return Self.parseLogOutput(try gitSync(Self.logArguments(limit: limit, range: range, path: path)))
    }

    static func parseLogOutput(_ output: String) -> [GitRevision] {
        var revisions: [GitRevision] = []
        let isoFormatter = ISO8601DateFormatter()

        for record in output.components(separatedBy: "\u{1e}") {
            let fields = record.components(separatedBy: "\u{1f}")
            guard fields.count >= 11 else { continue }
            guard let hash = GitHash(hex: fields[0]) else { continue }

            let parentHashes = fields[1].split(separator: " ").compactMap { GitHash(hex: String($0)) }
            let refs = fields[8]
                .components(separatedBy: ", ")
                .map { $0.replacingOccurrences(of: "HEAD -> ", with: "") }
                .filter { !$0.isEmpty }
            // The body may itself contain \x1f-free text only, but rejoin defensively.
            let body = fields[10...].joined(separator: "\u{1f}").trimmingCharacters(in: .whitespacesAndNewlines)

            revisions.append(GitRevision(
                hash: hash,
                parentHashes: parentHashes,
                author: GitAuthor(name: fields[2], email: fields[3], date: isoFormatter.date(from: fields[4]) ?? Date()),
                committer: GitAuthor(name: fields[5], email: fields[6], date: isoFormatter.date(from: fields[7]) ?? Date()),
                subject: fields[9],
                body: body,
                refs: refs
            ))
        }
        return revisions
    }

    // MARK: - Mutations: Staging & Commits

    public func add(paths: [String]) async throws {
        try await git(["add", "--"] + paths)
    }

    /// Stages the given paths, including deletions.
    public func stage(paths: [String]) async throws {
        try await git(["add", "-A", "--"] + paths)
    }

    /// Stages the removal of tracked paths without touching the working tree (for files already
    /// deleted on disk, TortoiseGit's "Delete" on a missing file).
    public func removeFromIndex(paths: [String]) async throws {
        try await git(["rm", "--cached", "-r", "-q", "--"] + paths)
    }

    /// Brings deleted working-tree files back from the index.
    public func restoreFromIndex(paths: [String]) async throws {
        try await git(["checkout", "--"] + paths)
    }

    /// Removes the given paths from the index, keeping working-tree changes.
    public func unstage(paths: [String]) async throws {
        if hasHead {
            try await git(["restore", "--staged", "--"] + paths)
        } else {
            // Unborn branch: there is no HEAD to restore from, so drop the entries from the index.
            try await git(["rm", "--cached", "-r", "-q", "--"] + paths)
        }
    }
    
    /// False on an unborn branch (freshly initialised repository without commits).
    public var hasHead: Bool {
        return (try? gitSync(["rev-parse", "--verify", "-q", "HEAD"])) != nil
    }

    /// Commits. When `paths` is given, exactly those paths are committed (`--only`), regardless of
    /// whatever else happens to be staged — the TortoiseGit commit-dialog semantics.
    public func commit(message: String, amend: Bool = false, paths: [String]? = nil) async throws {
        var args = ["commit", "-m", message]
        if amend { args.append("--amend") }
        if let paths, !paths.isEmpty {
            args.append(contentsOf: ["--only", "--"])
            args.append(contentsOf: paths)
        }
        try await git(args)
    }
    
    /// Discards local changes (index and working tree) for the given entries, like TortoiseGit's Revert.
    /// Files that are new in the index are unstaged but kept on disk; untracked files are left alone.
    public func discardChanges(_ items: [GitItemStatusInfo]) async throws {
        var restore: [String] = []
        var unstageOnly: [String] = []
        for item in items {
            switch item.status {
            case .untracked, .ignored, .clean:
                continue
            case .added:
                unstageOnly.append(item.path)
            case .renamed, .copied:
                unstageOnly.append(item.path)
                if item.status == .renamed, let original = item.originalPath {
                    restore.append(original)
                }
            default:
                if item.stagedStatus == .added {
                    unstageOnly.append(item.path)
                } else {
                    restore.append(item.path)
                }
            }
        }
        if !unstageOnly.isEmpty {
            try await git(["rm", "--cached", "-q", "-r", "--"] + unstageOnly)
        }
        if !restore.isEmpty {
            try await git(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + restore)
        }
    }

    // MARK: - Remote Operations: Push, Pull, Fetch

    public func push(remote: String = "origin", branch: String? = nil, force: Bool = false, tags: Bool = false) async throws -> String {
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        if tags { args.append("--tags") }
        args.append(remote)
        if let branch = branch, !branch.isEmpty {
            args.append(branch)
        }
        return try await git(args)
    }

    public func pull(remote: String = "origin", branch: String? = nil, rebase: Bool = false) async throws -> String {
        var args = ["pull", rebase ? "--rebase" : "--no-rebase", remote]
        if let branch = branch, !branch.isEmpty {
            args.append(branch)
        }
        return try await git(args)
    }

    public func fetch(remote: String = "origin", prune: Bool = true, tags: Bool = true) async throws -> String {
        var args = ["fetch"]
        if prune { args.append("--prune") }
        if tags { args.append("--tags") }
        args.append(remote)
        return try await git(args)
    }

    // MARK: - Branch & Checkout

    public func checkout(ref: String, createBranch: Bool = false, force: Bool = false) async throws -> String {
        var args = ["checkout"]
        if force { args.append("-f") }
        if createBranch { args.append("-b") }
        args.append(ref)
        return try await git(args)
    }

    public func createBranch(name: String, startPoint: String = "HEAD", checkout: Bool = true) async throws -> String {
        if checkout {
            return try await git(["checkout", "-b", name, startPoint])
        }
        return try await git(["branch", name, startPoint])
    }

    public func deleteBranch(name: String, force: Bool = false) async throws -> String {
        return try await git(["branch", force ? "-D" : "-d", name])
    }

    // MARK: - Merge & Rebase

    public func merge(branch: String, fastForward: Bool = true, squash: Bool = false, message: String? = nil) async throws -> String {
        var args = ["merge", "--no-edit"]
        if !fastForward { args.append("--no-ff") }
        if squash { args.append("--squash") }
        if let message = message, !message.isEmpty {
            args.append(contentsOf: ["-m", message])
        }
        args.append(branch)
        return try await git(args)
    }

    /// Non-interactive rebase. Interactive rebases are driven by `RebaseWindowController`
    /// through `GIT_SEQUENCE_EDITOR`, never by spawning an editor here.
    public func rebase(upstream: String, branch: String? = nil) async throws -> String {
        var args = ["rebase", upstream]
        if let branch = branch, !branch.isEmpty {
            args.append(branch)
        }
        return try await git(args)
    }

    public func cherryPick(commit: String, noCommit: Bool = false) async throws -> String {
        var args = ["cherry-pick"]
        if noCommit { args.append("-n") }
        args.append(commit)
        return try await git(args)
    }

    // MARK: - Stash Operations

    public func stash(message: String? = nil, includeUntracked: Bool = true) async throws -> String {
        var args = ["stash", "push"]
        if includeUntracked { args.append("-u") }
        if let msg = message, !msg.isEmpty {
            args.append(contentsOf: ["-m", msg])
        }
        return try await git(args)
    }

    public func stashPop(index: Int = 0) async throws -> String {
        return try await git(["stash", "pop", "stash@{\(index)}"])
    }

    public func stashApply(index: Int = 0) async throws -> String {
        return try await git(["stash", "apply", "stash@{\(index)}"])
    }

    public func stashList() throws -> [String] {
        return Self.nonEmptyLines(try gitSync(["stash", "list"]))
    }

    public func stashDrop(index: Int = 0) async throws -> String {
        return try await git(["stash", "drop", "stash@{\(index)}"])
    }

    // MARK: - Reset & Revert

    public enum ResetMode: String, Sendable {
        case soft = "--soft"
        case mixed = "--mixed"
        case hard = "--hard"
        case keep = "--keep"
    }

    public func reset(target: String = "HEAD", mode: ResetMode = .mixed) async throws -> String {
        return try await git(["reset", mode.rawValue, target])
    }

    public func revert(commit: String, noCommit: Bool = false) async throws -> String {
        var args = ["revert", "--no-edit"]
        if noCommit { args.append("-n") }
        args.append(commit)
        return try await git(args)
    }

    public func clean(dryRun: Bool = false, directories: Bool = true, force: Bool = true) async throws -> String {
        var args = ["clean"]
        if dryRun { args.append("-n") }
        if force { args.append("-f") }
        if directories { args.append("-d") }
        return try await git(args)
    }

    // MARK: - Diff & Blame

    public func diff(path: String? = nil, cached: Bool = false, commit: String? = nil) async throws -> String {
        var args = ["diff", "--no-color", "--no-ext-diff"]
        if cached { args.append("--cached") }
        if let commit = commit, !commit.isEmpty { args.append(commit) }
        if let path = path, !path.isEmpty {
            args.append(contentsOf: ["--", path])
        }
        return try await git(args)
    }

    public func blame(path: String, revision: String? = nil) async throws -> String {
        var args = ["blame", "--line-porcelain"]
        if let rev = revision, !rev.isEmpty { args.append(rev) }
        args.append(contentsOf: ["--", path])
        return try await git(args)
    }

    // MARK: - Tags & Remotes

    public func tagList() throws -> [String] {
        return Self.nonEmptyLines(try gitSync(["tag", "-l"]))
    }

    public func tagCreate(name: String, message: String? = nil) async throws -> String {
        var args = ["tag"]
        if let msg = message, !msg.isEmpty {
            args.append(contentsOf: ["-a", "-m", msg])
        }
        args.append(name)
        return try await git(args)
    }

    public func tagDelete(name: String) async throws -> String {
        return try await git(["tag", "-d", name])
    }

    public func remotes() throws -> [String] {
        return Self.nonEmptyLines(try gitSync(["remote"]))
    }

    public func remoteAdd(name: String, url: String) async throws -> String {
        return try await git(["remote", "add", name, url])
    }

    public func remoteRemove(name: String) async throws -> String {
        return try await git(["remote", "remove", name])
    }

    // MARK: - Worktree & Submodule

    public func worktrees() throws -> [String] {
        return try gitSync(["worktree", "list", "--porcelain"])
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst(9)) }
    }

    public func worktreeAdd(path: String, branch: String? = nil) async throws -> String {
        var args = ["worktree", "add", path]
        if let b = branch, !b.isEmpty { args.append(b) }
        return try await git(args)
    }

    public func worktreeRemove(path: String) async throws -> String {
        return try await git(["worktree", "remove", path])
    }

    public func submodules() throws -> [String] {
        return Self.nonEmptyLines(try gitSync(["submodule", "status"]))
    }

    public func submoduleUpdate(initSubmodules: Bool = true, recursive: Bool = true) async throws -> String {
        var args = ["submodule", "update"]
        if initSubmodules { args.append("--init") }
        if recursive { args.append("--recursive") }
        return try await git(args)
    }

    // MARK: - Config

    public func configGet(key: String) throws -> String {
        return try gitSync(["config", "--get", key]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func configSet(key: String, value: String, global: Bool = false) async throws -> String {
        var args = ["config"]
        if global { args.append("--global") }
        args.append(contentsOf: [key, value])
        return try await git(args)
    }
}
