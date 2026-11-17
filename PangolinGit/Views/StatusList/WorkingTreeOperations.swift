import Cocoa
import PangolinGitCore

/// File operations shared by the status-list menu, the Finder commands and the Revert / Resolve /
/// Delete dialogs (TortoiseGit implements these in `CGitStatusListCtrl` and `CAppUtils`). Mutating
/// git commands run in the progress window, which also refreshes open windows and Finder badges.
@MainActor
enum WorkingTreeOperations {

    /// "Commit…" follow-up button for a progress window.
    static func commitAction(_ root: PangolinPath) -> ProgressWindowController.PostAction {
        ProgressWindowController.PostAction("Commit…") {
            CommandRouter.shared.execute(command: .commit, targetPath: root.rawPath)
        }
    }

    // MARK: - Trash

    /// Moves repository-relative paths to the Trash (TortoiseGit uses the Recycle Bin). Returns the
    /// paths that could not be moved, with the reason.
    @discardableResult
    static func trash(_ paths: [String], root: PangolinPath) -> [(String, Error)] {
        var failures: [(String, Error)] = []
        for path in paths {
            let url = root.appending(path).url
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failures.append((path, error))
            }
        }
        return failures
    }

    /// Deletes the paths permanently.
    @discardableResult
    static func deletePermanently(_ paths: [String], root: PangolinPath) -> [(String, Error)] {
        var failures: [(String, Error)] = []
        for path in paths {
            do {
                try FileManager.default.removeItem(at: root.appending(path).url)
            } catch {
                failures.append((path, error))
            }
        }
        return failures
    }

    static func reportFailures(_ failures: [(String, Error)], action: String) {
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(action) failed for \(failures.count) item(s)"
        alert.informativeText = failures.prefix(10).map { "\($0.0): \($0.1.localizedDescription)" }.joined(separator: "\n")
        alert.runModal()
    }

    // MARK: - Revert

    /// Reverts `items` after confirmation (TortoiseGit's Revert): warns about conflicted files, moves
    /// the working-tree files that get overwritten to the Trash when that setting is on, and runs the
    /// restore in the progress window.
    static func revert(_ items: [GitItemStatusInfo], root: PangolinPath, submodules: Bool = false,
                       onFinish: ((Bool) -> Void)? = nil) {
        let revertible = items.filter { ![.untracked, .ignored, .clean].contains($0.status) }
        guard !revertible.isEmpty else { return }
        let conflicted = revertible.filter { $0.isConflicted || $0.status == .conflicted }
        let useTrash = ConfigManager.shared.useTrashOnRevert

        if ConfigManager.shared.confirmOnRevert || !conflicted.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = conflicted.isEmpty ? .warning : .critical
            alert.messageText = revertible.count == 1 ? "Revert “\(revertible[0].path)”?" : "Revert \(revertible.count) files?"
            var text = useTrash
                ? "Local changes are discarded; the current files are moved to the Trash first."
                : "Local changes are discarded permanently."
            if !conflicted.isEmpty {
                text += "\n\n\(conflicted.count) conflicted file(s) will be reset to HEAD, dropping both sides of the conflict:\n"
                    + conflicted.prefix(8).map { "• " + $0.path }.joined(separator: "\n")
            }
            alert.informativeText = text
            alert.addButton(withTitle: "Revert")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        if useTrash {
            // Trash a copy so git can still restore the file in place.
            let failures = trashCopies(GitRepository.filesOverwrittenByRevert(revertible), root: root)
            reportFailures(failures, action: "Moving to the Trash")
        }

        let hasHead = GitRepository.open(at: root)?.hasHead ?? true
        var commands = GitRepository.revertCommands(for: revertible, hasHead: hasHead)
        let submodulePaths = revertible.filter(\.isSubmodule).map(\.path)
        if submodules && !submodulePaths.isEmpty {
            commands.append(["submodule", "update", "--init", "--recursive", "--"] + submodulePaths)
        }
        ProgressWindowController.run(title: "Revert", commands: commands, workingDirectory: root,
                                     onFinish: { outcome in onFinish?(outcome.succeeded) })
    }

    /// Copies files into the Trash, leaving the originals in place.
    private static func trashCopies(_ paths: [String], root: PangolinPath) -> [(String, Error)] {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinGit-Revert-\(UUID().uuidString)")
        var failures: [(String, Error)] = []
        for path in paths {
            let source = root.appending(path).url
            let copy = staging.appendingPathComponent(path)
            do {
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: copy)
                try FileManager.default.trashItem(at: copy, resultingItemURL: nil)
            } catch {
                failures.append((path, error))
            }
        }
        try? FileManager.default.removeItem(at: staging)
        return failures
    }

    // MARK: - Resolve

    /// Resolves conflicted paths: with a side, takes that side's version; without, marks the files
    /// resolved as they are (TortoiseGit's *Resolved* / *Resolve using mine/theirs*).
    static func resolve(_ paths: [String], side: GitConflictSide?, root: PangolinPath, onFinish: (() -> Void)? = nil) {
        guard !paths.isEmpty, let repo = GitRepository.open(at: root) else { return }
        let commands = side.map { repo.resolveCommands(paths: paths, side: $0) } ?? [GitRepository.markResolvedCommand(paths: paths)]
        ProgressWindowController.run(title: "Resolve", commands: commands, workingDirectory: root, postActions: { outcome in
            guard outcome.succeeded else { return [] }
            // Commit once nothing is left to resolve.
            let remaining = (try? repo.status())?.contains { $0.isConflicted } ?? false
            return remaining ? [] : [commitAction(root)]
        }, onFinish: { _ in onFinish?() })
    }

    // MARK: - Delete

    /// "Delete (keep local)": removes the paths from version control and leaves the files on disk.
    static func deleteKeepLocal(_ paths: [String], root: PangolinPath) {
        guard !paths.isEmpty else { return }
        ProgressWindowController.run(title: "Delete (Keep Local)", commands: [["rm", "-r", "--cached", "--"] + paths],
                                     workingDirectory: root, postActions: { $0.succeeded ? [commitAction(root)] : [] })
    }

    /// Deletes unversioned or ignored files from disk: to the Trash, or permanently.
    static func deleteUnversioned(_ paths: [String], root: PangolinPath, permanently: Bool) {
        guard !paths.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = permanently ? .critical : .warning
        alert.messageText = paths.count == 1 ? "Delete “\(paths[0])”?" : "Delete \(paths.count) items?"
        alert.informativeText = permanently
            ? "The files are deleted permanently. They are not under version control and cannot be restored."
            : "The files are moved to the Trash."
        alert.addButton(withTitle: permanently ? "Delete Permanently" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let failures = permanently ? deletePermanently(paths, root: root) : trash(paths, root: root)
        reportFailures(failures, action: "Delete")
        RepositoryEvents.post(root)
    }

    // MARK: - Ignore list

    /// "Remove from ignore list": finds the rule that ignores each path and removes it, or, when the
    /// rule is a broad pattern, adds an exception (`!/path`) to the root `.gitignore` instead.
    static func removeFromIgnoreList(_ paths: [String], root: PangolinPath) {
        guard let repo = GitRepository.open(at: root) else { return }
        let matches: [GitIgnoreMatch]
        do {
            matches = try repo.ignoreMatches(paths: paths)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        guard !matches.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Not ignored"
            alert.informativeText = "No ignore rule matches the selected item(s)."
            alert.runModal()
            return
        }
        // A rule that names exactly the path can simply go; anything broader also un-ignores other files.
        let exact = matches.allSatisfy { match in
            let bare = match.pattern.hasSuffix("/") ? String(match.pattern.dropLast()) : match.pattern
            let path = match.path.hasSuffix("/") ? String(match.path.dropLast()) : match.path
            return bare == "/" + GitIgnoreFile.escape(path) || bare == GitIgnoreFile.escape(path)
        }
        let alert = NSAlert()
        alert.messageText = "Remove from Ignore List"
        alert.informativeText = "These rules ignore the selection:\n"
            + matches.prefix(10).map { "• \($0.pattern)   (\($0.source):\($0.lineNumber))" }.joined(separator: "\n")
            + (exact ? "" : "\n\nRemoving a rule also un-ignores other files it matches. An exception un-ignores only the selection.")
        alert.addButton(withTitle: exact ? "Remove Rules" : "Add Exception")
        alert.addButton(withTitle: "Cancel")
        if !exact { alert.addButton(withTitle: "Remove Rules") }
        let response = alert.runModal()
        let removeRules = (exact && response == .alertFirstButtonReturn) || (!exact && response == .alertThirdButtonReturn)
        let addException = !exact && response == .alertFirstButtonReturn
        do {
            if removeRules {
                // Remove bottom-up per file so earlier line numbers stay valid.
                var linesByFile: [String: Set<Int>] = [:]
                for match in matches { linesByFile[match.source, default: []].insert(match.lineNumber) }
                for (source, lines) in linesByFile {
                    let url = source.hasPrefix("/") ? URL(fileURLWithPath: source) : root.appending(source).url
                    for line in lines.sorted(by: >) {
                        try GitIgnoreFile.removeLine(line, from: url)
                    }
                }
            } else if addException {
                try GitIgnoreFile.append(matches.map { GitIgnoreFile.exceptionPattern(forPath: $0.path) }, to: .gitignore, repositoryRoot: root)
            } else {
                return
            }
            RepositoryEvents.post(root)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Flags and LFS

    /// Sets (or clears) assume-unchanged / skip-worktree on tracked files.
    static func setFlag(_ flag: GitLocalChangeFlag?, paths: [String], root: PangolinPath) {
        ProgressWindowController.run(title: flag.map { "Mark \($0.title)" } ?? "Unflag",
                                     commands: GitRepository.flagCommands(flag, paths: paths), workingDirectory: root)
    }

    static func lfs(lock: Bool, paths: [String], root: PangolinPath) {
        ProgressWindowController.run(title: lock ? "LFS Lock" : "LFS Unlock",
                                     commands: paths.map { ["lfs", lock ? "lock" : "unlock", $0] }, workingDirectory: root)
    }

    // MARK: - Open / export / compare

    static func open(_ paths: [String], root: PangolinPath) {
        for path in paths {
            NSWorkspace.shared.open(root.appending(path).url)
        }
    }

    /// "Open With" submenu listing the applications that can open the first file.
    static func openWithMenu(_ paths: [String], root: PangolinPath) -> NSMenu? {
        guard let first = paths.first else { return nil }
        let urls = paths.map { root.appending($0).url }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: urls[0])
        guard !apps.isEmpty else { return nil }
        let menu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: root.appending(first).url)
        for app in apps.prefix(20) {
            var title = FileManager.default.displayName(atPath: app.path)
            if app == defaultApp { title += " (default)" }
            let item = ClosureMenuItem(title: title) {
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Other…") {
            let panel = NSOpenPanel()
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            guard panel.runModal() == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        })
        return menu
    }

    /// "Export selection to…": copies the working-tree files into a chosen folder, keeping their
    /// repository-relative folders.
    static func exportSelection(_ paths: [String], root: PangolinPath) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose the folder to copy the \(paths.count) selected item(s) to."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let fm = FileManager.default
        let existing = paths.filter { fm.fileExists(atPath: destination.appendingPathComponent($0).path) }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace \(existing.count) existing item(s)?"
            alert.informativeText = existing.prefix(8).joined(separator: "\n")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var failures: [(String, Error)] = []
        for path in paths {
            let source = root.appending(path).url
            let target = destination.appendingPathComponent(path)
            guard fm.fileExists(atPath: source.path) else { continue }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: source, to: target)
            } catch {
                failures.append((path, error))
            }
        }
        reportFailures(failures, action: "Export")
        if failures.count < paths.count {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    /// "Compare two files": diffs two working-tree files with each other (`git diff --no-index`).
    static func compareTwoFiles(_ first: String, _ second: String, root: PangolinPath) {
        Task { @MainActor in
            let result = try? await GitCLIRunner().run(arguments: ["diff", "--no-index", "--no-color", "--no-ext-diff", "--", first, second],
                                                       workingDirectory: root)
            let text = result?.standardOutput ?? ""
            WindowRegistry.shared.present({
                TwoFileDiffWindowController(title: "\(first) ↔ \(second)", unifiedDiff: text.isEmpty ? "The files are identical." : text)
            })
        }
    }

    // MARK: - Clipboard

    enum CopyVariant: CaseIterable {
        case fullPaths, relativePaths, fileNames, allInformation

        var title: String {
            switch self {
            case .fullPaths: return "Full Paths"
            case .relativePaths: return "Relative Paths"
            case .fileNames: return "File Names"
            case .allInformation: return "All Information"
            }
        }
    }

    /// Clipboard text for the rows (TortoiseGit's *Copy to clipboard* submenu).
    static func clipboardText(_ items: [StatusListItem], variant: CopyVariant, root: PangolinPath) -> String {
        items.map { item in
            switch variant {
            case .fullPaths: return root.appending(item.path).rawPath
            case .relativePaths: return item.path
            case .fileNames: return (item.path as NSString).lastPathComponent
            case .allInformation:
                var fields = [item.statusText, item.path]
                if let original = item.info.originalPath { fields.append("from \(original)") }
                if let count = item.lineCount { fields.append("+\(count.added.map(String.init) ?? "-") -\(count.removed.map(String.init) ?? "-")") }
                if let changelist = item.changelist { fields.append(changelist) }
                return fields.joined(separator: "\t")
            }
        }.joined(separator: "\n")
    }
}

/// Small window showing a unified diff side by side, for "Compare two files".
final class TwoFileDiffWindowController: NSWindowController {
    init(title: String, unifiedDiff: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        let diffView = SideBySideDiffView()
        window.contentView = diffView
        super.init(window: window)
        diffView.setDiff(rawUnifiedText: unifiedDiff)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
