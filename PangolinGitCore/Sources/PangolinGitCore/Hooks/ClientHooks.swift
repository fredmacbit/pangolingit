import Foundation

/// Client-side hook scripts that run around PangolinGit actions (not git's own `.git/hooks`):
/// TortoiseGit's `CHooks` (`src/Utils/Hooks.cpp`), configured on Settings ▸ Hook Scripts or provided
/// by a project in `.tgitconfig` (`hook.<type>.cmdline/wait/show`).
public enum ClientHookType: String, CaseIterable, Codable, Sendable {
    case startCommit = "start_commit_hook"
    case preCommit = "pre_commit_hook"
    case postCommit = "post_commit_hook"
    case prePush = "pre_push_hook"
    case postPush = "post_push_hook"
    case preRebase = "pre_rebase_hook"

    public var title: String {
        switch self {
        case .startCommit: return "Start-commit"
        case .preCommit: return "Pre-commit"
        case .postCommit: return "Post-commit"
        case .prePush: return "Pre-push"
        case .postPush: return "Post-push"
        case .preRebase: return "Pre-rebase"
        }
    }

    /// The arguments PangolinGit appends to the command line, as documented for TortoiseGit.
    public var argumentSummary: String {
        switch self {
        case .startCommit, .preCommit: return "PATHS MESSAGEFILE CWD"
        case .postCommit: return "CWD AMEND"
        case .prePush, .postPush: return "ERRORFILE CWD"
        case .preRebase: return "UPSTREAM REBASEDBRANCH ERRORFILE CWD"
        }
    }

    /// Name of the `.tgitconfig` section (`hook.startcommit.cmdline`, …).
    var projectKey: String {
        switch self {
        case .startCommit: return "startcommit"
        case .preCommit: return "precommit"
        case .postCommit: return "postcommit"
        case .prePush: return "prepush"
        case .postPush: return "postpush"
        case .preRebase: return "prerebase"
        }
    }
}

/// One configured hook script.
public struct ClientHook: Codable, Equatable, Sendable {
    public var type: ClientHookType
    /// Working tree (or a parent folder) the script applies to, or `*` for every repository.
    public var path: String
    /// Shell command line; `%root%` is replaced by the working-tree root.
    public var commandLine: String
    /// Wait for the script to finish (and honour its exit code).
    public var wait: Bool
    /// TortoiseGit shows the console window; kept for `.tgitconfig` compatibility, scripts run hidden on macOS.
    public var show: Bool
    public var enabled: Bool
    /// Provided by the repository's `.tgitconfig` rather than configured by the user.
    public var fromProject: Bool

    public init(type: ClientHookType, path: String, commandLine: String, wait: Bool = true,
                show: Bool = false, enabled: Bool = true, fromProject: Bool = false) {
        self.type = type
        self.path = path
        self.commandLine = commandLine
        self.wait = wait
        self.show = show
        self.enabled = enabled
        self.fromProject = fromProject
    }

    /// Stable key for remembering the user's approval of a project hook: the command may change, so it is part of the key.
    public var approvalKey: String {
        StoredDecisions.Key.projectHookApprovalPrefix + "\(type.rawValue)|\(path)|\(commandLine)"
    }
}

/// Persistence of the user's hook table.
public final class ClientHookStore: @unchecked Sendable {
    public static let shared = ClientHookStore()
    private let defaults: UserDefaults
    private let key = "clientHooks"

    public init(suiteName: String = "group.be.macbit.pangolingit") {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public var hooks: [ClientHook] {
        get {
            guard let data = defaults.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([ClientHook].self, from: data)) ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }
}

/// Result of running one hook.
public struct ClientHookResult: Sendable, Equatable {
    public let hook: ClientHook
    public let exitCode: Int32
    /// What the script wrote to stderr (TortoiseGit shows it when the script fails).
    public let errorOutput: String
    /// The commit message after a start-/pre-commit hook rewrote MESSAGEFILE (only when it succeeded).
    public let message: String?
    /// The user declined to run a project-provided hook.
    public let declined: Bool

    public var succeeded: Bool { exitCode == 0 && !declined }
}

/// Finds and runs the hook for an action (`CHooks::FindItem`, `CHooks::RunScript`).
public enum ClientHookRunner {

    /// Asks whether a project-provided hook may run (`CHooks::ApproveHook`); true = run.
    public typealias Approval = @Sendable (ClientHook) async -> Bool

    /// Hooks from the repository's `.tgitconfig` / git config (`hook.<type>.cmdline`, `.wait`, `.show`).
    public static func projectHooks(values: [String: String], root: String) -> [ClientHook] {
        ClientHookType.allCases.compactMap { type in
            let base = "hook.\(type.projectKey)."
            guard let command = values[base + "cmdline"], !command.isEmpty else { return nil }
            let wait = values[base + "wait"].map(BugtraqConfig.parseBool) ?? false
            let show = values[base + "show"].map(BugtraqConfig.parseBool) ?? false
            return ClientHook(type: type, path: root, commandLine: command, wait: wait, show: show,
                              enabled: true, fromProject: true)
        }
    }

    /// The hook that applies to `workingTree`: the user's hook for the closest folder at or above
    /// it (a project hook for the same folder comes after the user's own), then a `*` hook.
    public static func find(_ type: ClientHookType, workingTree: String, hooks: [ClientHook],
                            projectHooks: [ClientHook] = []) -> ClientHook? {
        let candidates = hooks.filter { $0.type == type && $0.enabled } + projectHooks.filter { $0.type == type }
        var folder = URL(fileURLWithPath: workingTree).standardizedFileURL
        while true {
            let path = folder.path
            if let match = candidates.first(where: { !$0.fromProject && normalized($0.path) == path })
                ?? candidates.first(where: { $0.fromProject && normalized($0.path) == path }) {
                return match
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == path { break }
            folder = parent
        }
        return candidates.first { $0.path == "*" && !$0.fromProject }
    }

    static func normalized(_ path: String) -> String {
        path == "*" ? path : URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// `%root%` substitution plus the quoted arguments appended to the command line.
    public static func commandLine(for hook: ClientHook, root: String, arguments: [String]) -> String {
        let base = hook.commandLine.replacingOccurrences(of: "%root%", with: root)
        return ([base] + arguments.map(shellQuoted)).joined(separator: " ")
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Actions

    /// Start-commit: before the commit dialog shows. Arguments `PATHS MESSAGEFILE CWD`; the script may rewrite the message.
    public static func startCommit(workingTree: String, paths: [String], message: String,
                                   approve: Approval? = nil) async -> ClientHookResult? {
        await runWithMessage(.startCommit, workingTree: workingTree, paths: paths, message: message, approve: approve)
    }

    /// Pre-commit: after OK, before git commit. Arguments `PATHS MESSAGEFILE CWD`; non-zero exit blocks the commit.
    public static func preCommit(workingTree: String, paths: [String], message: String,
                                 approve: Approval? = nil) async -> ClientHookResult? {
        await runWithMessage(.preCommit, workingTree: workingTree, paths: paths, message: message, approve: approve)
    }

    /// Post-commit: arguments `CWD AMEND` (`true`/`false`).
    public static func postCommit(workingTree: String, amend: Bool, approve: Approval? = nil) async -> ClientHookResult? {
        await run(.postCommit, workingTree: workingTree, arguments: { _ in [workingTree, amend ? "true" : "false"] }, approve: approve)
    }

    /// Pre-push: arguments `ERRORFILE CWD`; non-zero exit blocks the push.
    public static func prePush(workingTree: String, approve: Approval? = nil) async -> ClientHookResult? {
        await run(.prePush, workingTree: workingTree, arguments: { temp in [try temp.file(""), workingTree] }, approve: approve)
    }

    /// Post-push: arguments `ERRORFILE CWD`; ERRORFILE holds the push's error output.
    public static func postPush(workingTree: String, error: String, approve: Approval? = nil) async -> ClientHookResult? {
        await run(.postPush, workingTree: workingTree, arguments: { temp in [try temp.file(error), workingTree] }, approve: approve)
    }

    /// Pre-rebase: arguments `UPSTREAM REBASEDBRANCH ERRORFILE CWD`; non-zero exit blocks the rebase.
    public static func preRebase(workingTree: String, upstream: String, rebasedBranch: String,
                                 approve: Approval? = nil) async -> ClientHookResult? {
        await run(.preRebase, workingTree: workingTree,
                  arguments: { temp in [upstream, rebasedBranch, try temp.file(""), workingTree] }, approve: approve)
    }

    private static func runWithMessage(_ type: ClientHookType, workingTree: String, paths: [String], message: String,
                                       approve: Approval?) async -> ClientHookResult? {
        var messageFile: URL?
        let result = await run(type, workingTree: workingTree, arguments: { temp in
            let pathsFile = try temp.file(paths.joined(separator: "\n"))
            let file = try temp.file(message)
            messageFile = URL(fileURLWithPath: file)
            return [pathsFile, file, workingTree]
        }, approve: approve, readBack: { exitCode in
            guard exitCode == 0, let messageFile else { return nil }
            return try? String(contentsOf: messageFile, encoding: .utf8)
        })
        return result
    }

    /// Temporary files handed to a script, removed afterwards.
    final class TemporaryFiles {
        let directory: URL
        private var counter = 0

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("pangolin-hook-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }

        func file(_ contents: String) throws -> String {
            counter += 1
            let url = directory.appendingPathComponent("arg\(counter).txt")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func run(_ type: ClientHookType, workingTree: String,
                            arguments: (TemporaryFiles) throws -> [String],
                            approve: Approval?,
                            readBack: ((Int32) -> String?)? = nil) async -> ClientHookResult? {
        // Settings ▸ Hooks ▸ "Run hook scripts" master switch.
        guard ConfigManager.shared.hooksEnabled else { return nil }
        let root = URL(fileURLWithPath: workingTree).standardizedFileURL.path
        let projectValues = await GitConfigStore(repository: PangolinPath(root)).values(in: .project)
        guard let hook = find(type, workingTree: root, hooks: ClientHookStore.shared.hooks,
                              projectHooks: projectHooks(values: projectValues, root: root)) else { return nil }

        if hook.fromProject && StoredDecisions.shared.decision(for: hook.approvalKey) != 1 {
            let allowed = await approve?(hook) ?? false
            guard allowed else {
                return ClientHookResult(hook: hook, exitCode: 1, errorOutput: "The hook script was not approved.",
                                        message: nil, declined: true)
            }
        }

        let temp: TemporaryFiles
        let args: [String]
        do {
            temp = try TemporaryFiles()
            args = try arguments(temp)
        } catch {
            return ClientHookResult(hook: hook, exitCode: -1, errorOutput: error.localizedDescription, message: nil, declined: false)
        }
        let command = commandLine(for: hook, root: root, arguments: args)
        let (exitCode, stderr) = await execute(command, in: root, wait: hook.wait)
        let message = readBack?(exitCode)
        if hook.wait { temp.remove() }
        return ClientHookResult(hook: hook, exitCode: exitCode, errorOutput: stderr, message: message, declined: false)
    }

    /// Runs `/bin/sh -c command` in `directory`; without `wait` it is started and reported as successful.
    static func execute(_ command: String, in directory: String, wait: Bool) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                process.environment = GitCLIRunner.makeEnvironment(overrides: nil)
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                let errPipe = Pipe()
                process.standardError = wait ? errPipe : FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                    return
                }
                guard wait else {
                    continuation.resume(returning: (0, ""))
                    return
                }
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
