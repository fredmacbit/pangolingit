import Foundation
import Cocoa
import PangolinGitCore

/// Commands accepted from the Finder extension (`pangolingit://<cmd>?path=…`), the main menu and the launcher.
/// Equivalent to TortoiseGit's `TortoiseProc.cpp` `/command:` switch.
public enum PangolinCommand: String, CaseIterable {
    case commit
    case add
    case diff
    case log
    case blame
    case pull
    case push
    case sync
    case clone
    case branch
    case checkout
    case `switch` = "switch"
    case merge
    case rebase
    case stash
    case changed
    case browseRefs = "browserefs"
    case revert
    case reset
    case worktree
    case submodule
    case patch
    case imageDiff = "imagediff"
    case ssh
    case stats
    case ignore
    case export
    case reflog
    case bisect
    case repoBrowser = "repobrowser"
    case remotes
    case firstRun = "firstrun"
    case settings
    case about
    case rename
    case remove
    case requestPull = "requestpull"
    case lfsLocks = "lfslocks"
    case fileDiff = "filediff"
    case diffPrevious = "diffprevious"
    case formatPatch = "formatpatch"
    case applyPatchSerial = "applypatchserial"
    case sendMail = "sendmail"
    case revisionGraph = "revisiongraph"
    case fetch
    case mergeBranch = "mergebranch"
    case cherryPick = "cherrypick"
    case stashPop = "stashpop"
    case stashApply = "stashapply"
    case stashList = "stashlist"
    case resolve
    case cleanup
    case abortMerge = "abortmerge"
    case deleteKeepLocal = "deletekeeplocal"
    case deleteAndIgnore = "deleteandignore"
    case removeFromIgnore = "removefromignore"
    case createRepo = "createrepo"
    case refresh
    case help
    // Integrations and platform (P9/P10).
    case daemon
    case lfsLock = "lfslock"
    case lfsUnlock = "lfsunlock"
    case svnFetch = "svnfetch"
    case svnRebase = "svnrebase"
    case svnDCommit = "svndcommit"
    case svnIgnore = "svnignore"
    case updateCheck = "updatecheck"

    /// Commands that make sense without a working tree.
    var worksOutsideRepository: Bool {
        switch self {
        case .clone, .ssh, .firstRun, .settings, .about, .imageDiff, .updateCheck:
            return true
        case .sendMail:
            // Patch files can be mailed from anywhere (TortoiseGit's Send Mail on any .patch file).
            return true
        case .createRepo, .refresh, .help:
            return true
        default:
            return false
        }
    }

    /// Commands that also work on a bare repository (TortoiseGit offers these for `ITEMIS_BAREREPO`).
    var worksOnBareRepository: Bool {
        switch self {
        case .log, .reflog, .browseRefs, .repoBrowser, .export, .push, .worktree:
            return true
        default:
            return false
        }
    }
}

@MainActor
public final class CommandRouter {
    public static let shared = CommandRouter()

    private init() {}

    /// Extra parameters of the request being dispatched (`rev`, `logmsg`, `closeonend`, `page`, …;
    /// TortoiseGitProc's `/key:value` switches). Set only while `execute` runs, so a dialog may read
    /// it from its initialiser; empty for menu and Finder requests without parameters.
    public private(set) var options = CommandOptions()

    /// Parses and routes `pangolingit://commit?path=/repo/a&path=/repo/b&rev=…`.
    public func handleURL(_ url: URL) {
        guard url.scheme == "pangolingit" else { return }
        guard let command = PangolinCommand(rawValue: url.host ?? "") else {
            PangolinLog.general.error("Unknown command URL: \(url.absoluteString, privacy: .public)")
            return
        }
        let requestOptions = CommandOptions(url: url)
        options = requestOptions
        defer { options = CommandOptions() }
        execute(command: command, paths: requestOptions.paths)
    }

    public func execute(command: PangolinCommand, targetPath: String) {
        execute(command: command, paths: targetPath.isEmpty ? [] : [targetPath])
    }

    /// Dispatches a command for the given selection (files or folders, possibly several).
    public func execute(command: PangolinCommand, paths: [String]) {
        let targets = paths.map { PangolinPath($0) }
        let target = targets.first
        let locations = target.flatMap { GitAdminDir.findRepository(startingAt: $0) }
        let root = locations.flatMap { $0.isBare && !command.worksOnBareRepository ? nil : $0.workingTreeRoot }

        if !command.worksOutsideRepository && root == nil {
            showNotARepositoryAlert(command: command, path: target)
            return
        }
        if let root {
            ConfigManager.shared.addRecentRepository(root.rawPath)
        }

        let registry = WindowRegistry.shared
        // One window per (command, repository); a second request just brings it forward.
        let key = "\(command.rawValue)|\(root?.rawPath ?? target?.rawPath ?? "")"
        let file = target ?? PangolinPath("/")
        let relative = root.flatMap { root in targets.compactMap { $0.relative(to: root) } } ?? []

        switch command {
        case .commit:
            registry.present({ CommitWindowController(repositoryPath: root!, selection: relative) }, key: key, repository: root)
        case .add:
            registry.present({ AddWindowController(repositoryPath: root!, selection: relative) }, key: key, repository: root)
        case .log:
            // Show Log on a file or folder limits the history to it (TortoiseGit passes /path).
            let logPath = relative.first.flatMap { $0.isEmpty ? nil : $0 }
            registry.present({ LogWindowController(repositoryPath: root!, path: logPath) }, key: "\(key)|\(logPath ?? "")", repository: root)
        case .diff:
            if targets.count == 2, !targets[0].isDirectory, !targets[1].isDirectory {
                // Two files selected: compare them with each other (TortoiseGit's Diff on two files).
                DiffWindowController.presentFiles(left: targets[0].url, right: targets[1].url)
            } else {
                DiffWindowController.present(filePath: file, repository: root)
            }
        case .blame:
            guard requireFile(file, command: command) else { return }
            registry.present({ BlameWindowController(filePath: file) }, key: "blame|\(file.rawPath)", repository: root)
        case .push:
            registry.present({ PushWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .pull:
            registry.present({ PullFetchWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .sync:
            registry.present({ SyncWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .clone:
            let directory = (target?.isDirectory ?? false) ? target!.rawPath : FileManager.default.homeDirectoryForCurrentUser.path
            registry.present({ CloneWindowController(initialDirectory: directory) })
        case .branch:
            registry.present({ CreateBranchTagWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .checkout, .switch:
            registry.present({ SwitchWindowController(repositoryPath: root!) }, key: "switch|\(root!.rawPath)", repository: root)
        case .stash:
            registry.present({ StashWindowController(repositoryPath: root!, paths: relative) }, key: key, repository: root)
        case .rebase:
            registry.present({ RebaseWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .merge:
            guard requireFile(file, command: command) else { return }
            MergeWindowController.present(file: file, repository: root)
        case .changed:
            registry.present({ ChangedFilesWindowController(repositoryPath: root!, selection: relative) }, key: key, repository: root)
        case .browseRefs:
            registry.present({ BrowseRefsWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .revert:
            registry.present({ RevertWindowController(repositoryPath: root!, selection: relative) }, key: key, repository: root)
        case .reset:
            registry.present({ ResetWindowController(repositoryPath: root!, paths: relative) }, key: key, repository: root)
        case .worktree:
            registry.present({ WorktreeWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .submodule:
            registry.present({ SubmoduleWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .patch:
            let patchFile = targets.first { ["patch", "diff"].contains($0.pathExtension.lowercased()) }?.url
            registry.present({ PatchWindowController(repositoryPath: root!, paths: patchFile == nil ? relative : [], patchFile: patchFile) },
                             key: key, repository: root)
        case .imageDiff:
            if let left = options.string("left"), let right = options.string("right") {
                // TortoiseGitIDiff /left /right (also `pangolin idiff --left … --right …`).
                registry.present({ ImageDiffWindowController(oldImageURL: URL(fileURLWithPath: left),
                                                             newImageURL: URL(fileURLWithPath: right)) })
            } else if let target, root != nil {
                // Working-tree image against HEAD.
                DiffWindowController.present(filePath: target, repository: root)
            } else {
                registry.present({ ImageDiffWindowController(oldImageURL: nil, newImageURL: target?.url) })
            }
        case .ssh:
            registry.present({ SSHKeyWindowController() }, key: "ssh")
        case .stats:
            registry.present({ StatisticsWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .ignore:
            registry.present({ IgnoreWindowController(repositoryPath: root!, relativeFilePaths: relative) }, repository: root)
        case .export:
            registry.present({ ExportWindowController(repositoryPath: root!, paths: relative) }, key: key, repository: root)
        case .reflog:
            registry.present({ RefLogWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .bisect:
            registry.present({ BisectWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .repoBrowser:
            registry.present({ RepoBrowserWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .remotes:
            registry.present({ RemotesWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .firstRun:
            registry.present({ FirstRunWindowController() }, key: "firstrun")
        case .settings:
            registry.present({ SettingsWindowController() }, key: "settings")
            if let page = options.page { SettingsWindowController.showPage(page) }
        case .about:
            AboutWindowController.show()
        case .rename:
            let sources = relative.filter { !$0.isEmpty }
            guard !sources.isEmpty else { return }
            registry.present({ RenameWindowController(repositoryPath: root!, sourceRelativePaths: sources) }, repository: root)
        case .remove:
            let selection = relative.filter { !$0.isEmpty }
            guard !selection.isEmpty else { return }
            registry.present({ RemoveWindowController(repositoryPath: root!, targetPaths: selection) }, repository: root)
        case .requestPull:
            registry.present({ RequestPullWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .lfsLocks:
            registry.present({ LFSLocksWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .fileDiff:
            registry.present({ FileDiffWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .diffPrevious:
            DiffWindowController.presentPrevious(filePath: file, repository: root!)
        case .formatPatch:
            registry.present({ FormatPatchWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .applyPatchSerial:
            let patches = targets.filter { !$0.isDirectory }.map(\.url)
            registry.present({ ApplyPatchSeriesWindowController(repositoryPath: root!, patches: patches) }, key: key, repository: root)
        case .sendMail:
            let patches = targets.filter { !$0.isDirectory }.map(\.url)
            SendMailWindowController.present(repository: root, patches: patches)
        case .revisionGraph:
            registry.present({ RevisionGraphWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .fetch:
            registry.present({ PullFetchWindowController(repositoryPath: root!, mode: .fetch) }, key: key, repository: root)
        case .mergeBranch:
            registry.present({ MergeBranchWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .cherryPick:
            registry.present({ CherryPickWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .stashPop:
            StashActions.apply(root!, pop: true)
        case .stashApply:
            StashActions.apply(root!, pop: false)
        case .stashList:
            registry.present({ RefLogWindowController(repositoryPath: root!, ref: "refs/stash") }, key: key, repository: root)
        case .resolve:
            registry.present({ ResolveWindowController(repositoryPath: root!, selection: relative) }, key: key, repository: root)
        case .cleanup:
            registry.present({ CleanupWindowController(repositoryPath: root!, selection: relative) }, key: key, repository: root)
        case .abortMerge:
            registry.present({ AbortMergeWindowController(repositoryPath: root!) }, key: key, repository: root)
        case .deleteKeepLocal:
            WorkingTreeOperations.deleteKeepLocal(relative.filter { !$0.isEmpty }, root: root!)
        case .deleteAndIgnore:
            DeleteAndIgnore.run(paths: relative, root: root!)
        case .removeFromIgnore:
            WorkingTreeOperations.removeFromIgnoreList(relative.filter { !$0.isEmpty }, root: root!)
        case .createRepo:
            let folder = (target?.isDirectory ?? false) ? target! : (target?.deletingLastPathComponent ?? PangolinPath(FileManager.default.homeDirectoryForCurrentUser.path))
            registry.present({ CreateRepoWindowController(folder: folder) }, key: "createrepo|\(folder.rawPath)")
        case .refresh:
            // Finder handles its own Refresh entry; this serves `pangolingit://refresh?path=…` from elsewhere.
            targets.forEach(StatusAgentClient.invalidate)
        case .help:
            NSWorkspace.shared.open(Self.helpURL)
        case .daemon, .lfsLock, .lfsUnlock, .svnFetch, .svnRebase, .svnDCommit, .svnIgnore, .updateCheck:
            IntegrationCommands.run(command, repository: root, selection: relative, options: options)
        }
    }

    private func requireFile(_ path: PangolinPath, command: PangolinCommand) -> Bool {
        guard path.isDirectory else { return true }
        let alert = NSAlert()
        alert.messageText = "Select a file"
        alert.informativeText = "“\(command.rawValue.capitalized)” works on a single file, not on the folder “\(path.filename)”."
        alert.runModal()
        return false
    }

    private func showNotARepositoryAlert(command: PangolinCommand, path: PangolinPath?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Not a Git working tree"
        alert.informativeText = path.map { "“\($0.rawPath)” is not inside a Git working tree." }
            ?? "Choose a repository first (File ▸ Open Repository…)."
        alert.runModal()
    }
}
