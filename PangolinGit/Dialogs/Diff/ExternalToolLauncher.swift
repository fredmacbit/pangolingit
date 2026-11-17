import Cocoa
import PangolinGitCore

/// Starts the external diff viewer or merge tool configured in Settings ▸ Tools
/// (TortoiseGit's `CAppUtils::StartExtDiff`, `StartExtMerge`, `PickDiffTool`).
@MainActor
enum ExternalToolLauncher {

    /// True while ⌥ is held: TortoiseGit's Shift inverts the built-in/external choice.
    static var alternativeRequested: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    /// The external diff command line for `fileName`, or nil when the built-in viewer should be used.
    /// A per-extension entry always wins; otherwise the global tool is used when enabled (⌥ inverts).
    static func diffCommand(for fileName: String, alternative: Bool? = nil) -> String? {
        let alternative = alternative ?? alternativeRequested
        let config = ConfigManager.shared
        if let override = ExternalToolCommand.override(for: fileName, in: config.diffToolOverrides) { return override }
        guard !config.externalDiffTool.isEmpty else { return nil }
        guard config.useExternalDiffTool != alternative else { return nil }
        return quoted(config.externalDiffTool) + " " + config.externalDiffToolArgs
    }

    static func mergeCommand(for fileName: String, alternative: Bool? = nil) -> String? {
        let alternative = alternative ?? alternativeRequested
        let config = ConfigManager.shared
        if let override = ExternalToolCommand.override(for: fileName, in: config.mergeToolOverrides) { return override }
        guard !config.externalMergeTool.isEmpty else { return nil }
        guard config.useExternalMergeTool != alternative else { return nil }
        return quoted(config.externalMergeTool) + " " + config.externalMergeToolArgs
    }

    static var hasExternalDiffTool: Bool { !ConfigManager.shared.externalDiffTool.isEmpty }
    static var hasExternalMergeTool: Bool { !ConfigManager.shared.externalMergeTool.isEmpty }

    /// Launches a diff of two files; the old side is usually a temporary copy of a revision.
    static func launchDiff(commandLine: String, files: ExternalToolCommand.Files) {
        let argv = ExternalToolCommand.arguments(template: commandLine, kind: .diff, files: files)
        launch(argv, wait: false, workingDirectory: files.workingTreeRoot) { _ in }
    }

    /// Launches a merge tool. With `wait`, `completion` receives the exit status once the tool quits.
    static func launchMerge(commandLine: String, files: ExternalToolCommand.Files, wait: Bool,
                            completion: @escaping @MainActor (Int32?) -> Void) {
        let argv = ExternalToolCommand.arguments(template: commandLine, kind: .merge, files: files)
        launch(argv, wait: wait, workingDirectory: files.workingTreeRoot, completion: completion)
    }

    /// Opens `fileURL` in the alternative editor from Settings ▸ Tools, or the default app.
    static func openInAlternativeEditor(_ fileURL: URL) {
        let editor = ConfigManager.shared.alternativeEditor
        guard !editor.isEmpty else {
            NSWorkspace.shared.open(fileURL)
            return
        }
        launch([editor, fileURL.path], wait: false, workingDirectory: "") { _ in }
    }

    /// Runs `argv`. An `.app` bundle is started through `open -a` so it activates like a double-click;
    /// a bare command name is looked up on the user's PATH plus Homebrew's prefixes.
    static func launch(_ argv: [String], wait: Bool, workingDirectory: String,
                       completion: @escaping @MainActor (Int32?) -> Void) {
        guard let program = argv.first, !program.isEmpty else {
            completion(nil)
            return
        }
        let process = Process()
        if program.hasSuffix(".app") || program.hasSuffix(".app/") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n"] + (wait ? ["-W"] : []) + ["-a", program, "--args"] + argv.dropFirst()
        } else if let resolved = resolve(program) {
            process.executableURL = URL(fileURLWithPath: resolved)
            process.arguments = Array(argv.dropFirst())
        } else {
            showError("The program “\(program)” was not found. Check Settings ▸ Tools.")
            completion(nil)
            return
        }
        if !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        process.environment = environment
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if wait { completion(status) } }
            }
        }
        do {
            try process.run()
            if !wait { completion(nil) }
        } catch {
            showError("Could not start “\(program)”: \(error.localizedDescription)")
            completion(nil)
        }
    }

    private static var searchPath: [String] {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var path = inherited
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/Applications/Visual Studio Code.app/Contents/Resources/app/bin"]
        where !path.contains(extra) {
            path.append(extra)
        }
        return path
    }

    private static func resolve(_ program: String) -> String? {
        let expanded = (program as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        return searchPath.map { ($0 as NSString).appendingPathComponent(expanded) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Quotes a stored executable path so spaces survive word splitting.
    private static func quoted(_ path: String) -> String {
        path.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" })
            ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "External Tool"
        alert.informativeText = message
        alert.runModal()
    }
}
