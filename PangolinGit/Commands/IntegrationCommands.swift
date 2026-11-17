import Cocoa
import PangolinGitCore

/// Commands of the integrations area: LFS lock/unlock on a selection, Git daemon, git-svn and the
/// update check (TortoiseGit's `LFSCommands.cpp`, `DaemonCommand.cpp`, `SVN*Command.cpp`,
/// `UpdateCheckCommand.cpp`).
@MainActor
enum IntegrationCommands {

    static func run(_ command: PangolinCommand, repository: PangolinPath?, selection: [String], options: CommandOptions) {
        switch command {
        case .lfsLock, .lfsUnlock:
            guard let repository else { return }
            setLocked(command == .lfsLock, repository: repository, paths: selection.filter { !$0.isEmpty },
                      force: options.bool("force"))
        case .daemon:
            guard let repository else { return }
            DaemonWindowController.start(repository: repository)
        case .svnFetch, .svnRebase, .svnDCommit, .svnIgnore:
            guard let repository else { return }
            Task { await runSVN(command, repository: repository) }
        case .updateCheck:
            UpdateChecker.shared.checkForUpdates(userInitiated: options.values["visible"] != "0")
        default:
            break
        }
    }

    // MARK: - LFS (LF-01)

    /// Locks or unlocks the selected files (`LFSSetLockedProgressCommand`). Without a file selection
    /// the Locks dialog opens instead. A failed unlock offers *Force Unlock*; a successful lock offers
    /// *Pull…* so the locked file is up to date, as TortoiseGit does.
    static func setLocked(_ lock: Bool, repository: PangolinPath, paths: [String], force: Bool) {
        let files = paths.filter { path in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: repository.url.appendingPathComponent(path).path, isDirectory: &isDirectory)
                return !isDirectory.boolValue
            }
        guard !files.isEmpty else {
            WindowRegistry.shared.present({ LFSLocksWindowController(repositoryPath: repository) },
                                          key: "lfslocks|\(repository.rawPath)", repository: repository)
            return
        }
        ProgressWindowController.run(
            title: lock ? "LFS Lock" : (force ? "LFS Force Unlock" : "LFS Unlock"),
            commands: GitLFS.setLockedCommands(paths: files, lock: lock, force: force),
            workingDirectory: repository,
            postActions: { outcome in
                if lock && outcome.succeeded {
                    return [.init("Pull…") { CommandRouter.shared.execute(command: .pull, targetPath: repository.rawPath) }]
                }
                if !lock && !outcome.succeeded && !outcome.cancelled && !force {
                    return [.init("Force Unlock") {
                        guard confirmForceUnlock(paths: files) else { return }
                        setLocked(false, repository: repository, paths: files, force: true)
                    }]
                }
                return []
            })
    }

    /// Asks before breaking somebody else's lock; the answer can be remembered.
    static func confirmForceUnlock(paths: [String]) -> Bool {
        if StoredDecisions.shared.decision(for: StoredDecisions.Key.lfsForceUnlock) == 1 { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Force unlock?"
        alert.informativeText = "The lock on \(paths.count == 1 ? "“\(paths[0])”" : "\(paths.count) files") may belong to somebody else. "
            + "Breaking it can make them lose work."
        alert.addButton(withTitle: "Force Unlock")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let proceed = alert.runModal() == .alertFirstButtonReturn
        if proceed, alert.suppressionButton?.state == .on {
            StoredDecisions.shared.store(1, for: StoredDecisions.Key.lfsForceUnlock)
        }
        return proceed
    }

    // MARK: - git-svn (SV-01)

    /// Whether the repository was cloned with git-svn (an `svn-remote.*` section exists).
    static func isSVNRepository(_ repository: PangolinPath) async -> Bool {
        let output = try? await GitCLIRunner.runAsync(arguments: ["config", "--get-regexp", "^svn-remote\\."],
                                                       workingDirectory: repository)
        return !(output ?? "").isEmpty
    }

    private static func runSVN(_ command: PangolinCommand, repository: PangolinPath) async {
        guard await isSVNRepository(repository) else {
            let alert = NSAlert()
            alert.messageText = "Not a git-svn repository"
            alert.informativeText = "“\(repository.filename)” has no svn-remote configuration. Clone it with git svn first."
            alert.runModal()
            return
        }
        switch command {
        case .svnFetch:
            ProgressWindowController.run(title: "SVN Fetch", commands: [["svn", "fetch"]], workingDirectory: repository)
        case .svnRebase:
            await runWithAutoStash(title: "SVN Rebase", command: ["svn", "rebase"], repository: repository)
        case .svnDCommit:
            guard let rmdir = await askDCommitType(repository: repository) else { return }
            var arguments = ["svn", "dcommit"]
            if let rmdir { arguments.append(rmdir ? "--rmdir" : "--no-rmdir") }
            await runWithAutoStash(title: "SVN DCommit", command: arguments, repository: repository)
        case .svnIgnore:
            importSVNIgnore(repository: repository)
        default:
            break
        }
    }

    /// git svn refuses to rebase/dcommit with local changes; like TortoiseGit, offer to stash them
    /// first and pop them afterwards.
    private static func runWithAutoStash(title: String, command: [String], repository: PangolinPath) async {
        let dirty = (try? await GitCLIRunner.runAsync(arguments: ["status", "--porcelain", "--untracked-files=no"],
                                                       workingDirectory: repository)) ?? ""
        var commands = [command]
        var stashed = false
        if !dirty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let alert = NSAlert()
            alert.messageText = "The working tree has local changes"
            alert.informativeText = "\(title) needs a clean working tree. Stash the changes now and re-apply them afterwards?"
            alert.addButton(withTitle: "Stash and Continue")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            commands = [["stash", "push", "-m", "PangolinGit: before \(title)"], command, ["stash", "pop"]]
            stashed = true
        }
        ProgressWindowController.run(title: title, commands: commands, workingDirectory: repository,
                                     postActions: { outcome in
            guard !outcome.succeeded, stashed else { return [] }
            // The run stopped before `stash pop`; let the user get the changes back.
            return [.init("Stash Pop") {
                ProgressWindowController.run(title: "Stash Pop", commands: [["stash", "pop"]], workingDirectory: repository)
            }]
        })
    }

    /// TortoiseGit's `SVNDCommitDlg`: keep or remove directories that become empty. Remembering the
    /// choice writes `svn.rmdir`, which git svn reads itself, and skips the question next time.
    /// Returns nil to cancel, `.some(nil)` when the stored setting applies.
    private static func askDCommitType(repository: PangolinPath) async -> Bool?? {
        let stored = (try? await GitCLIRunner.runAsync(arguments: ["config", "--get", "svn.rmdir"], workingDirectory: repository))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return .some(nil) }

        let alert = NSAlert()
        alert.messageText = "SVN DCommit"
        alert.informativeText = "What should happen to directories that become empty in Subversion?"
        alert.addButton(withTitle: "Remove Empty Directories")
        alert.addButton(withTitle: "Keep Empty Directories")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice for this repository (svn.rmdir)"
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return nil }
        let rmdir = response == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on {
            _ = try? await GitCLIRunner.runAsync(arguments: ["config", "svn.rmdir", rmdir ? "true" : "false"],
                                                  workingDirectory: repository)
        }
        return .some(rmdir)
    }

    /// TortoiseGit's `SVNIgnoreCommand`: import `svn:ignore` as `.gitignore` files (`git svn create-ignore`)
    /// or into `.git/info/exclude` (`git svn show-ignore`).
    private static func importSVNIgnore(repository: PangolinPath) {
        let alert = NSAlert()
        alert.messageText = "Import svn:ignore"
        alert.informativeText = "Where should the Subversion ignore rules go?"
        alert.addButton(withTitle: ".gitignore Files")
        alert.addButton(withTitle: "info/exclude")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ProgressWindowController.run(title: "SVN Ignore", commands: [["svn", "create-ignore"]], workingDirectory: repository)
        case .alertSecondButtonReturn:
            Task {
                do {
                    let rules = try await GitCLIRunner.runAsync(arguments: ["svn", "show-ignore"], workingDirectory: repository)
                    let excludePath = try await GitCLIRunner.runAsync(arguments: ["rev-parse", "--git-path", "info/exclude"],
                                                                      workingDirectory: repository)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = excludePath.hasPrefix("/") ? URL(fileURLWithPath: excludePath)
                        : repository.url.appendingPathComponent(excludePath)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
                    try (existing + separator + rules).write(to: url, atomically: true, encoding: .utf8)
                    RepositoryEvents.post(repository)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        default:
            break
        }
    }
}
