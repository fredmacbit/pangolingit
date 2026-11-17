import Cocoa
import PangolinGitCore

/// Interactive Rebase window mirroring TortoiseGit's `CRebaseDlg` (`src/TortoiseProc/RebaseDlg.cpp`):
/// Branch / Upstream / Onto choosers with swap, options (force, preserve merges, autostash, autosquash),
/// the commit list with per-commit actions (pick, reword, edit, squash, fixup, skip), keyboard shortcuts,
/// drag-and-drop ordering, and lower tabs (Commit Message, Revision Files, Conflict Files). Reopened
/// while a rebase is stopped it shows the steps done and left, the conflicts, and Continue / Skip /
/// Amend / Abort.
public final class RebaseWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    private struct Row {
        var step: GitRebaseStep
        let author: String
        var state: State

        enum State { case editable, done, current, pending }
    }

    private static let rowType = NSPasteboard.PasteboardType("be.macbit.pangolingit.rebase-row")

    private let repositoryPath: PangolinPath
    private var gitDirectory: PangolinPath?
    private var rows: [Row] = []
    private var progress: GitRebaseProgress?
    private var isInProgress: Bool { progress != nil }
    private var localBranches: [String] = []

    private let tableView = RebaseTableView()
    private let branchCombo = NSComboBox()
    private var upstreamChooser: RevisionChooserView!
    private let ontoCheckbox = NSButton(checkboxWithTitle: "Onto:", target: nil, action: nil)
    private let ontoField = NSTextField()
    private let forceCheckbox = NSButton(checkboxWithTitle: "Force Rebase", target: nil, action: nil)
    private let mergesCheckbox = NSButton(checkboxWithTitle: "Preserve Merges", target: nil, action: nil)
    private let autostashCheckbox = NSButton(checkboxWithTitle: "Autostash", target: nil, action: nil)
    private let autosquashCheckbox = NSButton(checkboxWithTitle: "Autosquash", target: nil, action: nil)
    private var setupControls: [NSControl] = []

    private let tabView = NSTabView()
    private let messageView = NSTextView()
    private let filesView = NSTextView()
    private var conflictList: ConflictListView!

    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Loading commits for rebase...")
    private let startButton = NSButton(title: "Start Rebase", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    private let amendButton = NSButton(title: "Amend…", target: nil, action: nil)
    private let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    private var editButtons: [NSButton] = []
    private var reloadWork: DispatchWorkItem?

    /// - Parameters:
    ///   - upstream: what to rebase onto (Log's *Rebase "current" onto this*); default the upstream branch.
    ///   - branch: branch to rebase; default the current one.
    public init(repositoryPath: PangolinPath, upstream: String? = nil, branch: String? = nil) {
        self.repositoryPath = repositoryPath
        let window = NSWindow(
            contentRect: NSRect(x: 150, y: 150, width: 860, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rebase - \(repositoryPath.filename)"
        window.minSize = NSSize(width: 720, height: 600)
        super.init(window: window)

        gitDirectory = GitRepository.open(at: repositoryPath)?.gitDirectory
        upstreamChooser = RevisionChooserView(repository: repositoryPath, kinds: [.branch, .tag, .commit],
                                              initialRevision: upstream ?? "@{upstream}")
        upstreamChooser.onChange = { [weak self] in self?.scheduleReload() }
        conflictList = ConflictListView(repositoryRoot: repositoryPath)
        conflictList.isRebase = true
        conflictList.onChange = { [weak self] count in self?.conflictsChanged(count) }
        branchCombo.stringValue = branch ?? ""
        setupUI()
        reload()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        branchCombo.placeholderString = "current branch"
        branchCombo.delegate = self
        branchCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let swapButton = NSButton(title: "⇅ Swap", target: self, action: #selector(onSwap))
        swapButton.toolTip = "Exchange branch and upstream"
        ontoCheckbox.target = self
        ontoCheckbox.action = #selector(onOptionChanged)
        ontoCheckbox.toolTip = "Replay the commits onto a different base (git rebase --onto)"
        ontoField.placeholderString = "new base, e.g. release"
        ontoField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let ontoPicker = RevisionPickerButton(repository: repositoryPath) { [weak self] in
            self?.ontoField.stringValue = $0
            self?.ontoCheckbox.state = .on
            self?.onOptionChanged()
        }
        forceCheckbox.toolTip = "Rewrite the commits even when the branch is already based on the upstream (--force-rebase)"
        mergesCheckbox.toolTip = "Keep merge commits (--rebase-merges); the commit list cannot be edited then"
        autostashCheckbox.toolTip = "Stash local changes before and restore them after the rebase (--autostash)"
        autosquashCheckbox.toolTip = "Move “fixup!” / “squash!” commits after the commit they fix (--autosquash)"
        for box in [mergesCheckbox, autosquashCheckbox] {
            box.target = self
            box.action = #selector(onOptionChanged)
        }

        let refsGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Branch:"), NSStackView(views: [branchCombo, swapButton])],
            [NSTextField(labelWithString: "Upstream:"), upstreamChooser],
            [ontoCheckbox, NSStackView(views: [ontoField, ontoPicker])],
        ])
        refsGrid.rowSpacing = 6
        refsGrid.columnSpacing = 10
        refsGrid.rowAlignment = .firstBaseline
        let optionsRow = NSStackView(views: [forceCheckbox, mergesCheckbox, autostashCheckbox, autosquashCheckbox])
        optionsRow.spacing = 16
        setupControls = [branchCombo, swapButton, ontoCheckbox, ontoField, ontoPicker, forceCheckbox, mergesCheckbox,
                         autostashCheckbox, autosquashCheckbox]

        // Commit list
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView
        for (id, title, width) in [("Action", "Action", 90.0), ("Hash", "Commit", 80.0), ("Subject", "Message", 420.0), ("Author", "Author", 140.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.registerForDraggedTypes([Self.rowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        tableView.onKeyCommand = { [weak self] command in self?.handle(command) ?? false }
        tableView.toolTip = "Space: cycle action · P pick · R reword · E edit · Q squash · F fixup · S skip · U/D move"

        // Lower tabs (RB-05)
        tabView.addTabViewItem(textTab("Commit Message", messageView))
        tabView.addTabViewItem(textTab("Revision Files", filesView))
        let conflictsTab = NSTabViewItem(identifier: "conflicts")
        conflictsTab.label = "Conflict Files"
        let conflictContainer = NSView()
        conflictContainer.addSubview(conflictList)
        NSLayoutConstraint.activate([
            conflictList.topAnchor.constraint(equalTo: conflictContainer.topAnchor, constant: 8),
            conflictList.leadingAnchor.constraint(equalTo: conflictContainer.leadingAnchor, constant: 8),
            conflictList.trailingAnchor.constraint(equalTo: conflictContainer.trailingAnchor, constant: -8),
            conflictList.bottomAnchor.constraint(equalTo: conflictContainer.bottomAnchor, constant: -8),
        ])
        conflictsTab.view = conflictContainer
        tabView.addTabViewItem(conflictsTab)

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(tabView)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        // Edit buttons
        let addButton = NSButton(title: "Add…", target: self, action: #selector(onAddFromLog))
        addButton.toolTip = "Add a commit from the log as an extra pick"
        let upButton = NSButton(title: "▲ Up", target: self, action: #selector(onMoveUp))
        let downButton = NSButton(title: "▼ Down", target: self, action: #selector(onMoveDown))
        let allButton = NSPopUpButton(frame: .zero, pullsDown: true)
        allButton.addItem(withTitle: "Set All")
        allButton.menu?.addItem(ClosureMenuItem(title: "Pick All") { [weak self] in self?.setAll(.pick) })
        allButton.menu?.addItem(ClosureMenuItem(title: "Squash All") { [weak self] in self?.setAll(.squash) })
        allButton.menu?.addItem(ClosureMenuItem(title: "Edit All") { [weak self] in self?.setAll(.edit) })
        allButton.menu?.addItem(ClosureMenuItem(title: "Skip Unselected") { [weak self] in self?.skipUnselected() })
        editButtons = [addButton, upButton, downButton, allButton]
        let editStack = NSStackView(views: editButtons)

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.isHidden = true
        progressBar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (button, action) in [(startButton, #selector(onStartRebase)), (continueButton, #selector(onContinueRebase)),
                                 (skipButton, #selector(onSkipCommit)), (amendButton, #selector(onAmend)),
                                 (abortButton, #selector(onAbortRebase))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        startButton.keyEquivalent = "\r"
        skipButton.toolTip = "Drop the commit git stopped at and go on (git rebase --skip)"
        amendButton.toolTip = "Change the message of the commit git stopped at (git commit --amend)"
        let actionStack = NSStackView(views: [startButton, continueButton, skipButton, amendButton, abortButton])
        let statusRow = NSStackView(views: [progressBar, statusLabel])

        for view in [refsGrid, optionsRow, split, editStack, statusRow, actionStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            refsGrid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            refsGrid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            refsGrid.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            optionsRow.topAnchor.constraint(equalTo: refsGrid.bottomAnchor, constant: 10),
            optionsRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            split.topAnchor.constraint(equalTo: optionsRow.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            split.bottomAnchor.constraint(equalTo: editStack.topAnchor, constant: -8),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            tabView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),

            editStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            editStack.bottomAnchor.constraint(equalTo: statusRow.topAnchor, constant: -10),
            statusRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            statusRow.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -10),
            actionStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            actionStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    private func textTab(_ label: String, _ textView: NSTextView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = textView
        item.view = scroll
        return item
    }

    // MARK: - Loading

    private var upstream: String {
        let value = upstreamChooser.revision
        return value.isEmpty ? "@{upstream}" : value
    }

    private var branch: String {
        branchCombo.stringValue.trimmingCharacters(in: .whitespaces)
    }

    /// Reloads the commit list shortly after a ref changes (not on every keystroke).
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Shows the stopped rebase if there is one (RB-02), otherwise the commits `upstream..branch` to arrange.
    private func reload() {
        let root = repositoryPath
        Task { @MainActor in
            let heads = (try? await GitCLIRunner.runAsync(arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"], workingDirectory: root)) ?? ""
            self.localBranches = heads.split(separator: "\n").map(String.init)
            if self.branchCombo.numberOfItems != self.localBranches.count {
                self.branchCombo.removeAllItems()
                self.branchCombo.addItems(withObjectValues: self.localBranches)
            }
            if let gitDirectory = self.gitDirectory, let progress = GitRebaseProgress.read(gitDirectory: gitDirectory) {
                await self.showInProgress(progress)
            } else {
                self.progress = nil
                self.cleanUpMessageFiles()
                await self.loadCommits()
            }
            self.updateControls()
        }
    }

    private func loadCommits() async {
        let range = "\(upstream)..\(branch.isEmpty ? "HEAD" : branch)"
        var args = ["log", "--reverse", "--topo-order", "--format=%H%x1f%s%x1f%an", range]
        if mergesCheckbox.state == .off { args.insert("--no-merges", at: 1) }
        do {
            let output = try await GitCLIRunner.runAsync(arguments: args, workingDirectory: repositoryPath)
            var steps: [GitRebaseStep] = []
            var authors: [String: String] = [:]
            for line in output.split(separator: "\n") {
                let fields = line.components(separatedBy: "\u{1f}")
                guard fields.count == 3 else { continue }
                steps.append(GitRebaseStep(hash: fields[0], subject: fields[1]))
                authors[fields[0]] = fields[2]
            }
            if autosquashCheckbox.state == .on {
                steps = GitRebaseTodo.autosquash(steps)
            }
            rows = steps.map { Row(step: $0, author: authors[$0.hash] ?? "", state: .editable) }
            statusLabel.stringValue = rows.isEmpty
                ? "No commits between \(upstream) and \(branch.isEmpty ? "HEAD" : branch)."
                : "\(rows.count) commit(s) to rebase onto \(upstream), oldest first."
        } catch {
            rows = []
            statusLabel.stringValue = "Choose a branch or commit to rebase onto (\(error.localizedDescription))."
        }
        tableView.reloadData()
        conflictList.reload()
    }

    private func showInProgress(_ progress: GitRebaseProgress) async {
        self.progress = progress
        var subjects: [String: (String, String)] = [:]
        let hashes = (progress.done + progress.remaining).map(\.hash).filter { !$0.isEmpty }
        if !hashes.isEmpty, let output = try? await GitCLIRunner.runAsync(
            arguments: ["log", "--no-walk=unsorted", "--format=%H%x1f%s%x1f%an"] + hashes, workingDirectory: repositoryPath) {
            for line in output.split(separator: "\n") {
                let fields = line.components(separatedBy: "\u{1f}")
                guard fields.count == 3 else { continue }
                subjects[fields[0]] = (fields[1], fields[2])
            }
        }
        func row(_ line: GitRebaseTodoLine, state: Row.State) -> Row? {
            guard let action = line.action else { return nil }
            let full = subjects.first { $0.key.hasPrefix(line.hash) }
            return Row(step: GitRebaseStep(action: action, hash: full?.key ?? line.hash, subject: full?.value.0 ?? line.subject),
                       author: full?.value.1 ?? "", state: state)
        }
        var newRows = progress.done.compactMap { row($0, state: .done) }
        if !newRows.isEmpty { newRows[newRows.count - 1].state = .current }
        newRows += progress.remaining.compactMap { row($0, state: .pending) }
        rows = newRows
        tableView.reloadData()
        if let current = rows.firstIndex(where: { $0.state == .current }) {
            tableView.scrollRowToVisible(current)
        }
        progressBar.maxValue = Double(max(progress.total, 1))
        progressBar.doubleValue = Double(progress.step)
        let branchName = GitReflog.shortName(progress.headName)
        statusLabel.stringValue = "Rebasing \(branchName.isEmpty ? "HEAD" : branchName) (\(progress.step)/\(progress.total))"
            + (progress.isEditStop ? " — stopped to edit; amend or continue." : " — stopped; resolve conflicts, then Continue.")
        conflictList.reload()
    }

    private func conflictsChanged(_ count: Int) {
        if let item = tabView.tabViewItems.first(where: { ($0.identifier as? String) == "conflicts" }) {
            item.label = count > 0 ? "Conflict Files (\(count))" : "Conflict Files"
            if count > 0 && isInProgress { tabView.selectTabViewItem(item) }
        }
        updateControls()
    }

    private func updateControls() {
        let editable = !isInProgress && mergesCheckbox.state == .off
        setupControls.forEach { $0.isEnabled = !isInProgress }
        ontoField.isEnabled = !isInProgress && ontoCheckbox.state == .on
        upstreamChooser.alphaValue = isInProgress ? 0.5 : 1
        editButtons.forEach { $0.isEnabled = editable }
        progressBar.isHidden = !isInProgress
        startButton.isEnabled = !isInProgress && (!rows.isEmpty || mergesCheckbox.state == .on)
        continueButton.isEnabled = isInProgress && conflictList.conflictedPaths.isEmpty
        skipButton.isEnabled = isInProgress
        amendButton.isEnabled = isInProgress && (progress?.isEditStop ?? false)
        abortButton.isEnabled = isInProgress
        window?.title = isInProgress ? "Rebase (in progress) - \(repositoryPath.filename)" : "Rebase - \(repositoryPath.filename)"
    }

    @objc private func onOptionChanged() {
        updateControls()
        scheduleReload()
    }

    @objc private func onSwap() {
        let oldBranch = branch
        let oldUpstream = upstreamChooser.revision
        guard localBranches.contains(oldUpstream) else {
            statusLabel.stringValue = "Swap needs a local branch as upstream."
            return
        }
        branchCombo.stringValue = oldUpstream
        upstreamChooser.setRevision(oldBranch.isEmpty ? "HEAD" : oldBranch)
        scheduleReload()
    }

    // MARK: - Editing the list (RB-04)

    private func handle(_ command: RebaseTableView.KeyCommand) -> Bool {
        guard !isInProgress, mergesCheckbox.state == .off else { return false }
        switch command {
        case .cycle:
            let rowsToChange = tableView.selectedRowIndexes
            guard let first = rowsToChange.first else { return false }
            setAction(RebaseTableView.nextAction(after: rows[first].step.action), rows: rowsToChange)
        case .set(let action):
            setAction(action, rows: tableView.selectedRowIndexes)
        case .moveUp:
            onMoveUp()
        case .moveDown:
            onMoveDown()
        }
        return true
    }

    /// Sets `action` on `indexes`; reword first asks for the new message (TortoiseGit edits it in the message pane).
    private func setAction(_ action: GitRebaseTodoLine.Action, rows indexes: IndexSet) {
        let valid = indexes.filter { $0 < rows.count && rows[$0].state == .editable }
        guard !valid.isEmpty else { return }
        if action == .reword {
            askForMessages(Array(valid))
            return
        }
        for index in valid {
            rows[index].step.action = action
            if action != .pick { rows[index].step.newMessage = nil }
        }
        reloadKeepingSelection()
    }

    /// Prompts for each row's new message in turn.
    private func askForMessages(_ indexes: [Int]) {
        guard let index = indexes.first else {
            reloadKeepingSelection()
            return
        }
        let step = rows[index].step
        let root = repositoryPath
        Task { @MainActor in
            var current = step.newMessage ?? step.subject
            if step.newMessage == nil,
               let full = try? await GitCLIRunner.runAsync(arguments: ["log", "-1", "--format=%B", step.hash], workingDirectory: root) {
                current = full
            }
            let sheet = TextInputSheet(title: "Reword \(String(step.hash.prefix(8)))", prompt: "New commit message:",
                                       initialText: current.trimmingCharacters(in: .whitespacesAndNewlines), okTitle: "Reword", multiline: true)
            sheet.validator = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The message cannot be empty." : nil }
            sheet.begin(on: self.window) { message in
                if let message, index < self.rows.count {
                    self.rows[index].step.action = .reword
                    self.rows[index].step.newMessage = message
                }
                self.askForMessages(Array(indexes.dropFirst()))
            }
        }
    }

    private func setAll(_ action: GitRebaseTodoLine.Action) {
        guard !rows.isEmpty, !isInProgress else { return }
        // "Squash All" keeps the first commit as the one everything is squashed into.
        let indexes = action == .squash ? IndexSet(integersIn: 1..<rows.count) : IndexSet(integersIn: 0..<rows.count)
        if action == .squash { rows[0].step.action = .pick }
        setAction(action, rows: indexes)
    }

    private func skipUnselected() {
        let selected = tableView.selectedRowIndexes
        setAction(.drop, rows: IndexSet(integersIn: 0..<rows.count).subtracting(selected))
    }

    private func reloadKeepingSelection() {
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
    }

    @objc private func onMoveUp() {
        let selection = tableView.selectedRowIndexes
        guard !isInProgress, let first = selection.first, first > 0 else { return }
        for index in selection { rows.swapAt(index, index - 1) }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(selection.map { $0 - 1 }), byExtendingSelection: false)
        tableView.scrollRowToVisible(first - 1)
    }

    @objc private func onMoveDown() {
        let selection = tableView.selectedRowIndexes
        guard !isInProgress, let last = selection.last, last < rows.count - 1 else { return }
        for index in selection.reversed() { rows.swapAt(index, index + 1) }
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(selection.map { $0 + 1 }), byExtendingSelection: false)
        tableView.scrollRowToVisible(last + 1)
    }

    /// Adds a commit picked in the Log as an extra `pick` at the end (TortoiseGit's *Add* from log).
    @objc private func onAddFromLog() {
        let root = repositoryPath
        WindowRegistry.shared.present({
            LogWindowController(repositoryPath: root) { [weak self] hash in self?.appendPick(hash) }
        }, repository: root)
    }

    private func appendPick(_ hash: String) {
        Task { @MainActor in
            guard let line = try? await GitCLIRunner.runAsync(arguments: ["log", "-1", "--format=%H%x1f%s%x1f%an", hash], workingDirectory: repositoryPath) else { return }
            let fields = line.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard fields.count == 3, !self.rows.contains(where: { $0.step.hash == fields[0] }) else { return }
            self.rows.append(Row(step: GitRebaseStep(hash: fields[0], subject: fields[1]), author: fields[2], state: .editable))
            self.tableView.reloadData()
            self.updateControls()
        }
    }

    // MARK: - Running

    /// Message files for reworded commits live in the git directory so they survive a stopped rebase.
    private var messageDirectory: PangolinPath? {
        gitDirectory?.appendingPathComponent("pangolin-rebase")
    }

    private func cleanUpMessageFiles() {
        if let dir = messageDirectory { try? FileManager.default.removeItem(atPath: dir.rawPath) }
    }

    private var options: GitRebaseOptions {
        var options = GitRebaseOptions(upstream: upstream)
        options.branch = branch.isEmpty ? nil : branch
        options.onto = ontoCheckbox.state == .on ? ontoField.stringValue.trimmingCharacters(in: .whitespaces) : nil
        options.forceRebase = forceCheckbox.state == .on
        options.rebaseMerges = mergesCheckbox.state == .on
        options.autostash = autostashCheckbox.state == .on
        options.autosquash = autosquashCheckbox.state == .on
        return options
    }

    @objc private func onStartRebase() {
        let steps = rows.map(\.step)
        let options = self.options
        if !options.rebaseMerges, let error = GitRebaseTodo.validationError(steps) {
            statusLabel.stringValue = error
            return
        }
        let root = repositoryPath
        Task { @MainActor in
            guard await self.confirmNotUpToDate(options) else { return }
            var stashed = false
            if !options.autostash {
                switch await DirtyWorkingTree.prepare(root, operation: "rebase", allowContinue: false, window: self.window) {
                case .cancel: return
                case .stashed: stashed = true
                case .proceed: break
                }
            }
            guard let environment = self.writeTodo(steps, preserveMerges: options.rebaseMerges) else { return }
            self.run(title: "Rebase", arguments: options.arguments, environment: environment, stashed: stashed)
        }
    }

    /// TortoiseGit's up-to-date / fast-forward detection: nothing to replay → say so (or force);
    /// branch behind upstream → offer a fast-forward instead.
    private func confirmNotUpToDate(_ options: GitRebaseOptions) async -> Bool {
        let base = options.onto ?? options.upstream
        let tip = options.branch ?? "HEAD"
        let root = repositoryPath
        func isAncestor(_ a: String, _ b: String) async -> Bool {
            ((try? await GitCLIRunner().run(arguments: ["merge-base", "--is-ancestor", a, b], workingDirectory: root))?.isSuccess) ?? false
        }
        if rows.isEmpty && !options.rebaseMerges, await isAncestor(tip, base) {
            let alert = NSAlert()
            alert.messageText = "Fast-forward possible"
            alert.informativeText = "\(tip) has no commits of its own; it can simply be moved forward to \(base)."
            alert.addButton(withTitle: "Fast-Forward")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                let args = options.branch.map { ["branch", "--force", $0, base] } ?? ["merge", "--ff-only", base]
                ProgressWindowController.run(title: "Fast-Forward", commands: [args], workingDirectory: root)
            }
            return false
        }
        if !options.forceRebase && options.onto == nil, await isAncestor(base, tip) {
            let alert = NSAlert()
            alert.messageText = "Already up to date"
            alert.informativeText = "\(tip) is already based on \(base). Rebase anyway to rewrite the commits as arranged?"
            alert.addButton(withTitle: "Rebase Anyway")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        return true
    }

    /// Writes the todo (and reword message files) and returns the environment that feeds it to git.
    private func writeTodo(_ steps: [GitRebaseStep], preserveMerges: Bool) -> [String: String]? {
        // With --rebase-merges git's own todo (labels, resets, merges) is used as is.
        if preserveMerges { return ["GIT_SEQUENCE_EDITOR": "true"] }
        guard let dir = messageDirectory else { return nil }
        do {
            try FileManager.default.createDirectory(atPath: dir.rawPath, withIntermediateDirectories: true)
            var files: [String: String] = [:]
            for step in steps where step.newMessage != nil {
                let file = dir.appendingPathComponent("\(step.hash).msg").rawPath
                try step.newMessage!.write(toFile: file, atomically: true, encoding: .utf8)
                files[step.hash] = file
            }
            let todo = GitRebaseTodo.render(steps) { files[$0.hash] }
            let todoFile = dir.appendingPathComponent("todo").rawPath
            try todo.write(toFile: todoFile, atomically: true, encoding: .utf8)
            let quoted = "'" + todoFile.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return ["GIT_SEQUENCE_EDITOR": "cp \(quoted)"]
        } catch {
            statusLabel.stringValue = "Could not write the rebase todo: \(error.localizedDescription)"
            return nil
        }
    }

    /// Runs a rebase step in the progress window; when git stops, this window shows the state.
    private func run(title: String, arguments: [String], environment: [String: String]? = nil, stashed: Bool = false) {
        let root = repositoryPath
        ProgressWindowController.run(title: title, commands: [arguments], workingDirectory: root, environment: environment,
                                     postActions: { [weak self] outcome in
            var actions: [ProgressWindowController.PostAction] = []
            let stillRebasing = self?.gitDirectory.flatMap { GitRebaseProgress.read(gitDirectory: $0) } != nil
            if stillRebasing {
                actions.append(.init("Show Rebase") { [weak self] in
                    self?.showWindow(nil)
                    self?.window?.makeKeyAndOrderFront(nil)
                })
            } else if outcome.succeeded {
                if stashed { actions.append(DirtyWorkingTree.stashPopAction(root)) }
                actions.append(.init("Show Log") { CommandRouter.shared.execute(command: .log, targetPath: root.rawPath) })
                actions.append(.init("Push…") { CommandRouter.shared.execute(command: .push, targetPath: root.rawPath) })
            }
            return actions
        })
    }

    @objc private func onContinueRebase() {
        run(title: "Rebase Continue", arguments: ["rebase", "--continue"])
    }

    @objc private func onSkipCommit() {
        run(title: "Rebase Skip", arguments: ["rebase", "--skip"])
    }

    /// At an `edit` stop: change the message of the commit just made (TortoiseGit's *Amend* at an edit step).
    @objc private func onAmend() {
        let root = repositoryPath
        Task { @MainActor in
            let message = (try? await GitCLIRunner.runAsync(arguments: ["log", "-1", "--format=%B", "HEAD"], workingDirectory: root)) ?? ""
            let sheet = TextInputSheet(title: "Amend Commit", prompt: "Message of the stopped commit (staged changes are included):",
                                       initialText: message.trimmingCharacters(in: .whitespacesAndNewlines), okTitle: "Amend", multiline: true)
            sheet.validator = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "The message cannot be empty." : nil }
            sheet.begin(on: self.window) { newMessage in
                guard let newMessage else { return }
                ProgressWindowController.run(title: "Amend", commands: [["commit", "--amend", "--allow-empty", "-m", newMessage]], workingDirectory: root)
            }
        }
    }

    @objc private func onAbortRebase() {
        let alert = NSAlert()
        alert.messageText = "Abort the rebase?"
        alert.informativeText = "The branch is restored to its state before the rebase started; resolutions made so far are lost."
        alert.addButton(withTitle: "Abort Rebase")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(title: "Rebase Abort", arguments: ["rebase", "--abort"])
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let item = rows[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let finished = item.state == .done
        if id == "Action" {
            if item.state == .editable && mergesCheckbox.state == .off {
                let popUp = NSPopUpButton()
                popUp.controlSize = .small
                for action in GitRebaseTodoLine.Action.allCases {
                    popUp.addItem(withTitle: action.title)
                    popUp.lastItem?.representedObject = action.rawValue
                }
                popUp.selectItem(withTitle: item.step.action.title)
                popUp.tag = row
                popUp.target = self
                popUp.action = #selector(onActionChanged(_:))
                return popUp
            }
            let marker = item.state == .current ? "▶ " : (finished ? "✓ " : "")
            let label = NSTextField(labelWithString: marker + item.step.action.title)
            label.textColor = item.state == .current ? .systemOrange : (finished ? .secondaryLabelColor : item.step.action.color)
            return label
        }
        let text: String
        switch id {
        case "Hash": text = String(item.step.hash.prefix(8))
        case "Subject": text = item.step.newMessage.map { $0.split(separator: "\n").first.map(String.init) ?? $0 } ?? item.step.subject
        default: text = item.author
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if id == "Hash" { label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) }
        label.textColor = finished || item.step.action == .drop ? .secondaryLabelColor : .labelColor
        if item.step.newMessage != nil && id == "Subject" { label.textColor = .systemBlue }
        return label
    }

    @objc private func onActionChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let action = GitRebaseTodoLine.Action(rawValue: raw) else { return }
        let indexes = tableView.selectedRowIndexes.contains(sender.tag) ? tableView.selectedRowIndexes : IndexSet(integer: sender.tag)
        setAction(action, rows: indexes)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        let step = rows[row].step
        let root = repositoryPath
        Task { @MainActor in
            let message = (try? await GitCLIRunner.runAsync(arguments: ["log", "-1", "--format=%B", step.hash], workingDirectory: root)) ?? ""
            let files = (try? await GitCLIRunner.runAsync(arguments: ["show", "--format=", "--name-status", "-M", step.hash], workingDirectory: root)) ?? ""
            guard self.tableView.selectedRow == row else { return }
            self.messageView.string = step.newMessage.map { "\($0)\n\n— original —\n\(message)" } ?? message
            self.filesView.string = files
        }
    }

    // Drag-and-drop reordering
    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard !isInProgress, mergesCheckbox.state == .off else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    public func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                          proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    public func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                          dropOperation: NSTableView.DropOperation) -> Bool {
        let sources = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) }.sorted()
        guard !sources.isEmpty else { return false }
        let moving = sources.map { rows[$0] }
        var target = row
        for index in sources.reversed() {
            rows.remove(at: index)
            if index < target { target -= 1 }
        }
        rows.insert(contentsOf: moving, at: target)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integersIn: target..<(target + moving.count)), byExtendingSelection: false)
        return true
    }

    // Context menu per commit
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = tableView.clickedRow
        guard clicked >= 0, clicked < rows.count else { return }
        if !tableView.selectedRowIndexes.contains(clicked) {
            tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        let selection = tableView.selectedRowIndexes
        if !isInProgress && mergesCheckbox.state == .off {
            for action in GitRebaseTodoLine.Action.allCases {
                menu.addItem(ClosureMenuItem(title: action.title) { [weak self] in self?.setAction(action, rows: selection) })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Move Up", symbol: "arrow.up") { [weak self] in self?.onMoveUp() })
            menu.addItem(ClosureMenuItem(title: "Move Down", symbol: "arrow.down") { [weak self] in self?.onMoveDown() })
            menu.addItem(.separator())
        }
        let hash = rows[clicked].step.hash
        let root = repositoryPath
        menu.addItem(ClosureMenuItem(title: "Show Changes", symbol: "plusminus") {
            WindowRegistry.shared.present({ DiffWindowController(filePath: root, oldRevision: "\(hash)^", newRevision: hash) }, repository: root)
        })
        menu.addItem(ClosureMenuItem(title: "Copy Commit Hash", symbol: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selection.map { self.rows[$0].step.hash }.joined(separator: "\n"), forType: .string)
        })
    }
}

extension RebaseWindowController: NSComboBoxDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        scheduleReload()
    }

    public func comboBoxSelectionDidChange(_ notification: Notification) {
        scheduleReload()
    }
}
