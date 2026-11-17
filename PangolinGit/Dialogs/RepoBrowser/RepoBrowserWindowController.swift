import Foundation
import Cocoa
import UniformTypeIdentifiers
import PangolinGitCore

/// Repository browser (TortoiseGit's `RepositoryBrowser.cpp`): a folder tree on the left and the
/// selected folder's contents on the right, at any revision chosen with the `…` picker. Files can
/// be opened, compared with the working tree, blamed, saved, reverted, diffed against a marked
/// file and dragged to Finder; submodule entries open their own log.
public final class RepoBrowserWindowController: NSWindowController, NSOutlineViewDelegate, NSOutlineViewDataSource,
                                                NSTableViewDataSource, NSTableViewDelegate {

    public let repositoryPath: PangolinPath

    public final class TreeNode {
        public let name: String
        public let fullPath: String
        public let mode: String
        public let type: String
        public let sha: String
        public let size: String
        public let isDirectory: Bool
        public var children: [TreeNode] = []

        public init(name: String, fullPath: String, mode: String, type: String, sha: String, size: String, isDirectory: Bool) {
            self.name = name
            self.fullPath = fullPath
            self.mode = mode
            self.type = type
            self.sha = sha
            self.size = size
            self.isDirectory = isDirectory
        }

        var isSubmodule: Bool { type == "commit" }
        var folders: [TreeNode] { children.filter(\.isDirectory) }
    }

    /// Synthetic root so the tree shows the repository itself as the top folder.
    private var root = TreeNode(name: "", fullPath: "", mode: "040000", type: "tree", sha: "", size: "-", isDirectory: true)
    private var currentFolder: TreeNode?
    private var listing: [TreeNode] = []
    private var revision = "HEAD"
    /// *Mark for Diff* (TortoiseGit): the file compared against by *Diff with marked*.
    private var marked: (revision: String, path: String)?

    private let revisionField = NSTextField()
    private let folderOutline = NSOutlineView()
    private let fileTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Ready")

    public init(repositoryPath: PangolinPath, initialRevision: String = "HEAD") {
        self.repositoryPath = repositoryPath

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Repository Browser — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 700, height: 420)

        super.init(window: window)
        setupUI(initialRevision: initialRevision)
        loadTree(revision: initialRevision)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(initialRevision: String) {
        guard let container = window?.contentView else { return }

        revisionField.stringValue = initialRevision
        revisionField.target = self
        revisionField.action = #selector(goClicked)
        revisionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let picker = RevisionPickerButton(repository: repositoryPath) { [weak self] revision in
            self?.revisionField.stringValue = revision
            self?.loadTree(revision: revision)
        }
        let go = NSButton(title: "Go", target: self, action: #selector(goClicked))
        go.bezelStyle = .rounded
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refresh.bezelStyle = .rounded
        refresh.keyEquivalent = "r"
        refresh.keyEquivalentModifierMask = .command
        let topBar = NSStackView(views: [ToolDialog.label("Revision:"), revisionField, picker, go, refresh])
        topBar.spacing = 6
        topBar.translatesAutoresizingMaskIntoConstraints = false

        // Folder tree
        let folderColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Folder"))
        folderColumn.title = "Folders"
        folderOutline.addTableColumn(folderColumn)
        folderOutline.outlineTableColumn = folderColumn
        folderOutline.headerView = nil
        folderOutline.delegate = self
        folderOutline.dataSource = self
        folderOutline.menu = NSMenu()
        folderOutline.menu?.delegate = self
        let folderScroll = NSScrollView()
        folderScroll.hasVerticalScroller = true
        folderScroll.documentView = folderOutline

        // File list
        for (id, title, width, key) in [("Name", "Name", 300.0, "name"), ("Ext", "Extension", 80.0, "ext"),
                                        ("Size", "Size", 90.0, "size"), ("Mode", "Mode", 70.0, "mode"), ("SHA", "Object", 110.0, "sha")] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            fileTable.addTableColumn(column)
        }
        fileTable.allowsMultipleSelection = true
        fileTable.usesAlternatingRowBackgroundColors = true
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.target = self
        fileTable.doubleAction = #selector(fileDoubleClicked)
        fileTable.menu = NSMenu()
        fileTable.menu?.delegate = self
        fileTable.setDraggingSourceOperationMask(.copy, forLocal: false)
        let fileScroll = NSScrollView()
        fileScroll.hasVerticalScroller = true
        fileScroll.documentView = fileTable

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(folderScroll)
        split.addArrangedSubview(fileScroll)
        folderScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let save = NSButton(title: "Save As…", target: self, action: #selector(saveFileAsClicked))
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        let buttons = ToolDialog.buttonRow([save, close])
        buttons.insertView(statusLabel, at: 0, in: .leading)

        [topBar, split, buttons].forEach(container.addSubview)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            split.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            split.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        DispatchQueue.main.async { split.setPosition(260, ofDividerAt: 0) }
    }

    private func loadTree(revision: String) {
        statusLabel.stringValue = "Loading the tree of \(revision)…"
        let root = repositoryPath
        Task { @MainActor in
            do {
                let out = try await GitCLIRunner.runAsync(arguments: ["ls-tree", "-r", "-t", "-l", "-z", revision], workingDirectory: root)
                let nodes = await Task.detached { Self.buildTree(fromLsTree: out) }.value
                let previousFolder = self.currentFolder?.fullPath ?? ""
                self.revision = revision
                self.root = TreeNode(name: root.filename, fullPath: "", mode: "040000", type: "tree", sha: "", size: "-", isDirectory: true)
                self.root.children = nodes
                self.folderOutline.reloadData()
                self.folderOutline.expandItem(self.root)
                self.window?.title = "Repository Browser — \(root.filename) @ \(revision)"
                self.showFolder(self.folder(at: previousFolder) ?? self.root)
            } catch {
                self.statusLabel.stringValue = "Tree error: \(error.localizedDescription)"
            }
        }
    }

    /// Builds the folder hierarchy from `git ls-tree -r -t -l -z` output (folders first, then files, by name).
    static func buildTree(fromLsTree output: String) -> [TreeNode] {
        var folders: [String: TreeNode] = [:]
        var roots: [TreeNode] = []

        /// The node for a folder path, created (with its parents) if `ls-tree` did not list it.
        func folder(_ path: String) -> TreeNode {
            if let existing = folders[path] { return existing }
            let node = TreeNode(name: (path as NSString).lastPathComponent, fullPath: path, mode: "040000",
                                type: "tree", sha: "", size: "-", isDirectory: true)
            folders[path] = node
            attach(node)
            return node
        }

        func attach(_ node: TreeNode) {
            let parent = (node.fullPath as NSString).deletingLastPathComponent
            if parent.isEmpty {
                roots.append(node)
            } else {
                folder(parent).children.append(node)
            }
        }

        // -z: NUL-terminated records, paths are not quoted. Format: <mode> <type> <object> <size>\t<path>
        for record in output.components(separatedBy: "\0") where !record.isEmpty {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let meta = record[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            guard meta.count >= 4 else { continue }
            let path = String(record[record.index(after: tab)...])
            let type = String(meta[1])
            let node = TreeNode(name: (path as NSString).lastPathComponent, fullPath: path, mode: String(meta[0]),
                                type: type, sha: String(meta[2]), size: String(meta[3]), isDirectory: type == "tree")
            if node.isDirectory {
                // ls-tree -t lists a folder before its contents; keep children added by an earlier placeholder.
                if let placeholder = folders[path] {
                    node.children = placeholder.children
                    if let index = roots.firstIndex(where: { $0 === placeholder }) {
                        roots[index] = node
                    } else if let parent = folders[(path as NSString).deletingLastPathComponent],
                              let index = parent.children.firstIndex(where: { $0 === placeholder }) {
                        parent.children[index] = node
                    }
                    folders[path] = node
                } else {
                    folders[path] = node
                    attach(node)
                }
            } else {
                attach(node)
            }
        }

        func sort(_ nodes: [TreeNode]) -> [TreeNode] {
            for node in nodes where node.isDirectory {
                node.children = sort(node.children)
            }
            return nodes.sorted {
                $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return sort(roots)
    }

    private func folder(at path: String) -> TreeNode? {
        guard !path.isEmpty else { return root }
        var node = root
        for component in path.split(separator: "/") {
            guard let next = node.folders.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    private func showFolder(_ folder: TreeNode) {
        currentFolder = folder
        listing = folder.children
        applySort()
        let row = folderOutline.row(forItem: folder)
        if row >= 0, folderOutline.selectedRow != row {
            folderOutline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let files = listing.filter { !$0.isDirectory }.count
        statusLabel.stringValue = "\(folder.fullPath.isEmpty ? "/" : folder.fullPath) — \(listing.count - files) folder(s), \(files) file(s) at \(revision)"
    }

    private func applySort() {
        let descriptor = fileTable.sortDescriptors.first
        let ascending = descriptor?.ascending ?? true
        let key = descriptor?.key ?? "name"
        listing.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: Bool
            switch key {
            case "size": order = (Int(a.size) ?? -1) < (Int(b.size) ?? -1)
            case "ext": order = (a.name as NSString).pathExtension.localizedStandardCompare((b.name as NSString).pathExtension) == .orderedAscending
            case "mode": order = a.mode < b.mode
            case "sha": order = a.sha < b.sha
            default: order = a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? order : !order
        }
        fileTable.reloadData()
    }

    @objc private func goClicked() {
        let rev = revisionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rev.isEmpty {
            loadTree(revision: rev)
        }
    }

    /// F5 / Cmd-R in TortoiseGit's browser.
    @objc private func refreshClicked() {
        loadTree(revision: revision)
    }

    @objc private func closeClicked() {
        window?.close()
    }

    // MARK: - File actions

    /// Rows the context menu acts on: the selection, or the clicked row when it is not selected.
    private var actionNodes: [TreeNode] {
        if let outlineMenuNode { return [outlineMenuNode] }
        var rows = fileTable.selectedRowIndexes
        if fileTable.clickedRow >= 0, !rows.contains(fileTable.clickedRow) {
            rows = IndexSet(integer: fileTable.clickedRow)
        }
        return rows.compactMap { $0 < listing.count ? listing[$0] : nil }
    }
    private var outlineMenuNode: TreeNode?

    @objc private func fileDoubleClicked() {
        guard fileTable.clickedRow >= 0, fileTable.clickedRow < listing.count else { return }
        let node = listing[fileTable.clickedRow]
        if node.isDirectory {
            // The current folder is visible in the tree, so expanding it reveals the child to select.
            folderOutline.expandItem(currentFolder)
            showFolder(node)
        } else if node.isSubmodule {
            showLog(of: node)
        } else {
            open(node, with: nil)
        }
    }

    /// Writes a blob to a temporary file named like the original (TortoiseGit opens a temp copy).
    private func extract(_ node: TreeNode) async throws -> URL {
        let data = try await GitCLIRunner.runDataAsync(arguments: ["cat-file", "blob", node.sha], workingDirectory: repositoryPath)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinGit-RepoBrowser", isDirectory: true)
            .appendingPathComponent(String(node.sha.prefix(12)), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(node.name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func open(_ node: TreeNode, with application: URL?) {
        Task { @MainActor in
            do {
                let url = try await self.extract(node)
                if let application {
                    NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration(),
                                            completionHandler: nil)
                } else {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                ToolDialog.showError(error, in: self.window)
            }
        }
    }

    private func openWith(_ node: TreeNode) {
        let panel = NSOpenPanel()
        panel.title = "Open “\(node.name)” With"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(node, with: app)
    }

    private func showLog(of node: TreeNode) {
        // Submodules are repositories of their own; other paths open the repository log.
        let target = node.isSubmodule ? repositoryPath.appendingPathComponent(node.fullPath) : repositoryPath
        CommandRouter.shared.execute(command: .log, targetPath: target.rawPath)
    }

    @objc private func saveFileAsClicked() {
        save(actionNodes.filter { !$0.isDirectory && !$0.isSubmodule })
    }

    /// One file: Save panel; several: choose a folder (TortoiseGit's *Save as…* for multiple files).
    private func save(_ nodes: [TreeNode]) {
        guard !nodes.isEmpty else { return }
        var targets: [(TreeNode, URL)] = []
        if nodes.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = nodes[0].name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            targets = [(nodes[0], url)]
        } else {
            guard let folder = ToolDialog.chooseFolder(title: "Save \(nodes.count) Files To", initial: nil) else { return }
            targets = nodes.map { ($0, folder.appendingPathComponent($0.name)) }
        }
        let root = repositoryPath
        Task { @MainActor in
            do {
                for (node, url) in targets {
                    let data = try await GitCLIRunner.runDataAsync(arguments: ["cat-file", "blob", node.sha], workingDirectory: root)
                    try data.write(to: url, options: .atomic)
                }
                NSWorkspace.shared.activateFileViewerSelecting(targets.map(\.1))
            } catch {
                ToolDialog.showError(error, in: self.window)
            }
        }
    }

    /// *Revert to this revision*: checks the selected paths out of the browsed revision.
    private func revertToRevision(_ nodes: [TreeNode]) {
        let paths = nodes.map(\.fullPath).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revert \(paths.count == 1 ? "“\(paths[0])”" : "\(paths.count) items") to \(revision)?"
        alert.informativeText = "The working tree and index get the content from \(revision); local changes to these paths are lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ProgressWindowController.run(title: "Revert to \(revision)", commands: [["checkout", revision, "--"] + paths], workingDirectory: repositoryPath)
    }

    /// Unified diff of the marked file against `node` (both at their own revisions).
    private func diffWithMarked(_ node: TreeNode) {
        guard let marked else { return }
        let args = ["diff", "\(marked.revision):\(marked.path)", "\(revision):\(node.fullPath)"]
        let root = repositoryPath
        Task { @MainActor in
            do {
                let data = try await GitCLIRunner.runDataAsync(arguments: args, workingDirectory: root)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinGit-Diff", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("\(node.name)-vs-marked.diff")
                try data.write(to: url, options: .atomic)
                PatchViewerWindowController.present(url)
            } catch {
                ToolDialog.showError(error, in: self.window)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Folder outline

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? TreeNode else { return root.children.isEmpty && root.name.isEmpty ? 0 : 1 }
        return node.folders.count
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? TreeNode)?.folders.isEmpty == false
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? TreeNode else { return root }
        return node.folders[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FolderCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.iconCell(id)
        cell.textField?.stringValue = node === root ? repositoryPath.filename : node.name
        cell.imageView?.image = NSImage(systemSymbolName: node === root ? "externaldrive" : "folder", accessibilityDescription: nil)
        return cell
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = folderOutline.item(atRow: folderOutline.selectedRow) as? TreeNode, node !== currentFolder else { return }
        showFolder(node)
    }

    private static func iconCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        [image, text].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview($0)
        }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    // MARK: - File table

    public func numberOfRows(in tableView: NSTableView) -> Int {
        listing.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < listing.count else { return nil }
        let node = listing[row]
        let colId = tableColumn?.identifier.rawValue ?? ""
        if colId == "Name" {
            let id = NSUserInterfaceItemIdentifier("NameCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? Self.iconCell(id)
            cell.textField?.stringValue = node.name
            if node.isSubmodule {
                cell.imageView?.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "Submodule")
            } else if node.isDirectory {
                cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            } else {
                cell.imageView?.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data)
            }
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("Text_\(colId)")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.textColor = .secondaryLabelColor
            return field
        }()
        switch colId {
        case "Ext":
            cell.stringValue = node.isDirectory || node.isSubmodule ? "" : (node.name as NSString).pathExtension
        case "Size":
            cell.stringValue = Int(node.size).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
            cell.alignment = .right
        case "Mode":
            cell.stringValue = node.mode
            cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        default:
            cell.stringValue = String(node.sha.prefix(10))
            cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        return cell
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applySort()
    }

    /// Drag files to Finder: the blob is written when the drop happens (`NSFilePromiseProvider`).
    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < listing.count else { return nil }
        let node = listing[row]
        guard !node.isDirectory, !node.isSubmodule else { return nil }
        let type = UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = node
        return provider
    }
}

extension RepoBrowserWindowController: NSFilePromiseProviderDelegate {
    public func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? TreeNode)?.name ?? "file"
    }

    public func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                    completionHandler: @escaping (Error?) -> Void) {
        guard let node = filePromiseProvider.userInfo as? TreeNode else {
            completionHandler(nil)
            return
        }
        do {
            let data = try GitCLIRunner.runData(arguments: ["cat-file", "blob", node.sha], workingDirectory: repositoryPath)
            try data.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    public func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }
}

extension RepoBrowserWindowController: NSMenuDelegate {
    /// TortoiseGit's repository-browser context menu.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        outlineMenuNode = nil
        if menu === folderOutline.menu {
            guard folderOutline.clickedRow >= 0, let node = folderOutline.item(atRow: folderOutline.clickedRow) as? TreeNode else { return }
            outlineMenuNode = node
        }
        let nodes = actionNodes
        guard let first = nodes.first else { return }
        let root = repositoryPath
        let revision = self.revision
        let files = nodes.filter { !$0.isDirectory && !$0.isSubmodule }

        if nodes.count == 1 && files.count == 1 {
            menu.addItem(ClosureMenuItem(title: "Open", symbol: "doc") { [weak self] in self?.open(first, with: nil) })
            menu.addItem(ClosureMenuItem(title: "Open With…", symbol: "arrow.up.forward.app") { [weak self] in self?.openWith(first) })
            menu.addItem(ClosureMenuItem(title: "Compare with Working Tree", symbol: "arrow.left.arrow.right") {
                DiffWindowController.present(filePath: root.appendingPathComponent(first.fullPath), oldRevision: revision, newRevision: nil, repository: root)
            })
            menu.addItem(ClosureMenuItem(title: "Blame", symbol: "person.text.rectangle") {
                let file = root.appendingPathComponent(first.fullPath)
                WindowRegistry.shared.present({ BlameWindowController(filePath: file, revision: revision) },
                                              key: "blame|\(revision)|\(file.rawPath)", repository: root)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Mark for Diff", symbol: "pin") { [weak self] in self?.marked = (revision, first.fullPath) })
            if let marked, marked.path != first.fullPath || marked.revision != revision {
                menu.addItem(ClosureMenuItem(title: "Diff with “\((marked.path as NSString).lastPathComponent)” (\(marked.revision))",
                                             symbol: "arrow.left.arrow.right") { [weak self] in self?.diffWithMarked(first) })
            }
            menu.addItem(.separator())
        }
        if first.isSubmodule || nodes.count == 1 {
            menu.addItem(ClosureMenuItem(title: first.isSubmodule ? "Show Log of Submodule" : "Show Log", symbol: "clock.arrow.circlepath") { [weak self] in
                self?.showLog(of: first)
            })
        }
        if !files.isEmpty {
            menu.addItem(ClosureMenuItem(title: files.count == 1 ? "Save As…" : "Save \(files.count) Files To…", symbol: "square.and.arrow.down") { [weak self] in
                self?.save(files)
            })
        }
        if nodes.contains(where: \.isDirectory) {
            let folders = nodes.filter(\.isDirectory).map(\.fullPath)
            menu.addItem(ClosureMenuItem(title: "Export…", symbol: "square.and.arrow.up") {
                WindowRegistry.shared.present({ ExportWindowController(repositoryPath: root, revision: revision, paths: folders) }, repository: root)
            })
        }
        if !nodes.contains(where: { $0.fullPath.isEmpty }) {
            menu.addItem(ClosureMenuItem(title: "Revert to This Revision…", symbol: "arrow.uturn.backward") { [weak self] in
                self?.revertToRevision(nodes)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Copy Path", symbol: "doc.on.clipboard") { [weak self] in
            self?.copy(nodes.map(\.fullPath).joined(separator: "\n"))
        })
        menu.addItem(ClosureMenuItem(title: "Copy Object Hash", symbol: "number") { [weak self] in
            self?.copy(nodes.map(\.sha).joined(separator: "\n"))
        })
    }
}
