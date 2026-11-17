import Cocoa
import PangolinGitCore

/// Commit dialog window controller mirroring TortoiseGit's `CommitDlg.cpp`.
///
/// Split over several files: this one builds the window and loads the file list; `+Commit` runs
/// the commit; `+Message` holds the message helpers (history, sign-off, pickers, completion).
public final class CommitWindowController: NSWindowController, NSWindowDelegate {

    /// What the Commit button does; the last choice is remembered (TortoiseGit's split OK button).
    enum CommitAction: Int, CaseIterable {
        case commit, commitAndPush, reCommit

        var title: String {
            switch self {
            case .commit: return "Commit"
            case .commitAndPush: return "Commit & Push"
            case .reCommit: return "ReCommit"
            }
        }
    }

    enum DefaultsKey {
        static let lastAction = "PangolinGit.Commit.lastAction"
        static let showUnversioned = "PangolinGit.Commit.showUnversioned"
        static let noAutoselectSubmodules = "PangolinGit.Commit.noAutoselectSubmodules"
        static let viewPatch = "PangolinGit.Commit.viewPatch"
    }

    let repositoryPath: PangolinPath
    /// Paths (relative to the root) the dialog was opened for; empty means the whole working tree.
    let selection: [String]
    var repository: GitRepository?

    // Message area
    let messageTextView = CommitMessageTextView()
    let historyButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let signOffButton = NSButton(title: "Sign-off", target: nil, action: nil)
    let mergeBanner = NSTextField(labelWithString: "")
    let bugIDLabel = NSTextField(labelWithString: "Bug-ID:")
    let bugIDField = NSTextField()
    let bugIDRow = NSStackView()

    // Options
    let amendCheckbox = NSButton(checkboxWithTitle: "Amend Last Commit", target: nil, action: nil)
    let amendDiffCheckbox = NSButton(checkboxWithTitle: "Show diff to last commit", target: nil, action: nil)
    let messageOnlyCheckbox = NSButton(checkboxWithTitle: "Message only", target: nil, action: nil)
    let newBranchCheckbox = NSButton(checkboxWithTitle: "New branch:", target: nil, action: nil)
    let newBranchField = NSTextField()
    let setAuthorCheckbox = NSButton(checkboxWithTitle: "Set author:", target: nil, action: nil)
    let authorField = NSTextField()
    let setDateCheckbox = NSButton(checkboxWithTitle: "Set date:", target: nil, action: nil)
    let datePicker = NSDatePicker()
    let resetDateCheckbox = NSButton(checkboxWithTitle: "Reset to now", target: nil, action: nil)

    // File list
    let statusListView = StatusListView()
    let patchView = CommitPatchView()
    let listSplitView = NSSplitView()
    let quickSelectButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let showUnversionedCheckbox = NSButton(checkboxWithTitle: "Show Unversioned Files", target: nil, action: nil)
    let wholeProjectCheckbox = NSButton(checkboxWithTitle: "Whole Project", target: nil, action: nil)
    let noAutoselectSubmodulesCheckbox = NSButton(checkboxWithTitle: "Do not autoselect submodules", target: nil, action: nil)
    let stagingCheckbox = NSButton(checkboxWithTitle: "Staging", target: nil, action: nil)
    let viewPatchCheckbox = NSButton(checkboxWithTitle: "View Patch", target: nil, action: nil)

    // Footer
    let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    let commitActionButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "Loading repository...")
    let messageSplitView = NSSplitView()

    lazy var listActions = StatusListActions(repositoryRoot: repositoryPath)
    /// Paths listed by the previous status load, so a reload keeps the user's check marks.
    var knownPaths: Set<String> = []
    /// Paths added through the context menu; checked on the next reload.
    var pathsToCheck: Set<String> = []
    var isCommitting = false
    var commitAction: CommitAction = .commit

    // Loaded from the repository
    /// `commit.template` contents.
    var template: String?
    var commentChar: Character = "#"
    var bugtraq: BugtraqSettings?
    /// `tgit.logminsize`: Commit stays disabled below this many characters.
    var minimumMessageLength = 0
    /// `tgit.warnnosignedoffby`.
    var warnNoSignedOffBy = false
    var isMergeInProgress = false
    var isStagingEnabled = false
    /// HEAD's message (loaded when Amend is first ticked) and the message it replaced.
    var amendMessage: String?
    var messageBeforeAmend = ""
    /// Message file of the last commit run; kept until success so the progress window's Retry works.
    var messageFile: URL?
    /// ST-14: copies taken by "Restore after commit", put back once the commit is done.
    var restorePaths: [String: URL] = [:]

    public init(repositoryPath: PangolinPath, selection: [String] = []) {
        self.repositoryPath = repositoryPath
        self.selection = selection.filter { !$0.isEmpty }
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Commit — \(repositoryPath.filename)"
        window.minSize = NSSize(width: 780, height: 560)
        window.setFrameAutosaveName("PangolinGit.CommitWindow")
        super.init(window: window)
        window.delegate = self

        commitAction = CommitAction(rawValue: UserDefaults.standard.integer(forKey: DefaultsKey.lastAction)) ?? .commit
        setupUI()
        loadRepository()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in
            guard let self, !self.isCommitting else { return }
            self.reloadStatus()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let messageFile { try? FileManager.default.removeItem(at: messageFile) }
    }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let topPane = makeMessagePane()
        let bottomPane = makeFileListPane()

        messageSplitView.isVertical = false
        messageSplitView.dividerStyle = .thin
        messageSplitView.translatesAutoresizingMaskIntoConstraints = false
        messageSplitView.addArrangedSubview(topPane)
        messageSplitView.addArrangedSubview(bottomPane)
        messageSplitView.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        messageSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        commitButton.target = self
        commitButton.action = #selector(onCommitClicked)
        commitButton.bezelStyle = .rounded
        commitButton.keyEquivalent = "\r"
        commitButton.translatesAutoresizingMaskIntoConstraints = false

        commitActionButton.translatesAutoresizingMaskIntoConstraints = false
        commitActionButton.bezelStyle = .rounded
        commitActionButton.toolTip = "Choose what the Commit button does"
        commitActionButton.addItem(withTitle: "")
        for action in CommitAction.allCases {
            commitActionButton.addItem(withTitle: action.title)
            commitActionButton.lastItem?.tag = action.rawValue
        }
        commitActionButton.target = self
        commitActionButton.action = #selector(onCommitActionChosen(_:))
        updateCommitButtonTitle()

        cancelButton.target = self
        cancelButton.action = #selector(onCancelClicked)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // ESC
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [messageSplitView, statusLabel, cancelButton, commitButton, commitActionButton].forEach(contentView.addSubview)

        NSLayoutConstraint.activate([
            messageSplitView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            messageSplitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            messageSplitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            messageSplitView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: commitButton.leadingAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            cancelButton.widthAnchor.constraint(equalToConstant: 80),

            commitActionButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -12),
            commitActionButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            commitActionButton.widthAnchor.constraint(equalToConstant: 34),

            commitButton.trailingAnchor.constraint(equalTo: commitActionButton.leadingAnchor, constant: -2),
            commitButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            commitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])

        // Remembered divider positions (CM-20); first use gets a sensible message height.
        let hadSavedSplit = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames PangolinGit.Commit.MessageSplit") != nil
        messageSplitView.autosaveName = "PangolinGit.Commit.MessageSplit"
        listSplitView.autosaveName = "PangolinGit.Commit.ListSplit"
        if !hadSavedSplit {
            contentView.layoutSubtreeIfNeeded()
            messageSplitView.setPosition(300, ofDividerAt: 0)
            if patchView.superview != nil {
                listSplitView.setPosition(listSplitView.bounds.width * 0.55, ofDividerAt: 0)
            }
        }
    }

    /// Message editor, Bug-ID field and the commit options (TortoiseGit's upper dialog half).
    private func makeMessagePane() -> NSView {
        let pane = NSView()

        let header = NSTextField(labelWithString: "Commit Message:")
        header.font = NSFont.boldSystemFont(ofSize: 12)

        historyButton.bezelStyle = .rounded
        historyButton.addItem(withTitle: "Recent Messages")
        historyButton.menu?.delegate = self
        historyButton.toolTip = "Paste an earlier message (hold ⌥ to delete entries)"

        signOffButton.target = self
        signOffButton.action = #selector(onSignOffClicked)
        signOffButton.bezelStyle = .rounded
        signOffButton.toolTip = "Add a Signed-off-by line"

        let headerRow = NSStackView(views: [header, NSView(), historyButton, signOffButton])
        headerRow.orientation = .horizontal
        headerRow.spacing = 8

        mergeBanner.textColor = .systemOrange
        mergeBanner.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        mergeBanner.isHidden = true

        bugIDField.placeholderString = "Issue number(s)"
        bugIDRow.setViews([bugIDLabel, bugIDField], in: .leading)
        bugIDRow.orientation = .horizontal
        bugIDRow.spacing = 6
        bugIDRow.isHidden = true
        bugIDField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let messageScrollView = NSScrollView()
        messageScrollView.hasVerticalScroller = true
        messageScrollView.borderType = .bezelBorder
        messageTextView.configure()
        messageTextView.minSize = NSSize(width: 0, height: 0)
        messageTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        messageTextView.isVerticallyResizable = true
        messageTextView.autoresizingMask = [.width]
        messageTextView.textContainer?.widthTracksTextView = true
        messageScrollView.documentView = messageTextView
        messageTextView.onSubmit = { [weak self] in self?.onCommitClicked() }
        messageTextView.onTextChange = { [weak self] in self?.updateCommitButtonState() }
        messageTextView.extraMenuItems = { [weak self] in self?.messageMenuItems() ?? [] }

        for checkbox in [amendCheckbox, amendDiffCheckbox, messageOnlyCheckbox, newBranchCheckbox, setAuthorCheckbox,
                         setDateCheckbox, resetDateCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(onOptionToggled(_:))
        }
        amendDiffCheckbox.isEnabled = false
        amendDiffCheckbox.toolTip = "Compare with the parent of the last commit, so the diff shows what the amended commit will contain"
        messageOnlyCheckbox.toolTip = "Commit only the message, without file changes (--allow-empty)"
        newBranchField.placeholderString = "branch name"
        newBranchField.isEnabled = false
        authorField.placeholderString = "Name <email>"
        authorField.isEnabled = false
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        datePicker.dateValue = Date()
        datePicker.isEnabled = false
        resetDateCheckbox.isEnabled = false
        resetDateCheckbox.toolTip = "When amending, record the current time as author date"
        newBranchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        authorField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }
        let optionsLeft = NSStackView(views: [
            row([amendCheckbox, amendDiffCheckbox]),
            row([messageOnlyCheckbox]),
            row([newBranchCheckbox, newBranchField])
        ])
        let optionsRight = NSStackView(views: [
            row([setAuthorCheckbox, authorField]),
            row([setDateCheckbox, datePicker, resetDateCheckbox])
        ])
        for stack in [optionsLeft, optionsRight] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
        }
        let optionsRow = NSStackView(views: [optionsLeft, optionsRight])
        optionsRow.orientation = .horizontal
        optionsRow.alignment = .top
        optionsRow.spacing = 24

        // A stack drops the merge banner and Bug-ID row from the layout while they are hidden.
        let headerStack = NSStackView(views: [headerRow, mergeBanner, bugIDRow])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        headerRow.widthAnchor.constraint(equalTo: headerStack.widthAnchor).isActive = true

        for view in [headerStack, messageScrollView, optionsRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: pane.topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),

            messageScrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 4),
            messageScrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            messageScrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            messageScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

            optionsRow.topAnchor.constraint(equalTo: messageScrollView.bottomAnchor, constant: 8),
            optionsRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            optionsRow.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor),
            optionsRow.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -8)
        ])
        return pane
    }

    /// Quick-select links, list options, the file list and the patch pane.
    private func makeFileListPane() -> NSView {
        let pane = NSView()

        quickSelectButton.bezelStyle = .rounded
        quickSelectButton.addItem(withTitle: "Check")
        for (title, tag) in QuickSelect.menuEntries {
            quickSelectButton.addItem(withTitle: title)
            quickSelectButton.lastItem?.tag = tag
        }
        quickSelectButton.target = self
        quickSelectButton.action = #selector(onQuickSelect(_:))
        quickSelectButton.toolTip = "Check all files of a kind (TortoiseGit's Check: links)"

        let defaults = UserDefaults.standard
        showUnversionedCheckbox.state = (defaults.object(forKey: DefaultsKey.showUnversioned) as? Bool ?? true) ? .on : .off
        noAutoselectSubmodulesCheckbox.state = defaults.bool(forKey: DefaultsKey.noAutoselectSubmodules) ? .on : .off
        viewPatchCheckbox.state = defaults.bool(forKey: DefaultsKey.viewPatch) ? .on : .off
        wholeProjectCheckbox.isHidden = selection.isEmpty
        wholeProjectCheckbox.toolTip = "List every change in the working tree, not only those below the selected items"
        stagingCheckbox.toolTip = "Commit what is staged; check boxes and the patch pane stage and unstage (tgit.commitstagingsupport)"
        for checkbox in [showUnversionedCheckbox, wholeProjectCheckbox, noAutoselectSubmodulesCheckbox, stagingCheckbox, viewPatchCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(onListOptionToggled(_:))
            checkbox.controlSize = .small
            checkbox.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        let optionsRow = NSStackView(views: [quickSelectButton, showUnversionedCheckbox, wholeProjectCheckbox,
                                             noAutoselectSubmodulesCheckbox, NSView(), stagingCheckbox, viewPatchCheckbox])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 10

        statusListView.onDoubleClickItem = { [weak self] item in self?.showDiff(for: item) }
        listActions.didStage = { [weak self] paths in self?.pathsToCheck.formUnion(paths) }
        // Changelist groups; files in "ignore-on-commit" start unchecked (TortoiseGit's commit dialog).
        listActions.attach(to: statusListView, autosaveName: "Commit", uncheckIgnoreOnCommit: true)
        statusListView.onDropFiles = { [weak self] urls in self?.includeDroppedFiles(urls) }
        statusListView.contextMenuProvider = { [weak self] items in self?.fileMenu(for: items) }
        statusListView.onItemCheckToggled = { [weak self] item in self?.itemCheckToggled(item) }
        statusListView.onBulkCheckChanged = { [weak self] in self?.syncIndexToCheckMarks() }
        statusListView.onRowSelectionChanged = { [weak self] _ in self?.reloadPatchView() }
        statusListView.onSelectionChanged = { [weak self] _ in self?.updateCommitButtonState() }
        patchView.onApplyHunk = { [weak self] patch, reverse in self?.applyHunk(patch, reverse: reverse) }

        listSplitView.isVertical = true
        listSplitView.dividerStyle = .thin
        listSplitView.addArrangedSubview(statusListView)
        listSplitView.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        setPatchPaneVisible(viewPatchCheckbox.state == .on)
        statusListView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        patchView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        for view in [optionsRow, listSplitView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            optionsRow.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            optionsRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            optionsRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor),

            listSplitView.topAnchor.constraint(equalTo: optionsRow.bottomAnchor, constant: 6),
            listSplitView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            listSplitView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            listSplitView.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            listSplitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        return pane
    }

    /// The patch pane is added to and removed from the split view (a hidden split pane leaves its
    /// divider behind and conflicts with the list's constraints).
    func setPatchPaneVisible(_ visible: Bool) {
        if visible, patchView.superview == nil {
            listSplitView.addArrangedSubview(patchView)
            listSplitView.layoutSubtreeIfNeeded()
            listSplitView.setPosition(listSplitView.bounds.width * 0.55, ofDividerAt: 0)
        } else if !visible, patchView.superview != nil {
            listSplitView.removeArrangedSubview(patchView)
            patchView.removeFromSuperview()
        }
    }

    func updateCommitButtonTitle() {
        commitButton.title = commitAction.title
    }

    /// Commit needs a long-enough message (`tgit.logminsize`) and something to commit.
    func updateCommitButtonState() {
        guard !isCommitting else { return }
        let length = CommitMessage.cleanup(messageTextView.string, commentChar: commentChar).count
        commitButton.isEnabled = length >= max(minimumMessageLength, 1)
        if minimumMessageLength > 0 && length < minimumMessageLength {
            commitButton.toolTip = "The message needs at least \(minimumMessageLength) characters (tgit.logminsize)."
        } else {
            commitButton.toolTip = "⌘↩ commits from the message box"
        }
    }

    // MARK: - Loading

    private func loadRepository() {
        guard let repo = GitRepository.open(at: repositoryPath) else {
            statusLabel.stringValue = "Not a valid Git repository."
            return
        }
        self.repository = repo
        Task { @MainActor in
            await self.loadRepositorySettings(repo)
            self.reloadStatus()
        }
    }

    /// Reads the per-repository commit settings and pre-fills the message (merge message or template).
    private func loadRepositorySettings(_ repo: GitRepository) async {
        commentChar = await repo.commentChar()
        template = await repo.commitTemplate()
        bugtraq = await repo.bugtraqSettings()
        minimumMessageLength = Int(await repo.configValue("tgit.logminsize") ?? "") ?? 0
        warnNoSignedOffBy = await repo.configBool("tgit.warnnosignedoffby", default: false)
        isStagingEnabled = await repo.configBool("tgit.commitstagingsupport", default: false)
        messageTextView.widthMarkerColumn = Int(await repo.configValue("tgit.logwidthmarker") ?? "") ?? 0
        isMergeInProgress = repo.isMergeInProgress
        stagingCheckbox.state = isStagingEnabled ? .on : .off

        if let bugtraq {
            bugIDLabel.stringValue = bugtraq.label
            bugIDRow.isHidden = false
        }
        if isMergeInProgress {
            mergeBanner.stringValue = "A merge is in progress: the commit concludes it and includes every staged change."
            mergeBanner.isHidden = false
        }
        if messageTextView.string.isEmpty {
            let prefill = (isMergeInProgress ? repo.pendingMergeMessage : nil) ?? template ?? ""
            messageTextView.string = prefill
            messageTextView.applyMarkup()
            messageTextView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        messageTextView.snippets = Self.loadSnippets()
        updateCommitButtonState()
        window?.makeFirstResponder(messageTextView)
    }

    var showsWholeProject: Bool {
        selection.isEmpty || wholeProjectCheckbox.state == .on
    }

    /// Loads the status list. New entries get the default check state (tracked changes checked,
    /// unversioned files only with "commit all"); entries already listed keep theirs. With staging
    /// support the check marks show the index instead.
    func reloadStatus() {
        guard let repo = repository else { return }
        Task { @MainActor in
            do {
                let pathspec = showsWholeProject ? [] : selection
                let items = try await repo.getStatus(pathspec: pathspec)
                let branch = (try? await repo.getCurrentBranch()) ?? "?"
                let detached = await repo.isHeadDetached()
                var filtered = items.filter { $0.status != .ignored }
                if showUnversionedCheckbox.state != .on {
                    filtered = filtered.filter { $0.status != .untracked }
                }

                if isStagingEnabled {
                    statusListView.setItems(filtered) { Self.isStagedEntry($0) }
                    statusListView.mixedPaths = Set(filtered.filter(Self.isPartiallyStaged).map(\.path))
                } else {
                    let includeUnversioned = ConfigManager.shared.defaultCommitAll
                    let previouslyChecked = statusListView.allCheckedPaths
                    let known = knownPaths
                    let toCheck = pathsToCheck
                    let selection = self.selection
                    let noSubmodules = noAutoselectSubmodulesCheckbox.state == .on
                    let merging = isMergeInProgress
                    statusListView.mixedPaths = []
                    statusListView.setItems(filtered) { item in
                        if toCheck.contains(item.path) { return true }
                        if known.contains(item.path) { return previouslyChecked.contains(item.path) }
                        if merging { return true }
                        if item.isSubmodule && noSubmodules { return false }
                        // With Whole Project, changes outside the Finder selection start unchecked (CM-22).
                        if !selection.isEmpty && !selection.contains(where: { item.path == $0 || item.path.hasPrefix($0 + "/") }) {
                            return false
                        }
                        return includeUnversioned || item.status != .untracked
                    }
                }
                knownPaths = Set(filtered.map(\.path))
                pathsToCheck.removeAll()
                let place = detached ? "detached HEAD" : "Branch: \(branch)"
                let restoring = restorePaths.isEmpty ? "" : " — \(restorePaths.count) file(s) restored after commit"
                statusLabel.stringValue = "\(place) (\(filtered.count) changed files)\(restoring)"
                updateCommitButtonState()
                reloadPatchView()
                updateCompletionWords(filtered)
            } catch {
                statusLabel.stringValue = "Error loading status: \(error.localizedDescription)"
            }
        }
    }

    /// In staging mode a row is checked when the index holds changes for it.
    static func isStagedEntry(_ item: GitItemStatusInfo) -> Bool {
        item.stagedStatus != nil && !item.isConflicted
    }

    /// Staged, with further changes in the working tree (the mixed checkbox).
    static func isPartiallyStaged(_ item: GitItemStatusInfo) -> Bool {
        guard isStagedEntry(item) else { return false }
        return item.status == .stagedModified || item.status == .missing
            || (item.stagedStatus == .added && item.status == .modified)
    }

    /// Files dropped from Finder (SH-09): unversioned ones are added, and all of them are checked
    /// (TortoiseGit's commit dialog accepts dropped files the same way).
    private func includeDroppedFiles(_ urls: [URL]) {
        var files: [String] = []
        // Folders are added as a whole so git skips their ignored content instead of failing on it.
        var folders: [String] = []
        for url in urls {
            guard let relative = PangolinPath(url: url).relative(to: repositoryPath), !relative.isEmpty,
                  !relative.hasPrefix(".git") else { continue }
            if PangolinPath(url: url).isDirectory {
                folders.append(relative)
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
                while let child = enumerator?.nextObject() as? URL {
                    if child.lastPathComponent == ".git" { enumerator?.skipDescendants(); continue }
                    if (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                       let path = PangolinPath(url: child).relative(to: repositoryPath) {
                        files.append(path)
                    }
                }
            } else {
                files.append(relative)
            }
        }
        guard !files.isEmpty || !folders.isEmpty else { return }
        pathsToCheck.formUnion(files)
        let listed = statusListView.listedItems
        let tracked = Set(listed.filter { $0.status != .untracked }.map(\.path))
        let droppedFiles = Set(files).subtracting(folders.flatMap { folder in files.filter { $0.hasPrefix(folder + "/") } })
        let toAdd = folders + droppedFiles.filter { !tracked.contains($0) }.sorted()
        guard !toAdd.isEmpty else {
            reloadStatus()
            return
        }
        Task { @MainActor in
            do {
                // `git add` is a mutation, so the list reloads by itself and checks `pathsToCheck`.
                try await GitCLIRunner.runAsync(arguments: ["add", "--"] + toAdd, workingDirectory: repositoryPath)
            } catch {
                NSAlert(error: error).runModal()
                reloadStatus()
            }
        }
    }

    // MARK: - File list

    private func fileMenu(for items: [StatusListItem]) -> NSMenu? {
        let menu = listActions.menu(for: items, listed: statusListView.listedItems) ?? NSMenu()
        let restorable = items.filter { $0.status != .untracked && $0.status != .deleted && $0.status != .missing && !$0.info.isDirectory }
        guard !restorable.isEmpty else { return menu.items.isEmpty ? nil : menu }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let marked = restorable.filter { restorePaths[$0.path] != nil }
        if marked.count == restorable.count {
            menu.addItem(ClosureMenuItem(title: "Restore Now", symbol: "arrow.uturn.backward") { [weak self] in
                self?.restoreFiles(marked.map(\.path))
            })
        } else {
            menu.addItem(ClosureMenuItem(title: "Restore after commit", symbol: "clock.arrow.circlepath") { [weak self] in
                self?.markForRestore(restorable.map(\.path))
            })
        }
        return menu
    }

    /// Double-click: diff against HEAD, or against HEAD's parent with "Show diff to last commit".
    private func showDiff(for item: StatusListItem) {
        let fullPath = repositoryPath.appending(item.path)
        let base = amendCheckbox.state == .on && amendDiffCheckbox.state == .on ? "HEAD~1" : "HEAD"
        DiffWindowController.present(filePath: fullPath, oldRevision: base, repository: repositoryPath)
    }

    // MARK: - Staging (CM-12)

    /// Staging mode: ticking a row stages the whole file, unticking unstages it.
    private func itemCheckToggled(_ item: StatusListItem) {
        guard isStagingEnabled, let repo = repository else { return }
        Task { @MainActor in
            do {
                if item.isChecked {
                    try await repo.stage(paths: [item.path])
                } else {
                    try await repo.unstage(paths: [item.path] + (item.info.originalPath.map { [$0] } ?? []))
                }
            } catch {
                statusLabel.stringValue = "Staging failed: \(error.localizedDescription)"
                reloadStatus()
            }
        }
    }

    /// Staging mode after Select All / None / a quick-select entry: make the index follow the check marks.
    func syncIndexToCheckMarks() {
        guard isStagingEnabled, let repo = repository else { return }
        let items = statusListView.listedItems
        let toStage = items.filter { $0.isChecked && (!Self.isStagedEntry($0.info) || Self.isPartiallyStaged($0.info)) }.map(\.path)
        let toUnstage = items.filter { !$0.isChecked && Self.isStagedEntry($0.info) }
            .flatMap { [$0.path] + ($0.info.originalPath.map { [$0] } ?? []) }
        statusListView.mixedPaths = []
        Task { @MainActor in
            do {
                if !toStage.isEmpty { try await repo.stage(paths: toStage) }
                if !toUnstage.isEmpty { try await repo.unstage(paths: toUnstage) }
            } catch {
                statusLabel.stringValue = "Staging failed: \(error.localizedDescription)"
                reloadStatus()
            }
        }
    }

    private func applyHunk(_ patch: String, reverse: Bool) {
        guard let repo = repository else { return }
        Task { @MainActor in
            do {
                try await repo.applyToIndex(patch: patch, reverse: reverse)
            } catch {
                statusLabel.stringValue = (reverse ? "Unstaging" : "Staging") + " the hunk failed: \(error.localizedDescription)"
            }
        }
    }

    /// Shows the highlighted file's changes in the patch pane.
    func reloadPatchView() {
        guard viewPatchCheckbox.state == .on, let repo = repository else { return }
        guard let item = statusListView.selectedItem else {
            patchView.showMessage("Select a file to see its changes.")
            return
        }
        let path = item.path
        let staging = isStagingEnabled
        let amendDiff = amendCheckbox.state == .on && amendDiffCheckbox.state == .on
        let fileURL = repositoryPath.appending(path).url
        Task { @MainActor in
            let hasHead = await Task.detached { repo.hasHead }.value
            let base = amendDiff ? "HEAD~1" : (hasHead ? "HEAD" : nil)
            if item.info.isDirectory || item.info.isSubmodule {
                patchView.showMessage("No patch for folders and submodules.", title: path)
                return
            }
            if item.status == .untracked {
                patchView.show(path: path, unstaged: Self.newFileDiff(path: path, url: fileURL), staged: nil, canStage: false)
                return
            }
            do {
                if staging {
                    let unstaged = try await repo.fileDiff(path, staged: false)
                    let staged = try await repo.fileDiff(path, staged: true)
                    let canStage = !item.info.isConflicted
                    patchView.show(path: path, unstaged: unstaged, staged: staged, canStage: canStage)
                } else {
                    let diff = try await repo.diff(path: path, cached: base == nil, commit: base)
                    patchView.show(path: path, unstaged: diff, staged: nil, canStage: false)
                }
            } catch {
                patchView.showMessage(error.localizedDescription, title: path)
            }
        }
    }

    /// An untracked text file as an all-added diff (the patch pane's view of a new file).
    static func newFileDiff(path: String, url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 512 * 1024,
              !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return "Binary files /dev/null and b/\(path) differ"
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return "" }
        return (["--- /dev/null", "+++ b/\(path)", "@@ -0,0 +1,\(lines.count) @@"] + lines.map { "+" + $0 }).joined(separator: "\n")
    }

    // MARK: - Options

    @objc private func onOptionToggled(_ sender: NSButton) {
        switch sender {
        case amendCheckbox:
            amendToggled()
        case amendDiffCheckbox:
            reloadPatchView()
        case messageOnlyCheckbox:
            statusListView.alphaValue = sender.state == .on ? 0.5 : 1
        case newBranchCheckbox:
            newBranchField.isEnabled = sender.state == .on
            if sender.state == .on { window?.makeFirstResponder(newBranchField) }
        case setAuthorCheckbox:
            authorField.isEnabled = sender.state == .on
            if sender.state == .on && authorField.stringValue.isEmpty {
                prefillAuthor()
            }
        case setDateCheckbox, resetDateCheckbox:
            break
        default:
            break
        }
        let amending = amendCheckbox.state == .on
        resetDateCheckbox.isEnabled = amending && setDateCheckbox.state == .on
        datePicker.isEnabled = setDateCheckbox.state == .on && !(resetDateCheckbox.isEnabled && resetDateCheckbox.state == .on)
    }

    /// CM-05: ticking Amend loads HEAD's message (the typed one comes back when it is unticked).
    private func amendToggled() {
        let amending = amendCheckbox.state == .on
        amendDiffCheckbox.isEnabled = amending
        if !amending { amendDiffCheckbox.state = .off }
        if setAuthorCheckbox.state == .on { prefillAuthor() }
        guard let repo = repository else { return }
        if amending {
            messageBeforeAmend = messageTextView.string
            Task { @MainActor in
                if amendMessage == nil {
                    amendMessage = try? await repo.commitMessage()
                }
                guard amendCheckbox.state == .on, let amendMessage else { return }
                setMessage(amendMessage)
            }
        } else if let amendMessage, messageTextView.string == amendMessage {
            setMessage(messageBeforeAmend)
        }
        reloadPatchView()
    }

    private func prefillAuthor() {
        guard let repo = repository else { return }
        let ofHead = amendCheckbox.state == .on
        Task { @MainActor in
            if let author = await repo.authorString(ofHead: ofHead) {
                authorField.stringValue = author
            }
        }
    }

    @objc private func onListOptionToggled(_ sender: NSButton) {
        let defaults = UserDefaults.standard
        switch sender {
        case showUnversionedCheckbox:
            defaults.set(sender.state == .on, forKey: DefaultsKey.showUnversioned)
        case noAutoselectSubmodulesCheckbox:
            defaults.set(sender.state == .on, forKey: DefaultsKey.noAutoselectSubmodules)
            if sender.state == .on {
                statusListView.setChecked(false) { $0.info.isSubmodule }
                syncIndexToCheckMarks()
            }
        case viewPatchCheckbox:
            defaults.set(sender.state == .on, forKey: DefaultsKey.viewPatch)
            setPatchPaneVisible(sender.state == .on)
        case stagingCheckbox:
            isStagingEnabled = sender.state == .on
            knownPaths = []
            if let repo = repository {
                Task { _ = try? await repo.configSet(key: "tgit.commitstagingsupport", value: isStagingEnabled ? "true" : "false") }
            }
        default:
            break
        }
        reloadStatus()
    }

    @objc private func onQuickSelect(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, let kind = QuickSelect(rawValue: tag) else { return }
        if kind == .none {
            statusListView.setChecked(false) { _ in true }
        } else {
            let noSubmodules = noAutoselectSubmodulesCheckbox.state == .on
            statusListView.setChecked(true) { kind.matches($0.info, skipSubmodules: noSubmodules) }
        }
        syncIndexToCheckMarks()
    }

    @objc private func onCommitActionChosen(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag, let action = CommitAction(rawValue: tag) else { return }
        commitAction = action
        UserDefaults.standard.set(action.rawValue, forKey: DefaultsKey.lastAction)
        updateCommitButtonTitle()
        onCommitClicked()
    }

    // MARK: - Closing (CM-18)

    @objc private func onCancelClicked() {
        if windowShouldClose(window!) { close() }
    }

    /// Asks before throwing away a typed message; the message is kept in the history either way,
    /// and files marked "Restore after commit" can be put back (TortoiseGit's `OnCancel`).
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isCommitting else { return false }
        let message = CommitMessage.cleanup(messageTextView.string, commentChar: commentChar)
        let untouched = message.isEmpty
            || message == CommitMessage.cleanup(template ?? "", commentChar: commentChar)
            || message == CommitMessage.cleanup(amendMessage ?? "", commentChar: commentChar)
        if !untouched {
            let alert = NSAlert()
            alert.messageText = "Discard the commit?"
            alert.informativeText = "Your message is kept under Recent Messages, so you can paste it next time."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep Editing")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            ConfigManager.shared.addRecentCommitMessage(message, forRepository: repositoryPath.rawPath)
        }
        if !restorePaths.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Restore the files marked “Restore after commit”?"
            alert.informativeText = restorePaths.keys.sorted().joined(separator: "\n")
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Keep Current Files")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: restoreFiles(Array(restorePaths.keys))
            case .alertSecondButtonReturn: restorePaths.removeAll()
            default: return false
            }
        }
        return true
    }
}

/// TortoiseGit's "Check:" links (`IDC_CHECKALL` … `IDC_CHECKSUBMODULES`).
enum QuickSelect: Int {
    case all = 1, none, unversioned, versioned, added, deleted, modified, files, submodules

    static let menuEntries: [(String, Int)] = [
        ("All", QuickSelect.all.rawValue), ("None", QuickSelect.none.rawValue),
        ("Unversioned", QuickSelect.unversioned.rawValue), ("Versioned", QuickSelect.versioned.rawValue),
        ("Added", QuickSelect.added.rawValue), ("Deleted", QuickSelect.deleted.rawValue),
        ("Modified", QuickSelect.modified.rawValue), ("Files", QuickSelect.files.rawValue),
        ("Submodules", QuickSelect.submodules.rawValue)
    ]

    /// Whether a row belongs to this group; submodules are skipped unless asked for explicitly
    /// while "Do not autoselect submodules" is on (`CGitStatusListCtrl::Check`).
    func matches(_ item: GitItemStatusInfo, skipSubmodules: Bool) -> Bool {
        if item.isSubmodule && skipSubmodules && self != .submodules { return false }
        switch self {
        case .all: return true
        case .none: return false
        case .unversioned: return item.status == .untracked
        case .versioned: return item.status != .untracked
        case .added: return item.status == .added || item.stagedStatus == .added || item.status == .copied
        case .deleted: return item.status == .deleted || item.status == .missing
        case .modified: return [.modified, .stagedModified, .staged, .renamed].contains(item.status)
        case .files: return !item.isSubmodule && !item.isDirectory
        case .submodules: return item.isSubmodule
        }
    }
}
