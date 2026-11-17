import Cocoa
import PangolinGitCore

/// Git Stash Save and Stash List dialog mirroring TortoiseGit's `StashSaveDlg.cpp` and the stash
/// list (TortoiseGit shows `refs/stash` in its RefLog dialog): save with message, untracked /
/// ignored files, keep index and an optional path limit; list with a diff preview of the selected
/// stash, Pop / Apply / Drop / Clear and *Create branch from stash*.
public final class StashWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let repositoryPath: PangolinPath
    /// Repository-relative paths the save is limited to (from a Finder selection); empty = everything.
    private let paths: [String]
    private var stashes: [GitReflogEntry] = []

    private let messageField = NSTextField()
    private let includeUntrackedCheckbox = NSButton(checkboxWithTitle: "Include untracked files (-u)", target: nil, action: nil)
    private let includeIgnoredCheckbox = NSButton(checkboxWithTitle: "Include ignored files too (--all)", target: nil, action: nil)
    private let keepIndexCheckbox = NSButton(checkboxWithTitle: "Keep staged changes (--keep-index)", target: nil, action: nil)
    private let onlyPathsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let stashSaveButton = NSButton(title: "Stash Save", target: nil, action: nil)

    private let tableView = NSTableView()
    private let previewView = SideBySideDiffView()
    private let statusLabel = NSTextField(labelWithString: "Ready.")
    private var selectionButtons: [NSButton] = []
    private let clearButton = NSButton(title: "Clear…", target: nil, action: nil)

    public init(repositoryPath: PangolinPath, paths: [String] = []) {
        self.repositoryPath = repositoryPath
        self.paths = paths.filter { !$0.isEmpty }
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 860, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Stash - \(repositoryPath.filename)"
        window.minSize = NSSize(width: 640, height: 520)
        super.init(window: window)

        setupUI()
        loadStashes()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.loadStashes() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let labelSave = NSTextField(labelWithString: "Save Working Changes to Stash:")
        labelSave.font = NSFont.boldSystemFont(ofSize: 12)
        messageField.placeholderString = "Optional stash message..."

        for box in [includeUntrackedCheckbox, includeIgnoredCheckbox] {
            box.target = self
            box.action = #selector(optionsChanged(_:))
        }
        onlyPathsCheckbox.title = paths.count == 1 ? "Only “\(paths[0])”" : "Only the \(paths.count) selected items"
        onlyPathsCheckbox.state = paths.isEmpty ? .off : .on
        onlyPathsCheckbox.isHidden = paths.isEmpty
        warningLabel.font = NSFont.systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange

        stashSaveButton.target = self
        stashSaveButton.action = #selector(onStashSave)
        stashSaveButton.bezelStyle = .rounded
        stashSaveButton.keyEquivalent = "\r"

        let saveRow = NSStackView(views: [messageField, stashSaveButton])
        let optionsRow = NSStackView(views: [includeUntrackedCheckbox, includeIgnoredCheckbox, keepIndexCheckbox])
        optionsRow.spacing = 14

        let labelList = NSTextField(labelWithString: "Stored Stashes:")
        labelList.font = NSFont.boldSystemFont(ofSize: 12)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView
        for (id, title, width) in [("Id", "Stash", 90.0), ("Message", "Message", 520.0), ("Date", "Date", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(onShowChanges)

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(previewView)

        var buttons: [NSButton] = []
        for (title, action) in [("Pop", #selector(onStashPop)), ("Apply", #selector(onStashApply)), ("Drop…", #selector(onStashDrop)),
                                ("Branch…", #selector(onStashBranch)), ("Show Changes", #selector(onShowChanges))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            buttons.append(button)
        }
        selectionButtons = buttons
        buttons[3].toolTip = "Create a branch where the stash was made and apply it there (git stash branch)"
        clearButton.target = self
        clearButton.action = #selector(onClear)
        clearButton.bezelStyle = .rounded
        let btnStack = NSStackView(views: buttons + [clearButton])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.textColor = .secondaryLabelColor
        let bottomRow = NSStackView(views: [statusLabel, NSView(), btnStack])

        let stack = NSStackView(views: [labelSave, saveRow, optionsRow, onlyPathsCheckbox, warningLabel, labelList, split, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: warningLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            saveRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            warningLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            split.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            previewView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        updateSelectionButtons()
    }

    /// TortoiseGit warns that stashing untracked (or ignored) files removes them from disk like `git clean`.
    @objc private func optionsChanged(_ sender: NSButton) {
        if sender === includeIgnoredCheckbox, sender.state == .on { includeUntrackedCheckbox.state = .on }
        if sender === includeUntrackedCheckbox, sender.state == .off { includeIgnoredCheckbox.state = .off }
        if includeIgnoredCheckbox.state == .on {
            warningLabel.stringValue = "Untracked and ignored files (build output, local settings, …) are moved into the stash and deleted from disk, like git clean -fdx."
        } else if includeUntrackedCheckbox.state == .on {
            warningLabel.stringValue = "Untracked files are moved into the stash and deleted from disk, like git clean -fd."
        } else {
            warningLabel.stringValue = ""
        }
    }

    private func loadStashes() {
        let root = repositoryPath
        Task { @MainActor in
            let result = try? await GitCLIRunner().run(arguments: GitReflog.arguments(ref: "refs/stash"), workingDirectory: root)
            let selected = self.tableView.selectedRow
            self.stashes = result?.isSuccess == true ? GitReflog.parse(result?.standardOutput ?? "", ref: "refs/stash") : []
            self.tableView.reloadData()
            if selected >= 0 && selected < self.stashes.count {
                self.tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            } else {
                self.previewView.setDiff(rawUnifiedText: "")
            }
            self.statusLabel.stringValue = "\(self.stashes.count) stash(es)."
            self.updateSelectionButtons()
        }
    }

    private func updateSelectionButtons() {
        let hasSelection = tableView.selectedRow >= 0
        selectionButtons.forEach { $0.isEnabled = hasSelection }
        clearButton.isEnabled = !stashes.isEmpty
    }

    @objc private func onStashSave() {
        var options = GitStashPushOptions()
        options.message = messageField.stringValue
        options.includeUntracked = includeUntrackedCheckbox.state == .on
        options.includeIgnored = includeIgnoredCheckbox.state == .on
        options.keepIndex = keepIndexCheckbox.state == .on
        if onlyPathsCheckbox.state == .on { options.paths = paths }
        messageField.stringValue = ""
        ProgressWindowController.run(title: "Stash Save", commands: [options.arguments], workingDirectory: repositoryPath)
    }

    /// The selected stash, or nil (with a hint) when nothing is selected.
    private var selectedStash: GitReflogEntry? {
        let row = tableView.selectedRow
        guard row >= 0 && row < stashes.count else {
            statusLabel.stringValue = "Select a stash first."
            return nil
        }
        return stashes[row]
    }

    @objc private func onStashPop() {
        guard let stash = selectedStash else { return }
        StashActions.apply(repositoryPath, stash: stash.selector, pop: true)
    }

    @objc private func onStashApply() {
        guard let stash = selectedStash else { return }
        StashActions.apply(repositoryPath, stash: stash.selector, pop: false)
    }

    @objc private func onShowChanges() {
        guard let stash = selectedStash else { return }
        let root = repositoryPath
        WindowRegistry.shared.present({ DiffWindowController(filePath: root, oldRevision: "\(stash.hash)^", newRevision: stash.hash) }, repository: root)
    }

    @objc private func onStashBranch() {
        guard let stash = selectedStash else { return }
        let root = repositoryPath
        let sheet = TextInputSheet(title: "Create Branch from Stash", prompt: "New branch (created where \(stash.selector) was made, with its changes applied):",
                                   initialText: "", okTitle: "Create Branch", multiline: false)
        sheet.validator = { GitRefName.validationError($0.trimmingCharacters(in: .whitespaces)) }
        sheet.begin(on: window) { name in
            guard let name = name?.trimmingCharacters(in: .whitespaces) else { return }
            ProgressWindowController.run(title: "Stash Branch \(name)", commands: [["stash", "branch", name, stash.selector]], workingDirectory: root,
                                         postActions: { $0.succeeded ? [StashActions.showChangesAction(root)] : [] })
        }
    }

    @objc private func onStashDrop() {
        guard let stash = selectedStash else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Drop \(stash.selector)?"
        alert.informativeText = "The stashed changes will be deleted. This cannot be undone from PangolinGit."
        alert.addButton(withTitle: "Drop")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(["stash", "drop", stash.selector])
    }

    @objc private func onClear() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clear all \(stashes.count) stashes?"
        alert.informativeText = "Every stashed change set is deleted (git stash clear). This cannot be undone."
        alert.addButton(withTitle: "Clear Stash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(["stash", "clear"])
    }

    /// Runs a quick stash command and reports git's message on failure; the list reloads through RepositoryEvents.
    private func perform(_ args: [String]) {
        let root = repositoryPath
        Task { @MainActor in
            do {
                try await GitCLIRunner.runAsync(arguments: args, workingDirectory: root)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "git \(args.prefix(2).joined(separator: " ")) failed"
                alert.runModal()
            }
        }
    }

    // MARK: - TableView

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return stashes.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < stashes.count else { return nil }
        let item = stashes[row]
        let label: NSTextField
        switch tableColumn?.identifier.rawValue {
        case "Id":
            label = NSTextField(labelWithString: item.selector)
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        case "Message":
            label = NSTextField(labelWithString: item.message)
        default:
            label = NSTextField(labelWithString: item.date.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "")
            label.textColor = .secondaryLabelColor
        }
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// Previews the selected stash's changes (`git stash show -p`), TortoiseGit's per-stash diff.
    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionButtons()
        let row = tableView.selectedRow
        guard row >= 0, row < stashes.count else {
            previewView.setDiff(rawUnifiedText: "")
            return
        }
        let selector = stashes[row].selector
        let root = repositoryPath
        Task { @MainActor in
            let diff = (try? await GitCLIRunner.runAsync(arguments: ["stash", "show", "-p", "--no-color", "--no-ext-diff", selector], workingDirectory: root)) ?? ""
            guard self.tableView.selectedRow == row else { return }
            self.previewView.setDiff(rawUnifiedText: diff)
        }
    }
}
