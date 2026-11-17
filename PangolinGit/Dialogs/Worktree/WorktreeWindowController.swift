import Foundation
import Cocoa
import PangolinGitCore

/// Worktree list (TortoiseGit's `WorktreeListDlg` / `WorktreeCreateDlg`): path, HEAD, branch,
/// lock state and reason; Add, Lock (with reason) / Unlock, Remove (offering *Force* when git
/// refuses), Prune, and Show in Finder / Log / Check for Modifications for a worktree.
public final class WorktreeWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {

    public let repositoryPath: PangolinPath

    private var worktrees: [GitWorktreeInfo] = []
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!

    public init(repositoryPath: PangolinPath) {
        self.repositoryPath = repositoryPath

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Worktrees — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 700, height: 320)

        super.init(window: window)
        setupUI()
        reload()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.reload() }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let container = window?.contentView else { return }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        for (id, title, width) in [("Path", "Path", 360.0), ("Hash", "Hash", 90.0), ("Branch", "Branch", 160.0),
                                   ("Locked", "Locked", 60.0), ("Reason", "Reason", 180.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            tableView.addTableColumn(column)
        }
        scroll.documentView = tableView

        statusLabel = NSTextField(labelWithString: "Loading worktrees…")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = ToolDialog.buttonRow([
            NSButton(title: "Add…", target: self, action: #selector(addWorktreeClicked)),
            NSButton(title: "Lock / Unlock…", target: self, action: #selector(toggleLockClicked)),
            NSButton(title: "Remove…", target: self, action: #selector(removeWorktreeClicked)),
            NSButton(title: "Prune", target: self, action: #selector(pruneClicked)),
            NSButton(title: "Close", target: self, action: #selector(closeClicked))
        ])
        buttons.insertView(statusLabel, at: 0, in: .leading)

        container.addSubview(scroll)
        container.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
    }

    private func reload() {
        let root = repositoryPath
        Task { @MainActor in
            do {
                let out = try await GitCLIRunner.runAsync(arguments: ["worktree", "list", "--porcelain"], workingDirectory: root)
                self.worktrees = GitWorktreeInfo.parse(porcelain: out)
                self.tableView.reloadData()
                let prunable = self.worktrees.filter(\.isPrunable).count
                self.statusLabel.stringValue = "\(self.worktrees.count) worktree(s)" + (prunable > 0 ? ", \(prunable) can be pruned" : "")
            } catch {
                self.statusLabel.stringValue = "Error loading worktrees: \(error.localizedDescription)"
            }
        }
    }

    private var selectedItem: GitWorktreeInfo? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        return row >= 0 && row < worktrees.count ? worktrees[row] : nil
    }

    // MARK: - Actions

    @objc private func addWorktreeClicked() {
        let root = repositoryPath
        WindowRegistry.shared.present({ WorktreeAddWindowController(repositoryPath: root) }, repository: root)
    }

    @objc private func toggleLockClicked() {
        guard let item = selectedItem else { return }
        guard !item.isMain else {
            ToolDialog.showMessage("Main worktree", "The main working tree cannot be locked.", in: window)
            return
        }
        if item.isLocked {
            ProgressWindowController.run(title: "Unlock Worktree", commands: [["worktree", "unlock", item.path]], workingDirectory: repositoryPath)
            return
        }
        // TortoiseGit asks for a lock reason (shown in the Reason column and by `git worktree list`).
        let alert = NSAlert()
        alert.messageText = "Lock Worktree"
        alert.informativeText = "Locking keeps “\(item.path)” from being pruned, moved or removed (e.g. on a removable disk)."
        let reason = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        reason.placeholderString = "Reason (optional)"
        alert.accessoryView = reason
        alert.addButton(withTitle: "Lock")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var args = ["worktree", "lock"]
        let text = reason.stringValue.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { args += ["--reason", text] }
        ProgressWindowController.run(title: "Lock Worktree", commands: [args + [item.path]], workingDirectory: repositoryPath)
    }

    @objc private func removeWorktreeClicked() {
        guard let item = selectedItem else { return }
        guard !item.isMain else {
            ToolDialog.showMessage("Main worktree", "The main working tree cannot be removed.", in: window)
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Remove worktree “\((item.path as NSString).lastPathComponent)”?"
        confirm.informativeText = "The folder “\(item.path)” is deleted. Its branch and commits stay in the repository."
            + (item.isLocked ? "\n\nThe worktree is locked\(item.lockReason.isEmpty ? "" : " (\(item.lockReason))"); it is removed anyway." : "")
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        // A locked worktree needs --force twice.
        let args = item.isLocked ? ["worktree", "remove", "--force", "--force", item.path] : ["worktree", "remove", item.path]
        let root = repositoryPath
        ProgressWindowController.run(title: "Remove Worktree", commands: [args], workingDirectory: root, postActions: { outcome in
            guard !outcome.succeeded else { return [] }
            // git refuses when the worktree has changes; TortoiseGit then offers a forced removal.
            return [.init("Force Remove") {
                ProgressWindowController.run(title: "Remove Worktree (force)", commands: [["worktree", "remove", "--force", item.path]],
                                             workingDirectory: root)
            }]
        })
    }

    @objc private func pruneClicked() {
        ProgressWindowController.run(title: "Prune Worktrees", commands: [["worktree", "prune", "-v"]], workingDirectory: repositoryPath)
    }

    @objc private func rowDoubleClicked() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < worktrees.count else { return }
        reveal(worktrees[tableView.clickedRow])
    }

    private func reveal(_ item: GitWorktreeInfo) {
        let url = URL(fileURLWithPath: item.path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            ToolDialog.showMessage("Folder missing", "“\(item.path)” no longer exists. Prune removes its administrative files.", in: window)
        }
    }

    @objc private func closeClicked() {
        window?.close()
    }

    // MARK: - NSTableViewDelegate & DataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        worktrees.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < worktrees.count else { return nil }
        let item = worktrees[row]
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("Path")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }()
        cell.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        cell.textColor = item.isPrunable ? .secondaryLabelColor : .labelColor
        switch id.rawValue {
        case "Path":
            cell.stringValue = item.isMain ? "\(item.path)  (main)" : item.path
            if item.isMain { cell.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) }
        case "Hash":
            cell.stringValue = String(item.head.prefix(8))
            cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        case "Branch":
            cell.stringValue = item.isBare ? "(bare)" : (item.branch ?? "(detached HEAD)")
        case "Locked":
            cell.stringValue = item.isLocked ? "Yes" : ""
            cell.textColor = .systemOrange
        default:
            cell.stringValue = item.isLocked ? item.lockReason : (item.isPrunable ? "Prunable: \(item.prunableReason)" : "")
            cell.textColor = .secondaryLabelColor
        }
        return cell
    }
}

extension WorktreeWindowController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = selectedItem else { return }
        let path = item.path
        menu.addItem(ClosureMenuItem(title: "Show in Finder", symbol: "folder") { [weak self] in self?.reveal(item) })
        menu.addItem(ClosureMenuItem(title: "Show Log", symbol: "clock.arrow.circlepath") {
            CommandRouter.shared.execute(command: .log, targetPath: path)
        })
        menu.addItem(ClosureMenuItem(title: "Check for Modifications", symbol: "doc.text.magnifyingglass") {
            CommandRouter.shared.execute(command: .changed, targetPath: path)
        })
        if !item.isMain {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: item.isLocked ? "Unlock" : "Lock…", symbol: item.isLocked ? "lock.open" : "lock") { [weak self] in
                self?.toggleLockClicked()
            })
            menu.addItem(ClosureMenuItem(title: "Remove…", symbol: "trash") { [weak self] in self?.removeWorktreeClicked() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Copy Path", symbol: "doc.on.clipboard") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        })
    }
}

/// *Create Worktree* (TortoiseGit's `WorktreeCreateDlg.cpp`): folder, base version (HEAD / branch /
/// tag / commit), optional new branch, Checkout, Force and Detach.
@MainActor
final class WorktreeAddWindowController: NSWindowController {

    private let repositoryPath: PangolinPath
    private let directoryField = NSTextField()
    private var chooser: RevisionChooserView!
    private let newBranchCheck = NSButton(checkboxWithTitle: "Create new branch:", target: nil, action: nil)
    private let branchField = NSTextField()
    private let checkoutCheck = NSButton(checkboxWithTitle: "Check out files (unchecked: --no-checkout)", target: nil, action: nil)
    private let forceCheck = NSButton(checkboxWithTitle: "Force (--force)", target: nil, action: nil)
    private let detachCheck = NSButton(checkboxWithTitle: "Detached HEAD (--detach)", target: nil, action: nil)

    init(repositoryPath: PangolinPath, base: String = "HEAD") {
        self.repositoryPath = repositoryPath
        super.init(window: ToolDialog.window(title: "Create Worktree", repository: repositoryPath, width: 600, height: 420, resizable: false))
        setupUI(base: base)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(base: String) {
        guard let content = window?.contentView else { return }
        // Suggest a sibling folder named after the repository, as `git worktree add ../repo-feature` is the usual layout.
        directoryField.stringValue = repositoryPath.deletingLastPathComponent.appendingPathComponent("\(repositoryPath.filename)-worktree").rawPath
        let browse = ClosureButton(title: "Browse…") { [weak self] in self?.browse() }
        browse.bezelStyle = .rounded
        directoryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        let directoryRow = NSStackView(views: [directoryField, browse])
        directoryRow.spacing = 6

        chooser = RevisionChooserView(repository: repositoryPath, initialRevision: base)
        chooser.onChange = { [weak self] in self?.suggestBranch() }
        let baseBox = NSBox()
        baseBox.title = "Base on"
        let boxContent = NSView()
        baseBox.contentView = boxContent
        boxContent.addSubview(chooser)
        NSLayoutConstraint.activate(LayoutHelper.pinEdges(chooser, to: boxContent, insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)))

        newBranchCheck.target = self
        newBranchCheck.action = #selector(optionsChanged)
        detachCheck.target = self
        detachCheck.action = #selector(optionsChanged)
        branchField.placeholderString = "feature/name"
        branchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let branchRow = NSStackView(views: [newBranchCheck, branchField])
        branchRow.spacing = 6
        checkoutCheck.state = .on

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Create", target: self, action: #selector(createClicked))
        ok.keyEquivalent = "\r"
        let buttons = ToolDialog.buttonRow([cancel, ok])

        let stack = NSStackView(views: [ToolDialog.label("Directory:", bold: true), directoryRow, baseBox, branchRow,
                                        checkoutCheck, detachCheck, forceCheck, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate(LayoutHelper.pinEdges(stack, to: content) + [
            baseBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        optionsChanged()
    }

    private func browse() {
        let panel = NSSavePanel()
        panel.title = "New Worktree Folder"
        panel.prompt = "Choose"
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: directoryField.stringValue).deletingLastPathComponent()
        panel.nameFieldStringValue = (directoryField.stringValue as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directoryField.stringValue = url.path
    }

    /// A remote branch as base suggests a local branch of the same name (only fills an empty field).
    private func suggestBranch() {
        let revision = chooser.revision
        guard branchField.stringValue.isEmpty, chooser.branches.contains(revision),
              let slash = revision.firstIndex(of: "/") else { return }
        let local = String(revision[revision.index(after: slash)...])
        guard !chooser.branches.contains(local) else { return }
        branchField.stringValue = local
    }

    @objc private func optionsChanged() {
        branchField.isEnabled = newBranchCheck.state == .on
        if newBranchCheck.state == .on { detachCheck.state = .off }
        newBranchCheck.isEnabled = detachCheck.state == .off
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func createClicked() {
        let directory = directoryField.stringValue.trimmingCharacters(in: .whitespaces)
        let base = chooser.revision
        guard !directory.isEmpty, !base.isEmpty else {
            ToolDialog.showMessage("Incomplete", "Choose a directory and the version to base the worktree on.", in: window, style: .warning)
            return
        }
        var args = ["worktree", "add"]
        if forceCheck.state == .on { args.append("--force") }
        if checkoutCheck.state == .off { args.append("--no-checkout") }
        if detachCheck.state == .on {
            args.append("--detach")
        } else if newBranchCheck.state == .on {
            let branch = branchField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !branch.isEmpty else {
                ToolDialog.showMessage("No branch name", "Enter the name of the new branch.", in: window, style: .warning)
                return
            }
            args += ["-b", branch]
        }
        args += ["--", directory, base]
        let root = repositoryPath
        window?.close()
        ProgressWindowController.run(title: "Create Worktree", commands: [args], workingDirectory: root, postActions: { outcome in
            guard outcome.succeeded else { return [] }
            return [
                .init("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: directory)) },
                .init("Show Log") { CommandRouter.shared.execute(command: .log, targetPath: directory) }
            ]
        })
    }
}
