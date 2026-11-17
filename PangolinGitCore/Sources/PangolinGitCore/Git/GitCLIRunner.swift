import Foundation

/// Git CLI execution result.
public struct GitCLIResult: Sendable {
    public let exitCode: Int32
    /// Raw stdout bytes — use this for blob content, which may be binary.
    public let standardOutputData: Data
    public let standardError: String
    
    public var standardOutput: String {
        return String(decoding: standardOutputData, as: UTF8.self)
    }

    public var isSuccess: Bool {
        return exitCode == 0
    }
}

/// Errors raised when shelling out to git CLI.
public enum GitCLIError: LocalizedError, Sendable {
    case commandFailed(exitCode: Int32, stderr: String, command: String)
    case executableNotFound(String)
    case processCrash(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let stderr, let cmd):
            return "Git command '\(cmd)' failed with exit code \(code): \(stderr)"
        case .executableNotFound(let path):
            return "Git executable not found at '\(path)'"
        case .processCrash(let reason):
            return "Git process terminated unexpectedly: \(reason)"
        }
    }
}

/// Git CLI runner wrapping `Process` for executing mutations (commit, push, pull, etc.).
/// Equivalent to TortoiseGit's process invocation and CLI output parsing in `AppUtils.cpp`.
public final class GitCLIRunner: Sendable {
    public let executablePath: String

    /// Called (on an arbitrary thread) after a command that may change repository state finished,
    /// with its working directory and arguments. The app uses it to refresh windows and Finder
    /// badges after every action from one place.
    nonisolated(unsafe) public static var mutationObserver: (@Sendable (PangolinPath, [String]) -> Void)?

    private static func notifyIfMutating(_ arguments: [String], workingDirectory: PangolinPath?) {
        guard let workingDirectory, isMutating(arguments) else { return }
        // Settings ▸ Saved Data ▸ Action log (TortoiseGit's logfile.txt).
        ActionLog.shared.record(repository: workingDirectory.rawPath, command: commandLine(arguments))
        guard let observer = mutationObserver else { return }
        observer(workingDirectory, arguments)
    }

    /// Whether a git command line can change refs, the index, the working tree or configuration
    /// that other windows display. Read-only forms of mixed commands (`branch --list`,
    /// `stash list`, `remote -v`, …) are not.
    public static func isMutating(_ arguments: [String]) -> Bool {
        // Skip global options: `-c key=value`, `-C dir`, `--no-pager`, …
        var index = 0
        while index < arguments.count, arguments[index].hasPrefix("-") {
            index += (arguments[index] == "-c" || arguments[index] == "-C") ? 2 : 1
        }
        guard index < arguments.count else { return false }
        let verb = arguments[index]
        let rest = Array(arguments[(index + 1)...])
        let subcommand = rest.first { !$0.hasPrefix("-") }
        let flags = Set(rest.filter { $0.hasPrefix("-") })

        switch verb {
        case "add", "rm", "mv", "commit", "reset", "revert", "checkout", "switch", "restore", "rebase", "merge",
             "cherry-pick", "pull", "fetch", "push", "apply", "am", "clean", "update-index", "notes", "gc", "prune":
            if verb == "apply", !flags.isDisjoint(with: ["--check", "--stat", "--numstat", "--summary"]) { return false }
            if verb == "clean", !flags.isDisjoint(with: ["-n", "--dry-run"]) { return false }
            if ["add", "commit", "push", "fetch", "pull", "merge", "rebase"].contains(verb), flags.contains("--dry-run") { return false }
            return true
        case "branch":
            let readOnly: Set<String> = ["--list", "-l", "-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose",
                                         "--contains", "--no-contains", "--merged", "--no-merged", "--show-current", "--format", "--points-at"]
            if flags.contains(where: { flag in readOnly.contains(flag) || flag.hasPrefix("--format=") || flag.hasPrefix("--sort=") }) &&
                flags.isDisjoint(with: ["-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy", "-u", "--set-upstream-to", "--unset-upstream"]) {
                return false
            }
            return subcommand != nil || !flags.isEmpty
        case "tag":
            if flags.contains(where: { ["-l", "--list", "-v", "--verify", "--contains", "--points-at"].contains($0) || $0.hasPrefix("--sort=") || $0.hasPrefix("--format=") }) {
                return false
            }
            return subcommand != nil
        case "stash":
            return !["list", "show"].contains(subcommand ?? "push")
        case "remote":
            return ["add", "remove", "rm", "rename", "set-url", "set-head", "set-branches", "prune", "update"].contains(subcommand ?? "")
        case "worktree":
            return ["add", "remove", "move", "prune", "lock", "unlock", "repair"].contains(subcommand ?? "")
        case "submodule":
            return ["add", "update", "deinit", "sync", "init", "absorbgitdirs", "set-branch", "set-url"].contains(subcommand ?? "")
        case "bisect":
            return !["log", "visualize", "view", "terms"].contains(subcommand ?? "log")
        case "lfs":
            return ["lock", "unlock", "pull", "fetch", "checkout", "track", "untrack", "migrate"].contains(subcommand ?? "")
        case "config":
            return !flags.contains(where: { ["--get", "--get-all", "--get-regexp", "-l", "--list", "--show-origin"].contains($0) })
                && rest.filter({ !$0.hasPrefix("-") }).count >= 2 || flags.contains("--unset") || flags.contains("--unset-all")
        default:
            return false
        }
    }

    /// Creates a runner. When no path is given, the configured or auto-detected git binary is used.
    public init(executablePath: String? = nil) {
        self.executablePath = executablePath ?? GitCLIRunner.resolveGitExecutable()
    }

    /// Locates a usable git binary: the user-configured path first, then Homebrew/MacPorts installs,
    /// then the Xcode Command Line Tools shim at /usr/bin/git.
    public static func resolveGitExecutable() -> String {
        let fm = FileManager.default
        let configured = ConfigManager.shared.gitExecutablePath
        let candidates = [
            configured,
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/opt/local/bin/git",
            "/usr/bin/git"
        ]
        for candidate in candidates where !candidate.isEmpty && fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/git"
    }

    /// Synchronously executes git and returns the raw result. Never call this on the main thread
    /// for network or long-running commands.
    public func runSync(
        arguments: [String],
        workingDirectory: PangolinPath? = nil,
        environment: [String: String]? = nil,
        standardInput: Data? = nil
    ) throws -> GitCLIResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw GitCLIError.executableNotFound(executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let workDir = workingDirectory {
            process.currentDirectoryURL = workDir.url
        }

        process.environment = Self.makeEnvironment(overrides: environment)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = standardInput != nil ? Pipe() : nil
        process.standardInput = inPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw GitCLIError.processCrash(error.localizedDescription)
        }

        if let inPipe, let standardInput {
            inPipe.fileHandleForWriting.write(standardInput)
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain stderr concurrently so neither pipe can fill up and deadlock the child.
        var errData = Data()
        let errDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errDrained.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDrained.wait()
        process.waitUntilExit()
        Self.notifyIfMutating(arguments, workingDirectory: workingDirectory)

        return GitCLIResult(
            exitCode: process.terminationStatus,
            standardOutputData: outData,
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }

    /// The environment every git invocation runs with.
    public static func makeEnvironment(overrides: [String: String]?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Predictable, untranslated output; never block waiting for a terminal prompt.
        env["LC_ALL"] = "C"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // There is no terminal to host an editor: accept default messages instead of hanging
        // (callers that drive an editor, e.g. interactive rebase, override these).
        env["GIT_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        // GUI apps launched from Finder get a minimal PATH; make sure helpers such as git-lfs are found.
        let extraPath = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = env["PATH"].map { "\(extraPath):\($0)" } ?? "\(extraPath):/usr/bin:/bin:/usr/sbin:/sbin"
        if let askPass = AskPassHelper.helperExecutablePath {
            env.merge(AskPassHelper.askPassEnvironment(helperPath: askPass)) { current, _ in current }
        }
        // Settings ▸ Network (TortoiseGit's proxy page). libcurl reads these variables.
        let config = ConfigManager.shared
        if !config.httpProxy.isEmpty { env["http_proxy"] = config.httpProxy }
        if !config.httpsProxy.isEmpty { env["https_proxy"] = config.httpsProxy }
        if !config.httpProxy.isEmpty || !config.httpsProxy.isEmpty { env["no_proxy"] = config.noProxy }
        if !config.sslVerify { env["GIT_SSL_NO_VERIFY"] = "1" }
        // Settings ▸ General ▸ Extra PATH.
        let extra = config.extraPath.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty, let path = env["PATH"] { env["PATH"] = "\(extra):\(path)" }
        // Settings ▸ Hooks ▸ hooks directory: `-c core.hooksPath=…` for every command, through git's
        // GIT_CONFIG_COUNT mechanism so no argument list has to change.
        let hooksDirectory = config.customHooksDirectory.trimmingCharacters(in: .whitespaces)
        if !hooksDirectory.isEmpty {
            let index = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
            env["GIT_CONFIG_KEY_\(index)"] = "core.hooksPath"
            env["GIT_CONFIG_VALUE_\(index)"] = (hooksDirectory as NSString).expandingTildeInPath
            env["GIT_CONFIG_COUNT"] = String(index + 1)
        }
        if let overrides {
            env.merge(overrides) { _, new in new }
        }
        return env
    }

    /// Runs git and delivers its output while it runs (for the progress window). `onOutput` is
    /// called off the main thread with each chunk and whether it came from stderr. Cancelling the
    /// calling task terminates git.
    public func stream(
        arguments: [String],
        workingDirectory: PangolinPath? = nil,
        environment: [String: String]? = nil,
        onOutput: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> GitCLIResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw GitCLIError.executableNotFound(executablePath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory.url
        }
        process.environment = Self.makeEnvironment(overrides: environment)
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collected = StreamCollector()
        let readersDone = DispatchGroup()
        let pipes = [(outPipe, false), (errPipe, true)]
        for (index, (pipe, isError)) in pipes.enumerated() {
            readersDone.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if collected.markReaderFinished(index) { readersDone.leave() }
                    return
                }
                collected.append(data, isError: isError)
                onOutput(String(decoding: data, as: UTF8.self), isError)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitCLIResult, Error>) in
                process.terminationHandler = { finished in
                    readersDone.notify(queue: .global()) {
                        Self.notifyIfMutating(arguments, workingDirectory: workingDirectory)
                        let (out, err) = collected.snapshot()
                        continuation.resume(returning: GitCLIResult(
                            exitCode: finished.terminationStatus,
                            standardOutputData: out,
                            standardError: String(decoding: err, as: UTF8.self)
                        ))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: GitCLIError.processCrash(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
            // A child git started (ssh, a hook) can keep the pipes open after git itself exits;
            // stop waiting for it shortly after an abort.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                for (index, (pipe, _)) in pipes.enumerated() where collected.markReaderFinished(index) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    readersDone.leave()
                }
            }
        }
    }

    /// Executes a Git CLI command in the specified working directory off the calling thread.
    public func run(
        arguments: [String],
        workingDirectory: PangolinPath? = nil,
        environment: [String: String]? = nil
    ) async throws -> GitCLIResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runSync(
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        environment: environment
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Executes git and returns standard output, throwing `GitCLIError.commandFailed` on a non-zero exit.
    public func runChecked(
        arguments: [String],
        workingDirectory: PangolinPath? = nil,
        environment: [String: String]? = nil
    ) async throws -> String {
        let result = try await run(arguments: arguments, workingDirectory: workingDirectory, environment: environment)
        return try Self.checked(result, arguments: arguments)
    }

    /// Synchronous convenience used throughout the dialogs: runs git with the default executable,
    /// returns standard output and throws on a non-zero exit. Call from a background context.
    @discardableResult
    public static func run(
        arguments: [String],
        workingDirectory: PangolinPath? = nil,
        environment: [String: String]? = nil
    ) throws -> String {
        let result = try GitCLIRunner().runSync(
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
        return try checked(result, arguments: arguments)
    }

    /// Async variant of `run(arguments:workingDirectory:environment:)` that executes git off the
    /// calling actor — use this from UI code so the main thread never waits on git.
    @discardableResult
    public static func runAsync(
        arguments: [String],
        workingDirectory: PangolinPath? = nil,
        environment: [String: String]? = nil
    ) async throws -> String {
        return try await GitCLIRunner().runChecked(
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }
    
    /// Like `runAsync`, but returns stdout as raw bytes (e.g. `git cat-file blob`).
    public static func runDataAsync(
        arguments: [String],
        workingDirectory: PangolinPath? = nil
    ) async throws -> Data {
        let result = try await GitCLIRunner().run(arguments: arguments, workingDirectory: workingDirectory)
        _ = try checked(result, arguments: arguments)
        return result.standardOutputData
    }
    
    /// Synchronous raw-bytes variant; call from a background context.
    public static func runData(
        arguments: [String],
        workingDirectory: PangolinPath? = nil
    ) throws -> Data {
        let result = try GitCLIRunner().runSync(arguments: arguments, workingDirectory: workingDirectory)
        _ = try checked(result, arguments: arguments)
        return result.standardOutputData
    }
    
    static func checked(_ result: GitCLIResult, arguments: [String]) throws -> String {
        guard result.isSuccess else {
            throw GitCLIError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines),
                command: commandLine(arguments)
            )
        }
        return result.standardOutput
    }

    /// `git <args>` with arguments quoted where needed, for error messages and the progress window.
    public static func commandLine(_ arguments: [String]) -> String {
        let quoted = arguments.map { arg -> String in
            guard arg.isEmpty || arg.contains(where: { " \"'$\\".contains($0) }) else { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return (["git"] + quoted).joined(separator: " ")
    }
}

/// Thread-safe accumulator for streamed stdout/stderr.
private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, isError: Bool) {
        lock.lock()
        if isError { err.append(data) } else { out.append(data) }
        lock.unlock()
    }

    private var finishedReaders = Set<Int>()

    /// True the first time reader `index` is marked finished, so the dispatch group is left once.
    func markReaderFinished(_ index: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishedReaders.insert(index).inserted
    }

    func snapshot() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (out, err)
    }
}
