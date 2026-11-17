import Foundation
import Cocoa
import PangolinGitCore

/// RefLog dialog (`RefLogDlg.cpp` in TortoiseGit): the reflog of HEAD, any branch or `refs/stash`
/// with Ref / SHA-1 / Action / Message / Date columns, a filter, *Delete* (reflog delete or stash
/// drop), *Clear stash*, stash Apply / Pop, a context menu with the usual log actions, and a picker
/// mode for revision fields (*Compare Revisions*).
public final class RefLogWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {

    public let repositoryPath: PangolinPath
    private var ref: String
    private let pickerCompletion: ((String) -> Void)?

    private var entries: [GitReflogEntry] = []
    private var filtered: [GitReflogEntry] = []
    private let refPopup = NSPopUpButton()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Loading reflog...")
    private let buttonStack = NSStackView()
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var isStash: Bool { ref == "refs/stash" }

    /// - Parameters:
    ///   - ref: `HEAD`, a branch (`main`, `refs/heads/main`, `origin/main`) or `refs/stash` (the stash list).
    ///   - pickerCompletion: picker mode; called with the chosen entry's commit, then the window closes.
    public init(repositoryPath: PangolinPath, ref: String = "HEAD", pickerCompletion: ((String) -> Void)? = nil) {
        self.repositoryPath = repositoryPath
        self.ref = ref
        self.pickerCompletion = pickerCompletion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 680, height: 400)
        super.init(window: window)
        setupUI()
        loadRefs()
        loadReflog()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.loadReflog() }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        refPopup.target = self
        refPopup.action = #selector(refChanged)
        searchField.placeholderString = "Filter by message, action or SHA-1"
        searchField.target = self
        searchField.action = #selector(filterChanged)
        let topRow = NSStackView(views: [NSTextField(labelWithString: "Ref:"), refPopup, searchField])
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView
        for (id, title, width) in [("Selector", "Ref", 120.0), ("Hash", "SHA-1", 90.0), ("Action", "Action", 140.0),
                                   ("Message", "Message", 380.0), ("Date", "Date", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [statusLabel, NSView(), buttonStack])

        for view in [topRow, scroll, bottomRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            topRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            topRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -10),
            bottomRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        rebuildButtons()
    }

    /// Buttons depend on the ref: stash actions for `refs/stash`, Select in picker mode.
    private func rebuildButtons() {
        buttonStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func add(_ title: String, _ handler: @escaping @MainActor () -> Void) {
            let button = ClosureButton(title: title, handler: handler)
            button.bezelStyle = .rounded
            buttonStack.addArrangedSubview(button)
        }
        if pickerCompletion != nil {
            add("Select") { [weak self] in self?.doubleClicked() }
        } else if isStash {
            add("Show Changes") { [weak self] in self?.showChanges() }
            add("Apply") { [weak self] in self?.applyStash(pop: false) }
            add("Pop") { [weak self] in self?.applyStash(pop: true) }
            add("Delete…") { [weak self] in self?.deleteSelected() }
            add("Clear Stash…") { [weak self] in self?.clearStash() }
        } else {
            add("Delete Entry…") { [weak self] in self?.deleteSelected() }
        }
        let close = ClosureButton(title: pickerCompletion == nil ? "Close" : "Cancel") { [weak self] in self?.close() }
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        buttonStack.addArrangedSubview(close)
        window?.title = (isStash ? "Stash List" : (pickerCompletion == nil ? "RefLog" : "Select from RefLog")) + " — \(repositoryPath.filename)"
    }

    /// Fills the ref selector: HEAD, local and remote branches, and the stash when there is one.
    private func loadRefs() {
        let root = repositoryPath
        Task { @MainActor in
            let output = (try? await GitCLIRunner.runAsync(arguments: ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/stash"],
                                                           workingDirectory: root)) ?? ""
            let refs = ["HEAD"] + output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
            self.refPopup.removeAllItems()
            for full in refs {
                self.refPopup.addItem(withTitle: full == "refs/stash" ? "stash" : GitReflog.shortName(full))
                self.refPopup.lastItem?.representedObject = full
            }
            let wanted = self.refPopup.itemArray.first { ($0.representedObject as? String) == self.ref || $0.title == self.ref }
            if let wanted {
                self.refPopup.select(wanted)
            } else {
                self.refPopup.addItem(withTitle: GitReflog.shortName(self.ref))
                self.refPopup.lastItem?.representedObject = self.ref
                self.refPopup.select(self.refPopup.lastItem)
            }
        }
    }

    @objc private func refChanged() {
        guard let full = refPopup.selectedItem?.representedObject as? String, full != ref else { return }
        ref = full
        rebuildButtons()
        loadReflog()
    }

    private func loadReflog() {
        let root = repositoryPath
        let ref = self.ref
        Task { @MainActor in
            let result = try? await GitCLIRunner().run(arguments: GitReflog.arguments(ref: ref), workingDirectory: root)
            guard ref == self.ref else { return }
            self.entries = GitReflog.parse(result?.standardOutput ?? "", ref: ref)
            self.applyFilter()
            if result?.isSuccess == false && !(ref == "refs/stash") {
                self.statusLabel.stringValue = "No reflog for \(ref)."
            }
        }
    }

    @objc private func filterChanged() {
        applyFilter()
    }

    private func applyFilter() {
        let text = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = text.isEmpty ? entries : entries.filter {
            $0.message.lowercased().contains(text) || $0.action.lowercased().contains(text) || $0.hash.hasPrefix(text) || $0.selector.lowercased().contains(text)
        }
        tableView.reloadData()
        let noun = isStash ? "stash(es)" : "entries"
        statusLabel.stringValue = filtered.count == entries.count ? "\(entries.count) \(noun)" : "Showing \(filtered.count) of \(entries.count) \(noun)"
    }

    private var selectedEntries: [GitReflogEntry] {
        tableView.selectedRowIndexes.compactMap { $0 < filtered.count ? filtered[$0] : nil }
    }

    @objc private func doubleClicked() {
        guard let entry = selectedEntries.first else { return }
        if let pickerCompletion {
            close()
            pickerCompletion(entry.hash)
        } else if isStash {
            showChanges()
        } else {
            WindowRegistry.shared.present({ FileDiffWindowController(repositoryPath: repositoryPath, rev1: "\(entry.hash)^", rev2: entry.hash) },
                                          repository: repositoryPath)
        }
    }

    // MARK: - Actions

    private func showChanges() {
        guard let entry = selectedEntries.first else { return }
        let root = repositoryPath
        WindowRegistry.shared.present({ DiffWindowController(filePath: root, oldRevision: "\(entry.hash)^", newRevision: entry.hash) },
                                      repository: root)
    }

    private func applyStash(pop: Bool) {
        guard let entry = selectedEntries.first else { return }
        StashActions.apply(repositoryPath, stash: entry.selector, pop: pop)
    }

    /// Deletes the selected entries: `git stash drop` for stashes, `git reflog delete` otherwise.
    /// Newest index last so the remaining selectors stay valid while deleting.
    private func deleteSelected() {
        let selected = selectedEntries.sorted { $0.index > $1.index }
        guard !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = selected.count == 1 ? "Delete \(selected[0].selector)?" : "Delete \(selected.count) entries?"
        alert.informativeText = isStash
            ? "The stashed changes are deleted. They can only be recovered with git fsck while unreachable objects are kept."
            : "Reflog entries are the safety net for recovering lost commits. Deleting them cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let commands = selected.map { isStash ? ["stash", "drop", $0.selector] : ["reflog", "delete", "--rewrite", $0.selector] }
        runAndReload(commands)
    }

    private func clearStash() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clear all stashes?"
        alert.informativeText = "All \(entries.count) stashed change sets are deleted (git stash clear). This cannot be undone."
        alert.addButton(withTitle: "Clear Stash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runAndReload([["stash", "clear"]])
    }

    private func runAndReload(_ commands: [[String]]) {
        let root = repositoryPath
        Task { @MainActor in
            for args in commands {
                do {
                    try await GitCLIRunner.runAsync(arguments: args, workingDirectory: root)
                } catch {
                    NSAlert(error: error).runModal()
                    break
                }
            }
            // `reflog delete` is not one of the commands the runner announces.
            RepositoryEvents.post(root)
            self.loadReflog()
        }
    }

    // MARK: - Context menu (RL-04)

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = tableView.clickedRow
        guard clicked >= 0, clicked < filtered.count else { return }
        if !tableView.selectedRowIndexes.contains(clicked) {
            tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        let selected = selectedEntries
        let root = repositoryPath
        let registry = WindowRegistry.shared

        if selected.count == 2 {
            let (newer, older) = (selected[0], selected[1])
            menu.addItem(ClosureMenuItem(title: "Compare Revisions", symbol: "arrow.left.arrow.right") {
                registry.present({ FileDiffWindowController(repositoryPath: root, rev1: older.hash, rev2: newer.hash) }, repository: root)
            })
            menu.addItem(ClosureMenuItem(title: "Show Unified Diff", symbol: "plusminus") {
                registry.present({ DiffWindowController(filePath: root, oldRevision: older.hash, newRevision: newer.hash) }, repository: root)
            })
            menu.addItem(.separator())
        } else if let entry = selected.first {
            let hash = entry.hash
            if isStash {
                menu.addItem(ClosureMenuItem(title: "Show Changes", symbol: "plusminus") { [weak self] in self?.showChanges() })
                menu.addItem(ClosureMenuItem(title: "Apply Stash", symbol: "tray.and.arrow.up") { [weak self] in self?.applyStash(pop: false) })
                menu.addItem(ClosureMenuItem(title: "Pop Stash", symbol: "tray.and.arrow.up.fill") { [weak self] in self?.applyStash(pop: true) })
                menu.addItem(ClosureMenuItem(title: "Create Branch from Stash…", symbol: "arrow.branch") { [weak self] in self?.stashBranch(entry) })
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuItem(title: "Compare with Working Tree", symbol: "doc.on.doc") {
                registry.present({ DiffWindowController(filePath: root, oldRevision: hash) }, repository: root)
            })
            menu.addItem(ClosureMenuItem(title: "Compare with Previous Revision", symbol: "arrow.left.arrow.right") {
                registry.present({ FileDiffWindowController(repositoryPath: root, rev1: "\(hash)^", rev2: hash) }, repository: root)
            })
            menu.addItem(ClosureMenuItem(title: "Browse Repository", symbol: "folder") {
                registry.present({ RepoBrowserWindowController(repositoryPath: root, initialRevision: hash) }, repository: root)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Create Branch at This Version…", symbol: "arrow.branch") {
                registry.present({ CreateBranchTagWindowController(repositoryPath: root, initialBase: hash) }, repository: root)
            })
            menu.addItem(ClosureMenuItem(title: "Create Tag at This Version…", symbol: "tag") {
                registry.present({ CreateBranchTagWindowController(repositoryPath: root, initialBase: hash, createTag: true) }, repository: root)
            })
            menu.addItem(ClosureMenuItem(title: "Switch/Checkout to This…", symbol: "arrow.triangle.swap") {
                registry.present({ SwitchWindowController(repositoryPath: root, initialTarget: hash) }, repository: root)
            })
            menu.addItem(ClosureMenuItem(title: "Reset to This…", symbol: "arrow.uturn.backward") {
                registry.present({ ResetWindowController(repositoryPath: root, initialCommit: hash) }, repository: root)
            })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: "Copy SHA-1", symbol: "doc.on.doc") {
            Self.copy(selected.map(\.hash))
        })
        menu.addItem(ClosureMenuItem(title: "Copy Messages") {
            Self.copy(selected.map(\.message))
        })
        menu.addItem(ClosureMenuItem(title: "Copy All Information") {
            Self.copy(selected.map { [$0.selector, $0.hash, $0.action, $0.message, $0.date.map(Self.dateFormatter.string(from:)) ?? ""].joined(separator: "\t") })
        })
        if pickerCompletion == nil {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: isStash ? "Delete Stash…" : "Delete Entry…", symbol: "trash") { [weak self] in self?.deleteSelected() })
        }
    }

    private static func copy(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// `git stash branch <name> <stash>`: a branch at the stash's base with the changes applied (SS-02).
    private func stashBranch(_ entry: GitReflogEntry) {
        let root = repositoryPath
        let sheet = TextInputSheet(title: "Create Branch from Stash", prompt: "New branch (created where \(entry.selector) was made, with its changes applied):",
                                   initialText: "", okTitle: "Create Branch", multiline: false)
        sheet.validator = { GitRefName.validationError($0.trimmingCharacters(in: .whitespaces)) }
        sheet.begin(on: window) { name in
            guard let name = name?.trimmingCharacters(in: .whitespaces) else { return }
            ProgressWindowController.run(title: "Stash Branch \(name)", commands: [["stash", "branch", name, entry.selector]], workingDirectory: root,
                                         postActions: { $0.succeeded ? [StashActions.showChangesAction(root)] : [] })
        }
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let entry = filtered[row]
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        switch tableColumn?.identifier.rawValue ?? "" {
        case "Selector":
            cell.stringValue = entry.selector
            cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        case "Hash":
            cell.stringValue = String(entry.hash.prefix(10))
            cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.textColor = .systemBlue
        case "Action":
            cell.stringValue = entry.action
            let action = entry.action.lowercased()
            if action.hasPrefix("commit") {
                cell.textColor = .systemGreen
            } else if action.hasPrefix("rebase") {
                cell.textColor = .systemOrange
            } else if action.hasPrefix("reset") {
                cell.textColor = .systemRed
            }
        case "Message":
            cell.stringValue = entry.message
        case "Date":
            cell.stringValue = entry.date.map(Self.dateFormatter.string(from:)) ?? ""
            cell.textColor = .secondaryLabelColor
        default:
            break
        }
        return cell
    }
}
