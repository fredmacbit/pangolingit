import Cocoa
import PangolinGitCore

/// Cherry-pick dialog: TortoiseGit runs `CRebaseDlg` in cherry-pick mode for Log ▸ *Cherry Pick
/// selected commits…*. Lists the commits oldest first (pick or skip, reorderable, more added from
/// the Log), with "-x" (*add "cherry picked from"*), the parent to follow for merge commits and
/// *No commit*; when git stops it shows the conflicts and Continue / Skip / Abort.
public final class CherryPickWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private struct Item {
        let hash: String
        let subject: String
        let author: String
        let isMerge: Bool
        var pick = true
    }

    private let repositoryPath: PangolinPath
    private let gitDirectory: PangolinPath?
    private var items: [Item] = []
    private var operation: GitOperationInProgress = .none

    private let tableView = NSTableView()
    private let currentLabel = NSTextField(labelWithString: "Cherry-pick onto: …")
    private let recordOriginCheckbox = NSButton(checkboxWithTitle: "Add “cherry picked from” (-x)", target: nil, action: nil)
    private let noCommitCheckbox = NSButton(checkboxWithTitle: "No commit (only apply the changes)", target: nil, action: nil)
    private let signOffCheckbox = NSButton(checkboxWithTitle: "Sign-off", target: nil, action: nil)
    private let mainlinePopup = NSPopUpButton()
    private var conflictList: ConflictListView!
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "Cherry-Pick", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private var setupControls: [NSControl] = []

    /// - Parameter commits: commits to apply in any order; they are sorted oldest first.
    public init(repositoryPath: PangolinPath, commits: [String] = []) {
        self.repositoryPath = repositoryPath
        self.gitDirectory = GitRepository.open(at: repositoryPath)?.gitDirectory
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cherry Pick - \(repositoryPath.filename)"
        window.minSize = NSSize(width: 620, height: 520)
        super.init(window: window)
        conflictList = ConflictListView(repositoryRoot: repositoryPath)
        conflictList.onChange = { [weak self] _ in self?.updateControls() }
        setupUI()
        add(commits)
        refreshState()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.refreshState() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        currentLabel.font = NSFont.boldSystemFont(ofSize: 13)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView
        for (id, title, width) in [("Pick", "", 30.0), ("Hash", "Commit", 80.0), ("Subject", "Message", 440.0), ("Author", "Author", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true

        let addButton = NSButton(title: "Add from Log…", target: self, action: #selector(addFromLog))
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeSelected))
        let upButton = NSButton(title: "▲ Up", target: self, action: #selector(moveItemsUp))
        let downButton = NSButton(title: "▼ Down", target: self, action: #selector(moveItemsDown))
        let editRow = NSStackView(views: [addButton, removeButton, upButton, downButton])

        mainlinePopup.addItems(withTitles: ["Parent 1 (the branch merged into)", "Parent 2 (the merged branch)"])
        mainlinePopup.toolTip = "For merge commits: the parent whose side counts as the mainline (git cherry-pick -m)"
        recordOriginCheckbox.toolTip = "Append “(cherry picked from commit …)” to each message (git cherry-pick -x)"
        let mainlineRow = NSStackView(views: [NSTextField(labelWithString: "Merge commits relative to:"), mainlinePopup])
        let optionsRow = NSStackView(views: [recordOriginCheckbox, signOffCheckbox, noCommitCheckbox])
        optionsRow.spacing = 16
        setupControls = [addButton, removeButton, upButton, downButton, recordOriginCheckbox, signOffCheckbox, noCommitCheckbox, mainlinePopup]

        statusLabel.textColor = .secondaryLabelColor
        for (button, action) in [(startButton, #selector(start)), (continueButton, #selector(continuePick)),
                                 (skipButton, #selector(skip)), (abortButton, #selector(abort))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        startButton.keyEquivalent = "\r"
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [startButton, continueButton, skipButton, abortButton, close])

        let conflictsLabel = NSTextField(labelWithString: "Conflict Files:")
        let stack = NSStackView(views: [currentLabel, scroll, editRow, optionsRow, mainlineRow, conflictsLabel, conflictList, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            conflictList.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            conflictList.heightAnchor.constraint(equalToConstant: 150),
            statusLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    /// Adds commits (oldest first, by commit date), skipping ones already listed.
    public func add(_ commits: [String]) {
        guard !commits.isEmpty else { return }
        let root = repositoryPath
        Task { @MainActor in
            guard let output = try? await GitCLIRunner.runAsync(arguments: ["log", "--no-walk", "--format=%H%x1f%s%x1f%an%x1f%P"] + commits,
                                                                 workingDirectory: root) else {
                self.statusLabel.stringValue = "Could not read the commits."
                return
            }
            let new = output.split(separator: "\n").reversed().compactMap { line -> Item? in
                let fields = line.components(separatedBy: "\u{1f}")
                guard fields.count == 4, !self.items.contains(where: { $0.hash == fields[0] }) else { return nil }
                return Item(hash: fields[0], subject: fields[1], author: fields[2], isMerge: fields[3].split(separator: " ").count > 1)
            }
            self.items += new
            self.tableView.reloadData()
            self.updateControls()
        }
    }

    private func refreshState() {
        let root = repositoryPath
        Task { @MainActor in
            let branch = (try? await GitCLIRunner.runAsync(arguments: ["symbolic-ref", "--short", "-q", "HEAD"], workingDirectory: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.currentLabel.stringValue = "Cherry-pick onto: \(branch.isEmpty ? "detached HEAD" : branch)"
            self.operation = self.gitDirectory.map { GitOperationInProgress.detect(gitDirectory: $0) } ?? .none
            self.conflictList.reload()
            self.updateControls()
        }
    }

    private var isPicking: Bool { operation == .cherryPick }

    private func updateControls() {
        let picks = items.filter(\.pick)
        setupControls.forEach { $0.isEnabled = !isPicking }
        mainlinePopup.isEnabled = !isPicking && picks.contains(where: \.isMerge)
        startButton.isEnabled = !isPicking && !picks.isEmpty && operation == .none
        continueButton.isEnabled = isPicking && conflictList.conflictedPaths.isEmpty
        skipButton.isEnabled = isPicking
        abortButton.isEnabled = isPicking
        if isPicking {
            statusLabel.stringValue = conflictList.conflictedPaths.isEmpty
                ? "The cherry-pick stopped. All conflicts are resolved — Continue commits and goes on with the next commit."
                : "The cherry-pick stopped with conflicts. Resolve them (double-click a file), then Continue — or Skip this commit, or Abort."
        } else if operation != .none {
            statusLabel.stringValue = "A \(operation.displayName) is in progress; finish it first."
        } else {
            statusLabel.stringValue = picks.isEmpty ? "Add the commits to cherry-pick." : "\(picks.count) commit(s) will be applied, oldest first."
        }
        statusLabel.textColor = isPicking && !conflictList.conflictedPaths.isEmpty ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Editing

    @objc private func addFromLog() {
        let root = repositoryPath
        WindowRegistry.shared.present({
            LogWindowController(repositoryPath: root) { [weak self] hash in self?.add([hash]) }
        }, repository: root)
    }

    @objc private func removeSelected() {
        for index in tableView.selectedRowIndexes.reversed() { items.remove(at: index) }
        tableView.reloadData()
        updateControls()
    }

    @objc private func moveItemsUp() {
        let selection = tableView.selectedRowIndexes
        guard let first = selection.first, first > 0 else { return }
        for index in selection { items.swapAt(index, index - 1) }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(selection.map { $0 - 1 }), byExtendingSelection: false)
    }

    @objc private func moveItemsDown() {
        let selection = tableView.selectedRowIndexes
        guard let last = selection.last, last < items.count - 1 else { return }
        for index in selection.reversed() { items.swapAt(index, index + 1) }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(selection.map { $0 + 1 }), byExtendingSelection: false)
    }

    @objc private func pickToggled(_ sender: NSButton) {
        guard sender.tag < items.count else { return }
        items[sender.tag].pick = sender.state == .on
        updateControls()
    }

    // MARK: - Running

    @objc private func start() {
        let picks = items.filter(\.pick)
        guard !picks.isEmpty else { return }
        var options = GitCherryPickOptions(commits: picks.map(\.hash))
        options.recordOrigin = recordOriginCheckbox.state == .on
        options.signOff = signOffCheckbox.state == .on
        options.noCommit = noCommitCheckbox.state == .on
        if picks.contains(where: \.isMerge) {
            options.mainline = mainlinePopup.indexOfSelectedItem + 1
        }
        let root = repositoryPath
        Task { @MainActor in
            var stashed = false
            switch await DirtyWorkingTree.prepare(root, operation: "cherry-pick", allowContinue: false, window: self.window) {
            case .cancel: return
            case .stashed: stashed = true
            case .proceed: break
            }
            self.run(title: "Cherry Pick", arguments: options.arguments, stashed: stashed, noCommit: options.noCommit)
        }
    }

    private func run(title: String, arguments: [String], stashed: Bool = false, noCommit: Bool = false) {
        let root = repositoryPath
        ProgressWindowController.run(title: title, commands: [arguments], workingDirectory: root, postActions: { [weak self] outcome in
            var actions: [ProgressWindowController.PostAction] = []
            let stopped = self?.gitDirectory.map { GitOperationInProgress.detect(gitDirectory: $0) == .cherryPick } ?? false
            if stopped {
                actions.append(.init("Resolve in Cherry Pick") { [weak self] in
                    self?.showWindow(nil)
                    self?.window?.makeKeyAndOrderFront(nil)
                })
            } else if outcome.succeeded {
                if noCommit {
                    actions.append(.init("Commit…") { CommandRouter.shared.execute(command: .commit, targetPath: root.rawPath) })
                }
                if stashed { actions.append(DirtyWorkingTree.stashPopAction(root)) }
                actions.append(.init("Show Log") { CommandRouter.shared.execute(command: .log, targetPath: root.rawPath) })
                if self?.isPicking == false { self?.close() }
            }
            return actions
        })
    }

    @objc private func continuePick() {
        run(title: "Cherry Pick Continue", arguments: ["cherry-pick", "--continue"])
    }

    @objc private func skip() {
        run(title: "Cherry Pick Skip", arguments: ["cherry-pick", "--skip"])
    }

    @objc private func abort() {
        let alert = NSAlert()
        alert.messageText = "Abort the cherry-pick?"
        alert.informativeText = "The branch returns to where it was before the cherry-pick started; commits already picked in this run are undone."
        alert.addButton(withTitle: "Abort Cherry-Pick")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(title: "Cherry Pick Abort", arguments: ["cherry-pick", "--abort"])
    }

    @objc private func closeClicked() {
        close()
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        switch tableColumn?.identifier.rawValue {
        case "Pick":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(pickToggled(_:)))
            box.state = item.pick ? .on : .off
            box.tag = row
            box.isEnabled = !isPicking
            return box
        case "Hash":
            let label = NSTextField(labelWithString: String(item.hash.prefix(8)))
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            return label
        case "Subject":
            let label = NSTextField(labelWithString: (item.isMerge ? "[merge] " : "") + item.subject)
            label.lineBreakMode = .byTruncatingTail
            label.textColor = item.pick ? .labelColor : .secondaryLabelColor
            return label
        default:
            return NSTextField(labelWithString: item.author)
        }
    }
}
