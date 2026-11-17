import Foundation
import Cocoa
import PangolinGitCore

/// Submodule management (TortoiseGit's submodule commands: `SubmoduleAddDlg`, `SubmoduleUpdateDlg`,
/// *Submodule Sync*, removal, *Show log of submodule*, `SubmoduleDiffDlg`).
/// Lists path / commit / state / branch / URL; Add, Update, Sync, Deinit and Remove act on the
/// selection, and the context menu opens the submodule's log, diff, commit and Finder folder.
public final class SubmoduleWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {

    public let repositoryPath: PangolinPath

    private var submodules: [GitSubmoduleInfo] = []
    private var tableView: NSTableView!
    private var statusLabel: NSTextField!

    public init(repositoryPath: PangolinPath) {
        self.repositoryPath = repositoryPath

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Submodules — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 700, height: 350)

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
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        for (id, title, width) in [("Path", "Path", 220.0), ("Commit", "Commit", 90.0), ("Status", "State", 120.0),
                                   ("Branch", "Branch", 100.0), ("URL", "Remote URL", 300.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            tableView.addTableColumn(column)
        }
        scroll.documentView = tableView

        statusLabel = NSTextField(labelWithString: "Loading submodules…")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = ToolDialog.buttonRow([
            NSButton(title: "Add…", target: self, action: #selector(addSubmoduleClicked)),
            NSButton(title: "Update…", target: self, action: #selector(updateSubmodulesClicked)),
            NSButton(title: "Sync", target: self, action: #selector(syncSubmodulesClicked)),
            NSButton(title: "Deinit…", target: self, action: #selector(deinitSubmoduleClicked)),
            NSButton(title: "Remove…", target: self, action: #selector(removeSubmoduleClicked)),
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

    /// `git submodule status` merged with `.gitmodules` (url / branch).
    static func loadSubmodules(_ root: PangolinPath) async -> [GitSubmoduleInfo] {
        let status = (try? await GitCLIRunner.runAsync(arguments: ["submodule", "status"], workingDirectory: root)) ?? ""
        // .gitmodules may be absent; URLs are then simply unknown
        let config = (try? await GitCLIRunner.runAsync(
            arguments: ["config", "-f", ".gitmodules", "--get-regexp", "^submodule\\..*\\.(url|path|branch)$"],
            workingDirectory: root
        )) ?? ""
        return GitSubmoduleInfo.parse(status: status, gitmodules: config)
    }

    private func reload() {
        let root = repositoryPath
        Task { @MainActor in
            let items = await Self.loadSubmodules(root)
            let selected = Set(self.selectedItems.map(\.path))
            self.submodules = items
            self.tableView.reloadData()
            let rows = IndexSet(items.enumerated().filter { selected.contains($0.element.path) }.map(\.offset))
            self.tableView.selectRowIndexes(rows, byExtendingSelection: false)
            self.statusLabel.stringValue = items.isEmpty ? "This repository has no submodules." : "\(items.count) submodule(s)"
        }
    }

    /// Selected rows, or the clicked row when the context menu opens on an unselected one.
    private var selectedItems: [GitSubmoduleInfo] {
        guard let tableView else { return [] }
        var rows = tableView.selectedRowIndexes
        if tableView.clickedRow >= 0, !rows.contains(tableView.clickedRow) {
            rows = IndexSet(integer: tableView.clickedRow)
        }
        return rows.compactMap { $0 < submodules.count ? submodules[$0] : nil }
    }

    // MARK: - Actions

    @objc private func addSubmoduleClicked() {
        let root = repositoryPath
        WindowRegistry.shared.present({ SubmoduleAddWindowController(repositoryPath: root) }, repository: root)
    }

    @objc private func updateSubmodulesClicked() {
        let root = repositoryPath
        let paths = selectedItems.map(\.path)
        WindowRegistry.shared.present({ SubmoduleUpdateWindowController(repositoryPath: root, paths: paths) }, repository: root)
    }

    @objc private func syncSubmodulesClicked() {
        let paths = selectedItems.map(\.path)
        ProgressWindowController.run(title: "Submodule Sync", commands: [["submodule", "sync", "--recursive", "--"] + paths],
                                     workingDirectory: repositoryPath)
    }

    @objc private func deinitSubmoduleClicked() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let confirm = NSAlert()
        confirm.messageText = "Deinitialize \(items.count == 1 ? "“\(items[0].path)”" : "\(items.count) submodules")?"
        confirm.informativeText = "git submodule deinit -f removes the working tree and DISCARDS uncommitted changes inside the submodule. It stays registered and can be updated again."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Deinitialize")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        ProgressWindowController.run(title: "Submodule Deinit", commands: [["submodule", "deinit", "-f", "--"] + items.map(\.path)],
                                     workingDirectory: repositoryPath)
    }

    /// Removes the submodule completely: deinit, `git rm` (which also drops the `.gitmodules`
    /// entry) and the cached repository under `.git/modules`, then offers to commit.
    @objc private func removeSubmoduleClicked() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let confirm = NSAlert()
        confirm.messageText = "Remove \(items.count == 1 ? "“\(items[0].path)”" : "\(items.count) submodules")?"
        confirm.informativeText = "The submodule is deinitialized, removed from the index and .gitmodules, and its cloned repository under .git/modules is deleted. Uncommitted changes inside it are lost. Commit afterwards to record the removal."
        confirm.alertStyle = .critical
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let root = repositoryPath
        let paths = items.map(\.path)
        let names = items.map(\.name)
        ProgressWindowController.run(
            title: "Remove Submodule",
            commands: [["submodule", "deinit", "-f", "--"] + paths, ["rm", "-f", "--"] + paths],
            workingDirectory: root,
            postActions: { outcome in
                guard outcome.succeeded else { return [] }
                return [.init("Commit…") { CommandRouter.shared.execute(command: .commit, targetPath: root.rawPath) }]
            },
            onFinish: { outcome in
                guard outcome.succeeded else { return }
                Task {
                    for name in names {
                        let modules = (try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "--git-path", "modules/\(name)"], workingDirectory: root))?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !modules.isEmpty else { continue }
                        let absolute = modules.hasPrefix("/") ? modules : root.appendingPathComponent(modules).rawPath
                        try? FileManager.default.removeItem(atPath: absolute)
                    }
                }
            }
        )
    }

    @objc private func rowDoubleClicked() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < submodules.count else { return }
        openSubmodule(submodules[tableView.clickedRow])
    }

    /// Opens the submodule's own log (it is a repository of its own).
    private func openSubmodule(_ item: GitSubmoduleInfo) {
        guard item.state != .uninitialized else {
            ToolDialog.showMessage("Not initialized", "Update “\(item.path)” first to check it out.", in: window)
            return
        }
        CommandRouter.shared.execute(command: .log, targetPath: repositoryPath.appendingPathComponent(item.path).rawPath)
    }

    @objc private func closeClicked() {
        window?.close()
    }

    // MARK: - NSTableViewDelegate & DataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        submodules.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < submodules.count else { return nil }
        let item = submodules[row]
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("Path")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }()
        cell.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        cell.textColor = .labelColor
        switch id.rawValue {
        case "Path":
            cell.stringValue = item.path
        case "Commit":
            cell.stringValue = String(item.commit.prefix(8))
            cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        case "Status":
            switch item.state {
            case .uninitialized:
                cell.stringValue = "Not initialized"
                cell.textColor = .systemOrange
            case .modifiedCommit:
                cell.stringValue = "Different commit"
                cell.textColor = .systemBlue
            case .conflict:
                cell.stringValue = "Merge conflict"
                cell.textColor = .systemRed
            case .upToDate:
                cell.stringValue = "Up to date"
                cell.textColor = .systemGreen
            }
        case "Branch":
            cell.stringValue = item.branch
            cell.textColor = .secondaryLabelColor
        default:
            cell.stringValue = item.url
            cell.textColor = .secondaryLabelColor
        }
        return cell
    }
}

extension SubmoduleWindowController: NSMenuDelegate {
    /// Per-row menu (TortoiseGit's submodule entries in the shell and status-list menus).
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = selectedItems
        guard let first = items.first else { return }
        let root = repositoryPath
        let subRoot = root.appendingPathComponent(first.path)
        let initialized = first.state != .uninitialized
        if items.count == 1 {
            let log = ClosureMenuItem(title: "Show Log of Submodule", symbol: "clock.arrow.circlepath") { [weak self] in self?.openSubmodule(first) }
            log.isEnabled = initialized
            menu.addItem(log)
            let diff = ClosureMenuItem(title: "Submodule Diff", symbol: "arrow.left.arrow.right") {
                WindowRegistry.shared.present({ SubmoduleDiffWindowController(root: root, submodulePath: first.path, oldRevision: "HEAD", newRevision: nil) }, repository: root)
            }
            diff.isEnabled = initialized
            menu.addItem(diff)
            let changes = ClosureMenuItem(title: "Check for Modifications in Submodule", symbol: "doc.text.magnifyingglass") {
                CommandRouter.shared.execute(command: .changed, targetPath: subRoot.rawPath)
            }
            changes.isEnabled = initialized
            menu.addItem(changes)
            let commit = ClosureMenuItem(title: "Commit Submodule…", symbol: "checkmark.circle") {
                CommandRouter.shared.execute(command: .commit, targetPath: subRoot.rawPath)
            }
            commit.isEnabled = initialized
            menu.addItem(commit)
            menu.addItem(ClosureMenuItem(title: "Show in Finder", symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([subRoot.url])
            })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: "Update…", symbol: "arrow.down.circle") { [weak self] in self?.updateSubmodulesClicked() })
        menu.addItem(ClosureMenuItem(title: "Sync", symbol: "arrow.triangle.2.circlepath") { [weak self] in self?.syncSubmodulesClicked() })
        menu.addItem(ClosureMenuItem(title: "Deinit…", symbol: "xmark.circle") { [weak self] in self?.deinitSubmoduleClicked() })
        menu.addItem(ClosureMenuItem(title: "Remove…", symbol: "trash") { [weak self] in self?.removeSubmoduleClicked() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Copy Path", symbol: "doc.on.clipboard") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
        })
        if !first.url.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Copy URL", symbol: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.url).joined(separator: "\n"), forType: .string)
            })
        }
    }
}
