import Cocoa
import PangolinGitCore

/// Right-click menu for status lists (the item menu of TortoiseGit's `CGitStatusListCtrl`):
/// conflict resolution, add (⌥ as executable), ignore, delete / delete (keep local) / delete and
/// ignore, revert, restore, changelists, local-change flags, LFS locks, diff and two-file compare,
/// blame, open / open with, reveal, export and copy. Works on one or several selected rows.
@MainActor
final class StatusListActions {

    private let repositoryRoot: PangolinPath
    /// Called with the repository-relative paths whose change was just staged (added or removed),
    /// so the commit dialog can check them.
    var didStage: (([String]) -> Void)?
    /// Changelist assignments of this repository (shared with the attached list).
    lazy var changelists = ChangelistStore(repositoryRoot: repositoryRoot)
    /// List that shows the changelist groups; regrouped after "Move to changelist".
    private weak var statusList: StatusListView?
    private lazy var usesLFS = GitRepository.open(at: repositoryRoot)?.usesLFS ?? false

    init(repositoryRoot: PangolinPath) {
        self.repositoryRoot = repositoryRoot
    }

    /// Connects a list: changelist groups, Size / Last Modified columns, remembered columns.
    /// - Parameter uncheckIgnoreOnCommit: leave `ignore-on-commit` files unchecked (Commit dialog).
    func attach(to list: StatusListView, autosaveName: String? = nil, uncheckIgnoreOnCommit: Bool = false) {
        statusList = list
        list.repositoryRoot = repositoryRoot
        list.changelists = changelists
        list.uncheckIgnoreOnCommit = uncheckIgnoreOnCommit
        if let autosaveName { list.autosaveName = autosaveName }
    }

    /// - Parameters:
    ///   - items: the rows the menu acts on.
    ///   - listed: every row in the list, used to offer adding a folder that holds several listed files.
    func menu(for items: [StatusListItem], listed: [StatusListItem]) -> NSMenu? {
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        let root = repositoryRoot
        let unversioned = items.filter { $0.status == .untracked }
        let ignored = items.filter { $0.status == .ignored }
        let missing = items.filter { $0.status == .missing }
        let conflicted = items.filter { $0.status == .conflicted || $0.info.isConflicted }
        let revertible = items.filter { ![.untracked, .ignored, .clean].contains($0.status) }
        // Rows git tracks in HEAD (not new, not gone): candidates for delete / flags / locks.
        let tracked = items.filter {
            ![.untracked, .ignored, .added, .missing, .deleted, .conflicted].contains($0.status) && $0.info.stagedStatus != .added && !$0.info.isConflicted
        }
        let suffix = { (list: [StatusListItem]) in list.count == 1 ? "" : " \(list.count) Items" }

        if !conflicted.isEmpty {
            addConflictItems(conflicted, to: menu)
            menu.addItem(.separator())
        }

        if !unversioned.isEmpty {
            let title = unversioned.count == 1 ? "Add" : "Add \(unversioned.count) Items"
            menu.addItem(ClosureMenuItem(title: title, symbol: "plus.circle") { [weak self] in
                self?.stage(unversioned.map(\.path), adding: true)
            })
            // ⌥: TortoiseGit's Shift variant "Add (as executable)".
            menu.addItem(Self.alternate(ClosureMenuItem(title: title + " as Executable", symbol: "terminal") { [weak self] in
                self?.stage(unversioned.map(\.path), adding: true, executable: true)
            }))
            addFolderItems(for: unversioned, listed: listed, to: menu)
            menu.addItem(ignoreMenuItem(title: "Add to Ignore List", symbol: "eye.slash", items: unversioned, target: .gitignore))
            menu.addItem(ignoreMenuItem(title: "Add to Local Exclude List (Not Committed)", symbol: "eye.slash.circle",
                                        items: unversioned, target: .localExclude))
            menu.addItem(.separator())
        }

        if !ignored.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Remove from Ignore List" + suffix(ignored), symbol: "eye") {
                WorkingTreeOperations.removeFromIgnoreList(ignored.map(\.path), root: root)
            })
            menu.addItem(.separator())
        }

        if !missing.isEmpty {
            let paths = missing.map(\.path)
            menu.addItem(ClosureMenuItem(title: "Remove from Repository" + suffix(missing), symbol: "trash") { [weak self] in
                self?.stage(paths, adding: false)
            })
            menu.addItem(ClosureMenuItem(title: "Restore" + suffix(missing), symbol: "arrow.uturn.backward") { [weak self] in
                self?.restore(paths)
            })
            menu.addItem(.separator())
        }

        if !revertible.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Revert…", symbol: "arrow.uturn.backward.circle") {
                WorkingTreeOperations.revert(revertible.map(\.info), root: root)
            })
        }
        if !tracked.isEmpty {
            let paths = tracked.map(\.path)
            menu.addItem(ClosureMenuItem(title: "Delete (Keep Local)" + suffix(tracked), symbol: "minus.circle") {
                WorkingTreeOperations.deleteKeepLocal(paths, root: root)
            })
            menu.addItem(ClosureMenuItem(title: "Delete and Add to Ignore List…", symbol: "eye.slash") {
                DeleteAndIgnore.run(paths: paths, root: root)
            })
        }
        let removable = unversioned + ignored
        if !removable.isEmpty {
            let paths = removable.map(\.path)
            menu.addItem(ClosureMenuItem(title: "Delete" + suffix(removable), symbol: "trash") {
                WorkingTreeOperations.deleteUnversioned(paths, root: root, permanently: false)
            })
            // ⌥ bypasses the Trash, like Shift+Delete in TortoiseGit.
            menu.addItem(Self.alternate(ClosureMenuItem(title: "Delete Permanently" + suffix(removable), symbol: "trash.slash") {
                WorkingTreeOperations.deleteUnversioned(paths, root: root, permanently: true)
            }))
        }
        if menu.items.last.map({ !$0.isSeparatorItem }) ?? false {
            menu.addItem(.separator())
        }

        addViewItems(for: items, to: menu)
        menu.addItem(.separator())
        menu.addItem(changelistMenuItem(for: items))
        if !tracked.isEmpty {
            menu.addItem(flagMenuItem(for: tracked))
            if usesLFS {
                let paths = tracked.map(\.path)
                menu.addItem(ClosureMenuItem(title: "LFS Lock" + suffix(tracked), symbol: "lock") {
                    WorkingTreeOperations.lfs(lock: true, paths: paths, root: root)
                })
                menu.addItem(ClosureMenuItem(title: "LFS Unlock" + suffix(tracked), symbol: "lock.open") {
                    WorkingTreeOperations.lfs(lock: false, paths: paths, root: root)
                })
            }
        }
        menu.addItem(.separator())
        addFileItems(for: items, to: menu)
        return menu
    }

    // MARK: - Menu sections

    /// Edit conflicts / Resolved / Resolve using mine / theirs, labelled with the branch names.
    private func addConflictItems(_ conflicted: [StatusListItem], to menu: NSMenu) {
        let root = repositoryRoot
        let paths = conflicted.map(\.path)
        let names = GitRepository.open(at: root)?.conflictSideNames() ?? GitConflictSideNames(mine: "mine", theirs: "theirs")
        if conflicted.count == 1 {
            menu.addItem(ClosureMenuItem(title: "Edit Conflicts", symbol: "exclamationmark.triangle") {
                let file = root.appending(paths[0])
                WindowRegistry.shared.present({ MergeWindowController(targetFile: file) }, key: "merge|\(file.rawPath)", repository: root)
            })
        }
        menu.addItem(ClosureMenuItem(title: "Resolved", symbol: "checkmark.circle") {
            WorkingTreeOperations.resolve(paths, side: nil, root: root)
        })
        menu.addItem(ClosureMenuItem(title: "Resolve Conflict Using \u{201C}Theirs\u{201D} (\(names.theirs))") {
            WorkingTreeOperations.resolve(paths, side: .theirs, root: root)
        })
        menu.addItem(ClosureMenuItem(title: "Resolve Conflict Using \u{201C}Mine\u{201D} (\(names.mine))") {
            WorkingTreeOperations.resolve(paths, side: .mine, root: root)
        })
    }

    /// Diff, two-file compare and blame.
    private func addViewItems(for items: [StatusListItem], to menu: NSMenu) {
        let root = repositoryRoot
        if items.count == 1, let item = items.first, item.status != .untracked, item.status != .deleted, item.status != .missing {
            menu.addItem(ClosureMenuItem(title: "Show Diff", symbol: "plusminus") {
                CommandRouter.shared.execute(command: .diff, targetPath: root.appending(item.path).rawPath)
            })
        }
        let existingFiles = items.filter { !$0.info.isDirectory && FileManager.default.fileExists(atPath: root.appending($0.path).rawPath) }
        if items.count == 2, existingFiles.count == 2 {
            menu.addItem(ClosureMenuItem(title: "Compare Two Files", symbol: "rectangle.split.2x1") {
                WorkingTreeOperations.compareTwoFiles(existingFiles[0].path, existingFiles[1].path, root: root)
            })
        }
        if items.count == 1, let item = items.first, ![.untracked, .ignored, .added].contains(item.status), item.info.stagedStatus != .added,
           !item.info.isDirectory, !item.info.isSubmodule {
            menu.addItem(ClosureMenuItem(title: "Blame", symbol: "person.text.rectangle") {
                let file = root.appending(item.path)
                WindowRegistry.shared.present({ BlameWindowController(filePath: file) }, key: "blame|\(file.rawPath)", repository: root)
            })
        }
    }

    /// Open, Open With, Show in Finder, Export, Copy.
    private func addFileItems(for items: [StatusListItem], to menu: NSMenu) {
        let root = repositoryRoot
        let existing = items.map(\.path).filter { FileManager.default.fileExists(atPath: root.appending($0).rawPath) }
        if !existing.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Open", symbol: "arrow.up.forward.app") {
                WorkingTreeOperations.open(existing, root: root)
            })
            if let openWith = WorkingTreeOperations.openWithMenu(existing, root: root) {
                let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                item.submenu = openWith
                menu.addItem(item)
            }
            menu.addItem(ClosureMenuItem(title: "Show in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(existing.map { root.appending($0).url })
            })
            menu.addItem(ClosureMenuItem(title: "Export Selection To…", symbol: "square.and.arrow.up") {
                WorkingTreeOperations.exportSelection(existing, root: root)
            })
        }
        let copyMenu = NSMenu()
        for variant in WorkingTreeOperations.CopyVariant.allCases {
            copyMenu.addItem(ClosureMenuItem(title: variant.title) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(WorkingTreeOperations.clipboardText(items, variant: variant, root: root), forType: .string)
            })
        }
        let copyItem = NSMenuItem(title: items.count == 1 ? "Copy Path" : "Copy Paths", action: nil, keyEquivalent: "")
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyItem.submenu = copyMenu
        menu.addItem(copyItem)
    }

    /// Move to changelist ▸ (new / existing / ignore-on-commit), Remove from changelist.
    private func changelistMenuItem(for items: [StatusListItem]) -> NSMenuItem {
        let paths = items.map(\.path)
        let store = changelists
        let submenu = NSMenu()
        submenu.addItem(ClosureMenuItem(title: "New Changelist…") { [weak self] in
            guard let name = Self.askChangelistName() else { return }
            store.move(paths, to: name)
            self?.statusList?.reloadChangelists()
        })
        var names = store.names
        if !names.contains(ChangelistStore.ignoreOnCommit) { names.append(ChangelistStore.ignoreOnCommit) }
        submenu.addItem(.separator())
        for name in names {
            let item = ClosureMenuItem(title: name) { [weak self] in
                store.move(paths, to: name)
                self?.statusList?.reloadChangelists()
            }
            item.state = items.allSatisfy({ $0.changelist == name }) ? .on : .off
            submenu.addItem(item)
        }
        if items.contains(where: { $0.changelist != nil }) {
            submenu.addItem(.separator())
            submenu.addItem(ClosureMenuItem(title: "Remove from Changelist") { [weak self] in
                store.remove(paths)
                self?.statusList?.reloadChangelists()
            })
        }
        let item = NSMenuItem(title: "Move to Changelist", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tray.2", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    /// Assume unchanged / Skip worktree / Unflag (TortoiseGit's "ignore local changes" flags).
    private func flagMenuItem(for items: [StatusListItem]) -> NSMenuItem {
        let root = repositoryRoot
        let paths = items.map(\.path)
        let submenu = NSMenu()
        for flag in [GitLocalChangeFlag.skipWorktree, .assumeUnchanged] {
            let item = ClosureMenuItem(title: flag.title) {
                WorkingTreeOperations.setFlag(flag, paths: paths, root: root)
            }
            item.state = items.allSatisfy({ $0.flag == flag }) ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(ClosureMenuItem(title: "Unflag") {
            WorkingTreeOperations.setFlag(nil, paths: paths, root: root)
        })
        let item = NSMenuItem(title: "Ignore Local Changes", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "flag", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    private static func askChangelistName() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Changelist"
        alert.informativeText = "Name of the changelist:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Turns `item` into the ⌥ alternate of the item added just before it.
    private static func alternate(_ item: NSMenuItem) -> NSMenuItem {
        item.isAlternate = true
        item.keyEquivalentModifierMask = .option
        return item
    }

    // MARK: - Add / remove / restore

    /// "Add Folder" entries for folders of the selection that hold more than one listed unversioned file.
    private func addFolderItems(for unversioned: [StatusListItem], listed: [StatusListItem], to menu: NSMenu) {
        let listedUnversioned = listed.filter { $0.status == .untracked }.map(\.path)
        // Innermost folder first: that is usually the one meant.
        let folders = Self.containingFolders(of: unversioned.map(\.path)).reversed()
        var offered = 0
        for folder in folders where offered < 5 {
            let contained = listedUnversioned.filter { $0.hasPrefix(folder + "/") }
            guard contained.count > 1 else { continue }
            menu.addItem(ClosureMenuItem(title: "Add Folder \u{201C}\(folder)/\u{201D} (\(contained.count) files)", symbol: "folder.badge.plus") { [weak self] in
                self?.stage([folder], adding: true, reported: contained)
            })
            offered += 1
        }
    }

    /// Adds (`git add`, optionally marked executable) or removes from the index (`git rm --cached`) the given paths.
    private func stage(_ paths: [String], adding: Bool, executable: Bool = false, reported: [String]? = nil) {
        guard let repo = GitRepository.open(at: repositoryRoot) else { return }
        Task { @MainActor in
            do {
                if adding {
                    try await repo.add(paths: paths)
                    if executable {
                        try await GitCLIRunner.runAsync(arguments: ["update-index", "--chmod=+x", "--"] + paths, workingDirectory: self.repositoryRoot)
                    }
                } else {
                    try await repo.removeFromIndex(paths: paths)
                }
                self.didStage?(reported ?? paths)
                RepositoryEvents.post(self.repositoryRoot)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func restore(_ paths: [String]) {
        guard let repo = GitRepository.open(at: repositoryRoot) else { return }
        Task { @MainActor in
            do {
                try await repo.restoreFromIndex(paths: paths)
                RepositoryEvents.post(self.repositoryRoot)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - Ignore

    private func ignoreMenuItem(title: String, symbol: String, items: [StatusListItem], target: GitIgnoreFile.Target) -> NSMenuItem {
        let submenu = NSMenu()
        let paths = items.map(\.path)
        let files = paths.filter { !$0.hasSuffix("/") }
        let parents = Self.unique(files.map(Self.parentFolder))
        let inSubfolder = parents.contains { !$0.isEmpty }

        func add(_ title: String, _ patterns: [String]) {
            submenu.addItem(ClosureMenuItem(title: title) { [weak self] in self?.ignore(Self.unique(patterns), target: target) })
        }

        // By name. Untracked folders (listed as "dir/") are ignored as folders.
        submenu.addItem(Self.header("File Name"))
        let exact = paths.map { $0.hasSuffix("/") ? GitIgnoreFile.folderPattern(forFolder: $0) : GitIgnoreFile.exactPattern(forPath: $0) }
        if paths.count == 1 {
            let name = (paths[0] as NSString).lastPathComponent
            add("\(paths[0]) \u{2014} This File Only", exact)
            if !files.isEmpty {
                if inSubfolder {
                    add("\(name) \u{2014} In Folder \(parents[0])/", [GitIgnoreFile.namePattern(forPath: files[0], inFolder: parents[0])])
                }
                add("\(name) \u{2014} Anywhere in Repository", [GitIgnoreFile.namePattern(forPath: files[0])])
            }
        } else {
            add("These \(paths.count) Items Only", exact)
            if !files.isEmpty {
                if inSubfolder {
                    add("Same Names \u{2014} In Their Folders",
                        files.map { GitIgnoreFile.namePattern(forPath: $0, inFolder: Self.parentFolder($0)) })
                }
                add("Same Names \u{2014} Anywhere in Repository", files.map { GitIgnoreFile.namePattern(forPath: $0) })
            }
        }

        // By extension: per distinct extension, in the folder(s) of those files or repository-wide.
        var extensions: [String] = []
        for file in files {
            let ext = (file as NSString).pathExtension
            if !ext.isEmpty && !extensions.contains(ext) { extensions.append(ext) }
        }
        if !extensions.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(Self.header("Extension"))
            for ext in extensions.prefix(6) {
                let withExt = files.filter { ($0 as NSString).pathExtension == ext }
                let extFolders = Self.unique(withExt.map(Self.parentFolder)).filter { !$0.isEmpty }
                if !extFolders.isEmpty {
                    let place = extFolders.count == 1 ? "In Folder \(extFolders[0])/" : "In Their Folders"
                    add("*.\(ext) \u{2014} \(place)", extFolders.compactMap { GitIgnoreFile.extensionPattern(forPath: "x.\(ext)", inFolder: $0) })
                }
                add("*.\(ext) \u{2014} Anywhere in Repository", [GitIgnoreFile.extensionPattern(forPath: "x.\(ext)")].compactMap { $0 })
            }
        }

        // By folder: every folder the selection lives in, outermost first.
        let folders = Self.containingFolders(of: paths)
        if !folders.isEmpty {
            submenu.addItem(.separator())
            submenu.addItem(Self.header("Whole Folder"))
            for folder in folders.prefix(8) {
                add("\(folder)/", [GitIgnoreFile.folderPattern(forFolder: folder)])
            }
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    private func ignore(_ patterns: [String], target: GitIgnoreFile.Target) {
        do {
            try GitIgnoreFile.append(patterns, to: target, repositoryRoot: repositoryRoot)
            RepositoryEvents.post(repositoryRoot)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Helpers

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return .sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Repository-relative folder of `path`; "" at the root.
    static func parentFolder(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Distinct ancestor folders of the given repository-relative paths, shortest first.
    static func containingFolders(of paths: [String]) -> [String] {
        var folders = Set<String>()
        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            components.removeLast()
            for depth in stride(from: components.count, to: 0, by: -1) {
                folders.insert(components[0..<depth].joined(separator: "/"))
            }
        }
        return folders.sorted { ($0.count, $0) < ($1.count, $1) }
    }
}

/// Menu item that runs a closure; status-list menus are built per click, so items carry their own action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}
