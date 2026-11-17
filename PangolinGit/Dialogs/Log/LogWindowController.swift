import Cocoa
import CryptoKit
import PangolinGitCore

/// Commit log mirroring TortoiseGit's `CLogDlg` (`src/TortoiseProc/LogDlg.cpp`) and its list
/// `CGitLogListBase`: ref/range, date and walk filters, search syntax, ref labels, lane graph,
/// a "Working tree changes" row, commit details and the changed files of the selected commit.
/// Context menus live in `LogWindowController+Menus.swift`.
public final class LogWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                        NSTextViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {

    public let repositoryPath: PangolinPath
    var repository: GitRepository?
    /// Picker mode (TortoiseGit's `…` buttons next to revision fields): called with the chosen
    /// commit hash, then the window closes.
    let pickerCompletion: ((String) -> Void)?
    let config = ConfigManager.shared

    // MARK: Model

    var query = GitLogQuery()
    /// Path filter kept while "Show whole project" is on, so it can be restored.
    private var suspendedPath: String?
    /// Everything git returned for the query, newest first.
    var entries: [GitLogEntry] = []
    /// Lanes computed over `entries` (parallel array) so the graph stays drawn while searching.
    private var graphRows: [RevisionGraphView.GraphRow] = []
    /// Indexes into `entries` of the rows that pass the search filter.
    private var visible: [Int] = []
    private var indexByHash: [String: Int] = [:]
    var refMap = GitRefMap()
    /// Uncommitted changes shown in the "Working tree changes" row (TortoiseGit's virtual entry).
    var workingTreeChanges: [GitItemStatusInfo] = []
    /// Changed paths per commit, loaded on demand for the "Paths" search field.
    private var pathsByHash: [String: [String]]?
    private var loadingPaths = false
    private var describeCache: [String: String] = [:]
    private var describePending = Set<String>()
    /// Files of the selected commit (or working tree) and those currently listed.
    var changedFiles: [GitChangedFile] = []
    var listedFiles: [GitChangedFile] = []
    /// The parent `changedFiles` was diffed against (nil = root commit / working tree).
    var changedFilesParent: String?
    var changedFilesParentIndex = 0
    private var loadGeneration = 0
    /// True while the log is being read (drives the spinner; tests wait for it).
    private(set) var isLoading = false
    private var detailGeneration = 0
    private var selectionHistory: [String] = []
    private var historyIndex = -1
    private var navigatingHistory = false
    private var hashToSelectAfterLoad: String?
    private var keyMonitor: Any?

    // MARK: Views

    let tableView = LogTableView()
    let changedFilesTableView = LogTableView()
    let commitDetailTextView = NSTextView()
    private let avatarView = NSImageView()
    private let splitView = NSSplitView()
    private let lowerSplitView = NSSplitView()
    let searchField = NSSearchField()
    private let refButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let fromCheck = NSButton(checkboxWithTitle: "From:", target: nil, action: nil)
    private let toCheck = NSButton(checkboxWithTitle: "To:", target: nil, action: nil)
    private let fromPicker = NSDatePicker()
    private let toPicker = NSDatePicker()
    private let limitField = NSTextField()
    private let limitPopup = NSPopUpButton()
    private let viewButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let goButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let historyControl = NSSegmentedControl()
    private let pathLabel = NSTextField(labelWithString: "")
    private let wholeProjectButton = NSButton(title: "Show Whole Project", target: nil, action: nil)
    private let pathBar = NSStackView()
    let statusLabel = NSTextField(labelWithString: "Loading commit log…")
    private let spinner = NSProgressIndicator()
    private let nextButton = NSButton(title: "Next 100", target: nil, action: nil)
    private let showAllButton = NSButton(title: "Show All", target: nil, action: nil)

    private static let limitKinds = ["all", "commits", "years", "months", "weeks"]

    /// - Parameters:
    ///   - path: repository-relative file or folder to show the history of (Show Log on a file).
    ///   - revisions: refs or a range (`A..B`) to start from instead of the remembered scope.
    public init(repositoryPath: PangolinPath, path: String? = nil, revisions: [String]? = nil,
                pickerCompletion: ((String) -> Void)? = nil) {
        self.repositoryPath = repositoryPath
        self.pickerCompletion = pickerCompletion
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1120, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let place = path.flatMap { $0.isEmpty ? nil : $0 } ?? repositoryPath.filename
        window.title = (pickerCompletion == nil ? "Git Log" : "Select Commit") + " — \(place)"
        window.minSize = NSSize(width: 820, height: 520)
        window.setFrameAutosaveName("PangolinGitLogWindow")
        super.init(window: window)

        query.limit = config.logDefaultLimit
        query.useMailmap = config.useMailmap
        if let path, !path.isEmpty {
            query.path = path
            // Renames can only be followed for a single file.
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: repositoryPath.appending(path).rawPath, isDirectory: &isDirectory)
            query.followRenames = !isDirectory.boolValue
        }
        if let revisions, !revisions.isEmpty {
            query.scope = .refs(revisions)
        } else {
            query.scope = Self.scope(fromSetting: config.logScope(forRepository: repositoryPath.rawPath))
        }

        setupUI()
        syncControlsFromQuery()
        loadLog()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.loadLog() }
        installKeyMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    static func scope(fromSetting value: String) -> GitLogQuery.Scope {
        switch value {
        case "all": return .allRefs
        case "basic": return .basicRefs
        case "local": return .localBranches
        default: return .current
        }
    }

    // MARK: - Layout

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Row 1: what to walk.
        refButton.addItem(withTitle: "HEAD")
        refButton.menu?.delegate = self
        refButton.toolTip = "Branch, tag, range or all branches to show (TortoiseGit's branch button)"
        refButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        for (check, picker) in [(fromCheck, fromPicker), (toCheck, toPicker)] {
            check.target = self
            check.action = #selector(onDateFilterChanged)
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .yearMonthDay
            picker.dateValue = Date()
            picker.target = self
            picker.action = #selector(onDateFilterChanged)
        }
        fromPicker.dateValue = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()

        let showLabel = NSTextField(labelWithString: "Show:")
        limitPopup.addItems(withTitles: ["All", "Last N commits", "Last N years", "Last N months", "Last N weeks"])
        limitPopup.target = self
        limitPopup.action = #selector(onLimitChanged)
        limitField.target = self
        limitField.action = #selector(onLimitChanged)
        limitField.alignment = .right
        limitField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        viewButton.addItem(withTitle: "View")
        viewButton.menu?.delegate = self
        viewButton.toolTip = "Walk options and what the list shows"

        let statisticsButton = NSButton(title: "Statistics", target: self, action: #selector(onStatistics))
        statisticsButton.toolTip = "Statistics of the revisions shown"
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(onRefresh))
        refreshButton.keyEquivalent = "r"
        refreshButton.keyEquivalentModifierMask = .command
        refreshButton.toolTip = "Reload the log (⌘R)"

        let row1 = NSStackView(views: [refButton, fromCheck, fromPicker, toCheck, toPicker, showLabel, limitField, limitPopup,
                                       viewButton, NSView(), statisticsButton, refreshButton])
        row1.spacing = 6
        row1.setHuggingPriority(.defaultLow, for: .horizontal)

        // Row 2: search and navigation.
        searchField.placeholderString = "Filter (terms, -exclude, +or, \"phrase\", ! inverts)"
        searchField.target = self
        searchField.action = #selector(onFilterChanged)
        searchField.delegate = self
        rebuildSearchMenu()

        historyControl.segmentCount = 2
        historyControl.trackingMode = .momentary
        historyControl.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back"), forSegment: 0)
        historyControl.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward"), forSegment: 1)
        historyControl.setToolTip("Back in selection history (⌥←)", forSegment: 0)
        historyControl.setToolTip("Forward in selection history (⌥→)", forSegment: 1)
        historyControl.target = self
        historyControl.action = #selector(onHistoryClicked)

        goButton.addItem(withTitle: "Go To")
        goButton.menu?.delegate = self
        goButton.toolTip = "Jump to a related commit"

        let row2 = NSStackView(views: [searchField, historyControl, goButton])
        row2.spacing = 6
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Path filter bar (LG-04).
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        wholeProjectButton.setButtonType(.pushOnPushOff)
        wholeProjectButton.bezelStyle = .rounded
        wholeProjectButton.controlSize = .small
        wholeProjectButton.target = self
        wholeProjectButton.action = #selector(onWholeProjectToggled)
        pathBar.setViews([pathLabel, wholeProjectButton], in: .leading)
        pathBar.spacing = 8

        let topStack = NSStackView(views: [row1, row2, pathBar])
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 6
        for row in [row1, row2] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: topStack.widthAnchor).isActive = true
        }
        topStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topStack)

        // Commit table.
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.autosaveName = "PangolinGitLogSplit"
        splitView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitView)

        let tableScrollView = NSScrollView()
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = true
        tableScrollView.borderType = .bezelBorder
        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 30
            tableColumn.isHidden = column.hidden
            tableView.addTableColumn(tableColumn)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = pickerCompletion == nil
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(onCommitDoubleClicked)
        tableView.onReturn = { [weak self] in self?.activateCommit(fromKeyboard: true) }
        tableView.onOptionArrow = { [weak self] key in self?.handleOptionArrow(key) ?? false }
        let commitMenu = NSMenu(title: "Commit")
        commitMenu.delegate = self
        tableView.menu = commitMenu
        let headerMenu = NSMenu(title: "Columns")
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
        tableView.autosaveName = "PangolinGitLogColumns"
        tableView.autosaveTableColumns = true
        tableScrollView.documentView = tableView
        splitView.addSubview(tableScrollView)

        // Lower pane: details | changed files.
        lowerSplitView.isVertical = true
        lowerSplitView.dividerStyle = .thin
        lowerSplitView.autosaveName = "PangolinGitLogLowerSplit"

        let messageScrollView = NSScrollView()
        messageScrollView.hasVerticalScroller = true
        messageScrollView.borderType = .bezelBorder
        commitDetailTextView.isEditable = false
        commitDetailTextView.isSelectable = true
        commitDetailTextView.delegate = self
        commitDetailTextView.textContainerInset = NSSize(width: 4, height: 4)
        commitDetailTextView.isVerticallyResizable = true
        commitDetailTextView.autoresizingMask = [.width]
        commitDetailTextView.textContainer?.widthTracksTextView = true
        messageScrollView.documentView = commitDetailTextView
        let detailContainer = NSView()
        messageScrollView.frame = detailContainer.bounds
        messageScrollView.autoresizingMask = [.width, .height]
        detailContainer.addSubview(messageScrollView)
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 6
        avatarView.layer?.masksToBounds = true
        avatarView.isHidden = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(avatarView)
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 6),
            avatarView.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -20),
            avatarView.widthAnchor.constraint(equalToConstant: 48),
            avatarView.heightAnchor.constraint(equalToConstant: 48)
        ])
        lowerSplitView.addSubview(detailContainer)

        let changedFilesScrollView = NSScrollView()
        changedFilesScrollView.hasVerticalScroller = true
        changedFilesScrollView.borderType = .bezelBorder
        for (id, title, width) in [("ChangeStatus", "Action", 60.0), ("ChangePath", "Path", 330.0),
                                   ("ChangeAdded", "+", 48.0), ("ChangeRemoved", "−", 48.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            changedFilesTableView.addTableColumn(column)
        }
        changedFilesTableView.usesAlternatingRowBackgroundColors = true
        changedFilesTableView.rowHeight = 20
        changedFilesTableView.allowsMultipleSelection = true
        changedFilesTableView.dataSource = self
        changedFilesTableView.delegate = self
        changedFilesTableView.target = self
        changedFilesTableView.doubleAction = #selector(onChangedFileDoubleClicked)
        changedFilesTableView.onReturn = { [weak self] in self?.onChangedFileDoubleClicked() }
        let filesMenu = NSMenu(title: "Files")
        filesMenu.delegate = self
        changedFilesTableView.menu = filesMenu
        changedFilesScrollView.documentView = changedFilesTableView
        lowerSplitView.addSubview(changedFilesScrollView)
        splitView.addSubview(lowerSplitView)

        // Status bar.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [nextButton, showAllButton] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.target = self
            button.isHidden = true
        }
        nextButton.action = #selector(onNextHundred)
        showAllButton.action = #selector(onShowAll)
        var statusViews: [NSView] = [spinner, statusLabel, NSView(), nextButton, showAllButton]
        if pickerCompletion != nil {
            let selectButton = NSButton(title: "Select", target: self, action: #selector(onSelectClicked))
            selectButton.keyEquivalent = "\r"
            let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(onPickerCancelClicked))
            cancelButton.keyEquivalent = "\u{1b}"
            statusViews.append(contentsOf: [cancelButton, selectButton])
        }
        let statusBar = NSStackView(views: statusViews)
        statusBar.spacing = 8
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusBar)

        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            topStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            topStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),

            splitView.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 8),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -8),

            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            statusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            statusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])

        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames PangolinGitLogSplit") == nil {
            splitView.setPosition(390, ofDividerAt: 0)
            lowerSplitView.setPosition(560, ofDividerAt: 0)
        }
    }

    /// The commit list's columns (TortoiseGit's `LOGLIST_*` columns); hidden ones are offered in
    /// the header menu.
    private static let columns: [(id: String, title: String, width: CGFloat, hidden: Bool)] = [
        ("Graph", "Graph", 80, false),
        ("Hash", "Commit", 72, false),
        ("SHA1", "SHA-1", 290, true),
        ("Subject", "Message", 470, false),
        ("Author", "Author", 140, false),
        ("Email", "Email", 170, true),
        ("Date", "Date", 130, false),
        ("Committer", "Committer", 140, true),
        ("CommitterEmail", "Committer Email", 170, true),
        ("CommitDate", "Commit Date", 130, true),
        ("Describe", "Describe", 140, true),
        ("Notes", "Notes", 160, true)
    ]

    // MARK: - Query controls

    /// Puts the query into the toolbar controls.
    private func syncControlsFromQuery() {
        refButton.item(at: 0)?.title = query.scopeTitle
        fromCheck.state = query.since == nil ? .off : .on
        toCheck.state = query.until == nil ? .off : .on
        if let since = query.since { fromPicker.dateValue = since }
        if let until = query.until { toPicker.dateValue = until }
        fromPicker.isEnabled = query.since != nil
        toPicker.isEnabled = query.until != nil
        limitPopup.selectItem(at: Self.limitKinds.firstIndex(of: query.limit.kind) ?? 0)
        limitField.stringValue = query.limit.count > 0 ? "\(query.limit.count)" : ""
        limitField.isEnabled = query.limit != .unlimited
        if let path = query.path {
            pathLabel.stringValue = "History of: \(path)"
        } else if let suspendedPath {
            pathLabel.stringValue = "History of: \(suspendedPath) (showing whole project)"
        }
        pathBar.isHidden = query.path == nil && suspendedPath == nil
        wholeProjectButton.state = suspendedPath != nil ? .on : .off
    }

    func setScope(_ scope: GitLogQuery.Scope) {
        query.scope = scope
        switch scope {
        case .current: config.setLogScope("current", forRepository: repositoryPath.rawPath)
        case .allRefs: config.setLogScope("all", forRepository: repositoryPath.rawPath)
        case .basicRefs: config.setLogScope("basic", forRepository: repositoryPath.rawPath)
        case .localBranches: config.setLogScope("local", forRepository: repositoryPath.rawPath)
        case .refs: break
        }
        syncControlsFromQuery()
        loadLog()
    }

    @objc private func onDateFilterChanged() {
        let calendar = Calendar.current
        query.since = fromCheck.state == .on ? calendar.startOfDay(for: fromPicker.dateValue) : nil
        query.until = toCheck.state == .on
            ? calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: toPicker.dateValue))
            : nil
        syncControlsFromQuery()
        loadLog()
    }

    @objc private func onLimitChanged() {
        let kind = Self.limitKinds[max(limitPopup.indexOfSelectedItem, 0)]
        let count = Int(limitField.stringValue.trimmingCharacters(in: .whitespaces)) ?? (kind == "commits" ? 100 : 1)
        query.limit = GitLogQuery.Limit(kind: kind, count: count)
        syncControlsFromQuery()
        loadLog()
    }

    @objc private func onNextHundred() {
        if case .commits(let n) = query.limit { query.limit = .commits(n + 100) }
        syncControlsFromQuery()
        loadLog()
    }

    @objc private func onShowAll() {
        query.limit = .unlimited
        syncControlsFromQuery()
        loadLog()
    }

    @objc private func onWholeProjectToggled() {
        if let path = query.path {
            suspendedPath = path
            query.path = nil
        } else if let suspendedPath {
            query.path = suspendedPath
            self.suspendedPath = nil
        }
        syncControlsFromQuery()
        loadLog()
    }

    @objc func onRefresh() {
        loadLog()
    }

    @objc private func onStatistics() {
        let revisions = visible.map { entries[$0].revision }
        let root = repositoryPath
        let walk = query.walkArguments()
        WindowRegistry.shared.present({
            StatisticsWindowController(repositoryPath: root, revisions: revisions, walkArguments: walk)
        }, repository: root)
    }

    // MARK: - Loading

    /// Reloads refs, the log and the working-tree state; keeps the selection when possible.
    func loadLog() {
        guard let repo = GitRepository.open(at: repositoryPath) else {
            statusLabel.stringValue = "Not a valid Git repository."
            return
        }
        repository = repo
        loadGeneration += 1
        let generation = loadGeneration
        let previousSelection = selectedEntries.first?.revision.hash.string
        query.useMailmap = config.useMailmap
        let query = self.query
        let root = repositoryPath
        let wantsWorkingTree = config.logShowWorkingTreeChanges
        spinner.startAnimation(nil)
        isLoading = true
        statusLabel.stringValue = "Loading commit log…"

        Task.detached(priority: .userInitiated) { [weak self] in
            let refs = await GitRefMap.load(root: root)
            let result: Result<[GitLogEntry], Error>
            do {
                result = .success(try await repo.log(query: query))
            } catch {
                result = .failure(error)
            }
            let entries = (try? result.get()) ?? []
            let graph = RevisionGraphView.GraphRow.build(for: entries.map(\.revision))
            var changes: [GitItemStatusInfo] = []
            if wantsWorkingTree {
                let pathspec = query.path.map { [$0] } ?? []
                changes = ((try? await repo.getStatus(untrackedFiles: "all", pathspec: pathspec)) ?? [])
                    .filter { $0.status != .ignored && $0.status != .clean }
            }
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.spinner.stopAnimation(nil)
                self.isLoading = false
                self.refMap = refs
                self.entries = entries
                self.graphRows = graph
                self.indexByHash = Dictionary(entries.enumerated().map { ($1.revision.hash.string, $0) }, uniquingKeysWith: { a, _ in a })
                self.workingTreeChanges = changes
                self.pathsByHash = nil
                self.describeCache = [:]
                self.applyFilter(selecting: self.hashToSelectAfterLoad ?? previousSelection)
                self.hashToSelectAfterLoad = nil
                if case .failure(let error) = result {
                    self.statusLabel.stringValue = "Failed to load log: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Filtering

    private var searchFilter: LogSearchFilter {
        LogSearchFilter(searchField.stringValue, fields: config.logSearchFields,
                        useRegex: config.logSearchRegex, caseSensitive: config.logSearchCaseSensitive)
    }

    /// Applies the search box to the loaded entries (TortoiseGit filters in memory as well).
    private func applyFilter(selecting hash: String? = nil) {
        // Resolve the selection before `visible` changes: row indexes mean other commits afterwards.
        let target = hash ?? selectedEntries.first?.revision.hash.string
        let filter = searchFilter
        if filter.isActive {
            if filter.fields.contains(.paths), pathsByHash == nil { loadPathsForSearch() }
            visible = entries.indices.filter { index in
                let entry = entries[index]
                let hash = entry.revision.hash.string
                let refNames = refMap.labels(for: hash).map(\.shortName)
                return filter.matches(filter.searchableText(for: entry, refNames: refNames, paths: pathsByHash?[hash]))
            }
        } else {
            visible = Array(entries.indices)
        }
        searchField.textColor = filter.isInvalidRegex ? .systemRed : .labelColor

        tableView.reloadData()
        if let target, let row = row(forHash: target) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else if numberOfRows(in: tableView) > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            updateSelectionDetails()
        }
        updateStatusLine()
    }

    private func loadPathsForSearch() {
        guard !loadingPaths else { return }
        loadingPaths = true
        let args = ["log", "--format=%x1e%H", "--name-only"] + query.walkArguments()
        let root = repositoryPath
        Task { @MainActor in
            let output = (try? await GitCLIRunner().runChecked(arguments: args, workingDirectory: root)) ?? ""
            self.pathsByHash = CommitStatsParser.parseNameOnly(output)
            self.loadingPaths = false
            self.applyFilter()
        }
    }

    @objc private func onFilterChanged() {
        applyFilter()
    }

    /// The magnifier menu (TortoiseGit's filter field menu). NSSearchField copies its template, so
    /// the items use plain target/action with tags instead of closures.
    func rebuildSearchMenu() {
        let menu = NSMenu(title: "Search")
        let fields = config.logSearchFields
        for (field, title) in LogSearchFilter.Fields.titled {
            let item = NSMenuItem(title: title, action: #selector(onSearchOptionChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = field.rawValue
            item.state = fields.contains(field) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (tag, title, isOn) in [(-1, "Regular Expression", config.logSearchRegex), (-2, "Case Sensitive", config.logSearchCaseSensitive)] {
            let item = NSMenuItem(title: title, action: #selector(onSearchOptionChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = isOn ? .on : .off
            menu.addItem(item)
        }
        searchField.searchMenuTemplate = menu
    }

    @objc private func onSearchOptionChosen(_ sender: NSMenuItem) {
        switch sender.tag {
        case -1: config.logSearchRegex.toggle()
        case -2: config.logSearchCaseSensitive.toggle()
        default:
            let field = LogSearchFilter.Fields(rawValue: sender.tag)
            var current = config.logSearchFields
            if current.contains(field) { current.remove(field) } else { current.insert(field) }
            config.logSearchFields = current
        }
        rebuildSearchMenu()
        applyFilter()
    }

    // MARK: - Rows

    var showsWorkingTreeRow: Bool {
        guard config.logShowWorkingTreeChanges, pickerCompletion == nil, !relevantWorkingTreeChanges.isEmpty else { return false }
        // Only when HEAD is part of the walk and no search hides the virtual row.
        if searchFilter.isActive { return false }
        if case .refs(let refs) = query.scope, !refs.contains("HEAD") { return false }
        return true
    }

    var relevantWorkingTreeChanges: [GitItemStatusInfo] {
        config.logShowUnversioned ? workingTreeChanges : workingTreeChanges.filter { $0.status != .untracked }
    }

    private var rowOffset: Int { showsWorkingTreeRow ? 1 : 0 }

    /// The entry of a table row; nil for the working-tree row.
    func entry(atRow row: Int) -> GitLogEntry? {
        let index = row - rowOffset
        guard index >= 0, index < visible.count else { return nil }
        return entries[visible[index]]
    }

    func isWorkingTreeRow(_ row: Int) -> Bool {
        showsWorkingTreeRow && row == 0
    }

    func row(forHash hash: String) -> Int? {
        guard let index = indexByHash[hash], let position = visible.firstIndex(of: index) else { return nil }
        return position + rowOffset
    }

    /// Selected commits, newest first.
    var selectedEntries: [GitLogEntry] {
        tableView.selectedRowIndexes.compactMap { entry(atRow: $0) }
    }

    var workingTreeRowSelected: Bool {
        tableView.selectedRowIndexes.contains { isWorkingTreeRow($0) }
    }

    func entry(forHash hash: String) -> GitLogEntry? {
        indexByHash[hash].map { entries[$0] }
    }

    /// Selects a commit by (abbreviated) hash; true when it is listed.
    @discardableResult
    func select(hash: String) -> Bool {
        let lowered = hash.lowercased()
        let match = indexByHash[lowered] != nil ? lowered
            : entries.first(where: { $0.revision.hash.string.hasPrefix(lowered) })?.revision.hash.string
        guard let match, let row = row(forHash: match) else { return false }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        window?.makeFirstResponder(tableView)
        return true
    }

    private func updateStatusLine() {
        let selected = tableView.selectedRowIndexes.count
        var text: String
        if entries.isEmpty {
            text = "No revisions."
        } else {
            let dates = visible.map { entries[$0].revision.author.date }
            let shown = visible.count == entries.count ? "\(entries.count)" : "\(visible.count) of \(entries.count)"
            text = "Showing \(shown) revisions"
            if let oldest = dates.min(), let newest = dates.max() {
                text += ", from \(formatDate(oldest, short: true)) to \(formatDate(newest, short: true))"
            }
            text += "."
        }
        if selected > 1 { text += " \(selected) selected." }
        statusLabel.stringValue = text
        var limitReached = false
        if case .commits(let n) = query.limit, entries.count >= n { limitReached = true }
        nextButton.isHidden = !limitReached
        showAllButton.isHidden = query.limit == .unlimited || (!limitReached && query.limit.kind == "commits")
    }

    func formatDate(_ date: Date, short: Bool? = nil) -> String {
        LogDisplayFormat.date(date, short: short ?? config.logShortDateFormat, relative: config.logRelativeTimes,
                              systemLocale: config.logUseSystemLocale)
    }

    var logFont: NSFont {
        let size = CGFloat(config.logFontSize)
        if !config.logFontName.isEmpty, let font = NSFont(name: config.logFontName, size: size) { return font }
        return NSFont.systemFont(ofSize: size)
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === self.tableView {
            return visible.count + rowOffset
        }
        return listedFiles.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let colId = tableColumn?.identifier.rawValue ?? ""
        if tableView === changedFilesTableView {
            return changedFileCell(column: colId, row: row)
        }
        let font = logFont
        let small = NSFont.systemFont(ofSize: max(font.pointSize - 1, 9))
        if isWorkingTreeRow(row) {
            switch colId {
            case "Subject":
                let cell = LogMessageCellView.make(in: tableView, owner: self)
                cell.chips = []
                cell.message = "Working tree changes (\(relevantWorkingTreeChanges.count))"
                cell.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                cell.textColor = .systemRed
                return cell
            case "Graph":
                return nil
            default:
                let cell = LogTextCellView.make(in: tableView, identifier: "LogText", owner: self)
                cell.configure("", font: small)
                return cell
            }
        }
        guard let entry = entry(atRow: row) else { return nil }
        let rev = entry.revision
        let hash = rev.hash.string

        switch colId {
        case "Graph":
            let cellId = NSUserInterfaceItemIdentifier("GraphCell")
            let graphCell = tableView.makeView(withIdentifier: cellId, owner: self) as? RevisionGraphView ?? {
                let view = RevisionGraphView()
                view.identifier = cellId
                return view
            }()
            graphCell.rowHeight = tableView.rowHeight
            if let index = indexByHash[hash], index < graphRows.count {
                graphCell.rows = [graphRows[index]]
            } else {
                graphCell.rows = []
            }
            return graphCell
        case "Subject":
            let cell = LogMessageCellView.make(in: tableView, owner: self)
            if config.logShowRefLabels {
                cell.chips = refMap.labels(for: hash).map {
                    LogMessageCellView.Chip(text: refMap.displayName(for: $0, symbolize: config.logSymbolizeRefs),
                                            kind: $0.kind, isCurrent: $0.isCurrent)
                }
            } else {
                cell.chips = []
            }
            cell.chipsOnRight = config.logLabelsOnRight
            var message = rev.subject
            if config.logFullMessageOnLine, !rev.body.isEmpty {
                message += " " + rev.body.replacingOccurrences(of: "\n", with: " ")
            }
            cell.message = message
            let isHead = hash == refMap.headHash
            cell.font = isHead ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            cell.textColor = .labelColor
            return cell
        default:
            let cell = LogTextCellView.make(in: tableView, identifier: "LogText", owner: self)
            switch colId {
            case "Hash": cell.configure(rev.hash.short, font: .monospacedSystemFont(ofSize: small.pointSize, weight: .regular), color: .secondaryLabelColor)
            case "SHA1": cell.configure(hash, font: .monospacedSystemFont(ofSize: small.pointSize, weight: .regular), color: .secondaryLabelColor)
            case "Author": cell.configure(rev.author.name, font: font)
            case "Email": cell.configure(rev.author.email, font: font, color: .secondaryLabelColor)
            case "Date": cell.configure(formatDate(rev.author.date), font: font, color: .secondaryLabelColor)
            case "Committer": cell.configure(rev.committer.name, font: font)
            case "CommitterEmail": cell.configure(rev.committer.email, font: font, color: .secondaryLabelColor)
            case "CommitDate": cell.configure(formatDate(rev.committer.date), font: font, color: .secondaryLabelColor)
            case "Notes": cell.configure(entry.notes.replacingOccurrences(of: "\n", with: " "), font: font)
            case "Describe":
                if let describe = describeCache[hash] {
                    cell.configure(describe, font: font, color: .secondaryLabelColor)
                } else {
                    cell.configure("…", font: font, color: .tertiaryLabelColor)
                    requestDescribe(hash)
                }
            default: cell.configure("", font: font)
            }
            return cell
        }
    }

    /// `git describe` for the Describe column, computed only for rows that are drawn (LG-14).
    private func requestDescribe(_ hash: String) {
        guard !describePending.contains(hash) else { return }
        describePending.insert(hash)
        let args = config.describeArguments(for: hash)
        let root = repositoryPath
        Task { @MainActor in
            let result = try? await GitCLIRunner().run(arguments: args, workingDirectory: root)
            let text = result?.isSuccess == true ? result!.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            self.describeCache[hash] = text
            self.describePending.remove(hash)
            if let row = self.row(forHash: hash), let column = self.tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "Describe" }) {
                self.tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
            }
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === tableView else { return }
        if !navigatingHistory, selectedEntries.count == 1, let hash = selectedEntries.first?.revision.hash.string,
           selectionHistory.indices.contains(historyIndex) ? selectionHistory[historyIndex] != hash : true {
            selectionHistory = Array(selectionHistory.prefix(historyIndex + 1))
            selectionHistory.append(hash)
            historyIndex = selectionHistory.count - 1
        }
        updateSelectionDetails()
        updateStatusLine()
    }

    // MARK: - Details

    func updateSelectionDetails() {
        detailGeneration += 1
        let generation = detailGeneration
        avatarView.isHidden = true
        let selection = selectedEntries
        if workingTreeRowSelected && selection.isEmpty {
            showWorkingTreeDetails()
            return
        }
        guard selection.count == 1, let entry = selection.first else {
            let text = selection.isEmpty ? "" : "\(selection.count) revisions selected."
            commitDetailTextView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: detailAttributes()))
            setChangedFiles([], parent: nil)
            return
        }
        commitDetailTextView.textStorage?.setAttributedString(detailText(for: entry))
        loadAvatar(email: entry.revision.author.email, generation: generation)
        loadExtraDetails(for: entry, generation: generation)
        setChangedFiles([], parent: nil)
        loadChangedFiles(for: entry.revision, generation: generation)
    }

    private func detailAttributes(bold: Bool = false, color: NSColor = .labelColor) -> [NSAttributedString.Key: Any] {
        let size = CGFloat(max(config.logFontSize - 1, 10))
        return [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color]
    }

    /// The upper part of TortoiseGit's message pane, with clickable hashes and URLs (LG-13).
    private func detailText(for entry: GitLogEntry) -> NSAttributedString {
        let rev = entry.revision
        let text = NSMutableAttributedString()
        func line(_ label: String, _ value: NSAttributedString) {
            text.append(NSAttributedString(string: label + "\t", attributes: detailAttributes(bold: true, color: .secondaryLabelColor)))
            text.append(value)
            text.append(NSAttributedString(string: "\n", attributes: detailAttributes()))
        }
        func plain(_ string: String) -> NSAttributedString { NSAttributedString(string: string, attributes: detailAttributes()) }
        func hashLink(_ hash: GitHash, short: Bool) -> NSAttributedString {
            var attributes = detailAttributes()
            attributes[.link] = URL(string: "pangolinlog:\(hash.string)")
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: CGFloat(max(config.logFontSize - 1, 10)), weight: .regular)
            return NSAttributedString(string: short ? hash.short : hash.string, attributes: attributes)
        }
        line("Commit:", hashLink(rev.hash, short: false))
        if !rev.parentHashes.isEmpty {
            let parents = NSMutableAttributedString()
            for (index, parent) in rev.parentHashes.enumerated() {
                if index > 0 { parents.append(plain(", ")) }
                parents.append(hashLink(parent, short: true))
                if let subject = self.entry(forHash: parent.string)?.revision.subject {
                    parents.append(plain(" (\(subject.prefix(50)))"))
                }
            }
            line("Parents:", parents)
        }
        line("Author:", plain("\(rev.author.name) <\(rev.author.email)>  \(formatDate(rev.author.date, short: false))"))
        if rev.committer.name != rev.author.name || rev.committer.email != rev.author.email || rev.committer.date != rev.author.date {
            line("Committer:", plain("\(rev.committer.name) <\(rev.committer.email)>  \(formatDate(rev.committer.date, short: false))"))
        }
        let labels = refMap.labels(for: rev.hash.string)
        if !labels.isEmpty {
            line("Refs:", plain(labels.map { $0.fullName }.joined(separator: ", ")))
        }
        text.append(plain("\n"))
        text.append(linkified(rev.fullMessage))
        if !entry.notes.isEmpty {
            text.append(NSAttributedString(string: "\n\nNotes:\n", attributes: detailAttributes(bold: true, color: .secondaryLabelColor)))
            text.append(linkified(entry.notes))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 80)]
        paragraph.defaultTabInterval = 80
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// Message text with URLs and known commit hashes (8+ hex digits, TortoiseGit's
    /// `ShortHashLengthForHyperLinkInLogMessage`) turned into links.
    private func linkified(_ message: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: message, attributes: detailAttributes())
        let range = NSRange(message.startIndex..., in: message)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: message, range: range) {
                if let url = match.url { result.addAttribute(.link, value: url, range: match.range) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: "\\b[0-9a-fA-F]{8,40}\\b") {
            for match in regex.matches(in: message, range: range) {
                guard let swiftRange = Range(match.range, in: message) else { continue }
                let candidate = message[swiftRange].lowercased()
                if entries.contains(where: { $0.revision.hash.string.hasPrefix(candidate) }) {
                    result.addAttribute(.link, value: URL(string: "pangolinlog:\(candidate)")!, range: match.range)
                }
            }
        }
        return result
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        if url.scheme == "pangolinlog" {
            let hash = url.absoluteString.replacingOccurrences(of: "pangolinlog:", with: "")
            if !select(hash: hash) { statusLabel.stringValue = "Commit \(hash.prefix(8)) is not in the list shown." }
            return true
        }
        return false
    }

    /// Describe and branch revision number, appended when ready (Settings ▸ Log).
    private func loadExtraDetails(for entry: GitLogEntry, generation: Int) {
        let hash = entry.revision.hash.string
        let wantsDescribe = config.logShowDescribe
        let wantsRevisionNumber = config.logShowBranchRevisionNumber
        guard wantsDescribe || wantsRevisionNumber else { return }
        let describeArgs = config.describeArguments(for: hash)
        let root = repositoryPath
        Task { @MainActor in
            var extra = ""
            if wantsDescribe, let result = try? await GitCLIRunner().run(arguments: describeArgs, workingDirectory: root), result.isSuccess {
                extra += "Describe:\t\(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            }
            if wantsRevisionNumber, let count = try? await GitCLIRunner().runChecked(
                arguments: ["rev-list", "--count", "--first-parent", hash], workingDirectory: root) {
                extra += "Branch revision:\t\(count.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            }
            guard generation == self.detailGeneration, !extra.isEmpty, let storage = self.commitDetailTextView.textStorage else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 110)]
            var attributes = self.detailAttributes(color: .secondaryLabelColor)
            attributes[.paragraphStyle] = paragraph
            // Insert after the header block (before the blank line preceding the message).
            let header = (storage.string as NSString).range(of: "\n\n")
            let location = header.location == NSNotFound ? storage.length : header.location + 1
            storage.insert(NSAttributedString(string: extra, attributes: attributes), at: location)
        }
    }

    private static var avatarCache: [String: NSImage] = [:]

    /// Gravatar of the author (Settings ▸ Log ▸ Show Gravatar), keyed by SHA-256 of the email.
    private func loadAvatar(email: String, generation: Int) {
        guard config.logShowGravatar else { return }
        let digest = SHA256.hash(data: Data(email.trimmingCharacters(in: .whitespaces).lowercased().utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if let cached = Self.avatarCache[hex] {
            avatarView.image = cached
            avatarView.isHidden = false
            return
        }
        guard let url = URL(string: config.logGravatarURL.replacingOccurrences(of: "%HASH%", with: hex)) else { return }
        Task { @MainActor in
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            Self.avatarCache[hex] = image
            guard generation == self.detailGeneration else { return }
            self.avatarView.image = image
            self.avatarView.isHidden = false
        }
    }

    private func showWorkingTreeDetails() {
        let changes = relevantWorkingTreeChanges
        let text = "Working tree changes\n\n\(changes.count) changed item(s) not yet committed."
            + (FileManager.default.fileExists(atPath: repositoryPath.appending(".git/MERGE_HEAD").rawPath) ? "\nA merge is in progress." : "")
        commitDetailTextView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: detailAttributes()))
        let files = changes.map { change -> GitChangedFile in
            let letter: String
            switch change.status {
            case .added: letter = "A"
            case .deleted, .missing: letter = "D"
            case .renamed: letter = "R"
            case .copied: letter = "C"
            case .untracked: letter = "?"
            case .conflicted: letter = "U"
            default: letter = "M"
            }
            return GitChangedFile(status: letter, path: change.path, oldPath: change.originalPath, isSubmodule: change.isSubmodule)
        }
        setChangedFiles(files, parent: nil)
    }

    // MARK: - Changed files (lower pane)

    func setChangedFiles(_ files: [GitChangedFile], parent: String?) {
        changedFiles = files
        changedFilesParent = parent
        if let path = query.path, config.logHideUnrelatedPaths {
            listedFiles = files.filter { Self.isRelated($0, to: path) }
        } else {
            listedFiles = files
        }
        changedFilesTableView.reloadData()
    }

    static func isRelated(_ file: GitChangedFile, to path: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return [file.path, file.oldPath].compactMap { $0 }.contains { $0 == path || $0.hasPrefix(prefix) }
    }

    /// What the commit changed against its first parent (TortoiseGit lists merges per parent; the
    /// files menu offers the other parents).
    func loadChangedFiles(for revision: GitRevision, parentIndex: Int = 0, generation: Int? = nil) {
        let hash = revision.hash.string
        let root = repositoryPath
        let token = generation ?? detailGeneration
        changedFilesParentIndex = parentIndex
        Task { @MainActor in
            // Real parents: a path-limited log rewrites %P (see GitRepository.parent(of:index:)).
            let parent = await self.repository?.parent(of: hash, index: parentIndex)
            let runner = GitCLIRunner()
            async let raw = runner.runChecked(arguments: GitChangedFilesParser.rawArguments(parent: parent, revision: hash), workingDirectory: root)
            async let numstat = runner.runChecked(arguments: GitChangedFilesParser.numstatArguments(parent: parent, revision: hash), workingDirectory: root)
            let files = GitChangedFilesParser.parse(raw: (try? await raw) ?? "", numstat: (try? await numstat) ?? "")
            guard token == self.detailGeneration else { return }
            self.setChangedFiles(files, parent: parent)
        }
    }

    private func changedFileCell(column: String, row: Int) -> NSView? {
        guard row < listedFiles.count else { return nil }
        let file = listedFiles[row]
        let cell = LogTextCellView.make(in: changedFilesTableView, identifier: "FileText", owner: self)
        let unrelated = query.path.map { !Self.isRelated(file, to: $0) } ?? false
        let font = NSFont.systemFont(ofSize: 11)
        switch column {
        case "ChangeStatus":
            let color: NSColor
            switch file.status {
            case "M": color = .systemBlue
            case "A": color = .systemGreen
            case "D": color = .systemRed
            case "R", "C": color = .systemPurple
            case "U": color = .systemOrange
            default: color = .labelColor
            }
            cell.configure(Self.actionTitle(file), font: .boldSystemFont(ofSize: 11), color: unrelated ? .tertiaryLabelColor : color)
        case "ChangePath":
            var text = file.path
            if let old = file.oldPath {
                text = config.logAbbreviateRenamings ? LogDisplayFormat.abbreviatedRename(from: old, to: file.path) : "\(file.path) (from \(old))"
            }
            if file.isSubmodule { text += "  [submodule]" }
            cell.configure(text, font: font, color: unrelated ? .tertiaryLabelColor : .labelColor)
        case "ChangeAdded":
            cell.configure(file.added.map { "\($0)" } ?? (file.isBinary && file.status != "?" ? "bin" : ""), font: font, color: .systemGreen)
        case "ChangeRemoved":
            cell.configure(file.removed.map { "\($0)" } ?? "", font: font, color: .systemRed)
        default:
            cell.configure("", font: font)
        }
        return cell
    }

    static func actionTitle(_ file: GitChangedFile) -> String {
        switch file.status {
        case "A": return "Added"
        case "M": return "Modified"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type"
        case "U": return "Conflict"
        case "?": return "Unversioned"
        default: return file.status
        }
    }

    // MARK: - Double click, Enter, picker

    @objc private func onCommitDoubleClicked() {
        activateCommit(fromKeyboard: false)
    }

    /// Double-click / Enter. In picker mode it selects; otherwise Enter and (with "Double-click
    /// compares", TortoiseGit's DiffByDoubleClickInLog) double-click compare with the previous
    /// revision; a plain double-click shows the commit as a unified diff.
    private func activateCommit(fromKeyboard: Bool) {
        if pickerCompletion != nil {
            onSelectClicked()
            return
        }
        if workingTreeRowSelected {
            CommandRouter.shared.execute(command: .changed, targetPath: repositoryPath.rawPath)
            return
        }
        guard selectedEntries.count == 1, let entry = selectedEntries.first else { return }
        if fromKeyboard || config.logDoubleClickCompares {
            compareWithPrevious(entry.revision, parentIndex: 0)
        } else {
            showUnifiedDiff(entry.revision)
        }
    }

    @objc private func onSelectClicked() {
        guard let hash = selectedEntries.first?.revision.hash.string, let pickerCompletion else { return }
        close()
        pickerCompletion(hash)
    }

    @objc private func onPickerCancelClicked() {
        close()
    }

    @objc func onChangedFileDoubleClicked() {
        let row = changedFilesTableView.clickedRow >= 0 ? changedFilesTableView.clickedRow : changedFilesTableView.selectedRow
        guard row >= 0, row < listedFiles.count else { return }
        diffFile(listedFiles[row])
    }

    // MARK: - Navigation (LG-09)

    enum Navigation {
        case back, forward, firstParent, secondParent, child, head
        case newerSameAuthor, olderSameAuthor, newerMerge, olderMerge, newerTag, olderTag, newerBranch, olderBranch
    }

    func navigate(_ navigation: Navigation) {
        switch navigation {
        case .back, .forward:
            let target = historyIndex + (navigation == .back ? -1 : 1)
            guard selectionHistory.indices.contains(target) else { NSSound.beep(); return }
            historyIndex = target
            navigatingHistory = true
            if !select(hash: selectionHistory[target]) { NSSound.beep() }
            navigatingHistory = false
            return
        case .head:
            if let head = refMap.headHash, select(hash: head) { return }
            NSSound.beep()
            return
        default:
            break
        }
        guard let current = selectedEntries.first?.revision else { NSSound.beep(); return }
        switch navigation {
        case .firstParent, .secondParent:
            let index = navigation == .firstParent ? 0 : 1
            guard current.parentHashes.indices.contains(index), select(hash: current.parentHashes[index].string) else { NSSound.beep(); return }
        case .child:
            guard let child = entries.first(where: { $0.revision.parentHashes.first == current.hash }),
                  select(hash: child.revision.hash.string) else { NSSound.beep(); return }
        default:
            let newer = [.newerSameAuthor, .newerMerge, .newerTag, .newerBranch].contains(navigation)
            let predicate: (GitRevision) -> Bool
            switch navigation {
            case .newerSameAuthor, .olderSameAuthor: predicate = { $0.author.email == current.author.email }
            case .newerMerge, .olderMerge: predicate = { $0.isMergeCommit }
            case .newerTag, .olderTag: predicate = { [refMap] in refMap.labels(for: $0.hash.string).contains { $0.isTag } }
            default: predicate = { [refMap] in refMap.labels(for: $0.hash.string).contains { $0.isBranch } }
            }
            guard let start = row(forHash: current.hash.string) else { return }
            let candidates = newer ? Array(stride(from: start - 1, through: 0, by: -1))
                : Array(stride(from: start + 1, to: numberOfRows(in: tableView), by: 1))
            for row in candidates {
                if let revision = entry(atRow: row)?.revision, predicate(revision) {
                    select(hash: revision.hash.string)
                    return
                }
            }
            NSSound.beep()
        }
    }

    private func handleOptionArrow(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 123: navigate(.back)
        case 124: navigate(.forward)
        case 125: navigate(.firstParent)
        case 126: navigate(.child)
        default: return false
        }
        return true
    }

    @objc private func onHistoryClicked() {
        navigate(historyControl.selectedSegment == 0 ? .back : .forward)
    }

    // MARK: - Keyboard (LG-25)

    /// ⌘F focuses the search box (the app's Edit menu has no Find item to route through).
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "f" {
                self.window?.makeFirstResponder(self.searchField)
                return nil
            }
            return event
        }
    }

    /// ⌘V with a commit hash on the clipboard jumps to that commit (TortoiseGit: paste hash to jump).
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= 4, text.count <= 64, text.allSatisfy(\.isHexDigit) else { NSSound.beep(); return }
        if !select(hash: text) { statusLabel.stringValue = "Commit \(text.prefix(8)) is not in the list shown." }
    }

    /// ⌘C copies the full information of the selected commits.
    @objc func copy(_ sender: Any?) {
        copyToClipboard(selectedEntries.map(fullInformation(_:)).joined(separator: "\n"))
    }

    /// Escape clears the search, then the path filter (TortoiseGit's Escape behaviour).
    public override func cancelOperation(_ sender: Any?) {
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            applyFilter()
        } else if query.path != nil {
            onWholeProjectToggled()
        } else if pickerCompletion != nil {
            close()
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func fullInformation(_ entry: GitLogEntry) -> String {
        let rev = entry.revision
        var text = """
        Revision: \(rev.hash.string)
        Author: \(rev.author.name) <\(rev.author.email)>
        Date: \(formatDate(rev.author.date, short: false))
        Message:
        \(rev.fullMessage)

        """
        if !entry.notes.isEmpty { text += "Notes:\n\(entry.notes)\n" }
        return text
    }

    // MARK: - Pop-up menus (NSMenuDelegate)

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === tableView.menu {
            buildCommitMenu(menu)
        } else if menu === changedFilesTableView.menu {
            buildFilesMenu(menu)
        } else if menu === tableView.headerView?.menu {
            buildColumnMenu(menu)
        } else if menu === refButton.menu {
            buildRefMenu(menu)
        } else if menu === viewButton.menu {
            buildViewMenu(menu)
        } else if menu === goButton.menu {
            buildGoMenu(menu)
        }
    }

    private func buildColumnMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for column in tableView.tableColumns {
            let item = ClosureMenuItem(title: column.title) { [weak self] in
                column.isHidden.toggle()
                self?.tableView.reloadData()
            }
            item.state = column.isHidden ? .off : .on
            menu.addItem(item)
        }
    }

    /// TortoiseGit's branch button and "All Branches" checkbox in one menu (LG-01).
    private func buildRefMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: query.scopeTitle, action: nil, keyEquivalent: "")
        func add(_ title: String, _ scope: GitLogQuery.Scope) {
            let item = ClosureMenuItem(title: title) { [weak self] in self?.setScope(scope) }
            item.state = query.scope == scope ? .on : .off
            menu.addItem(item)
        }
        add("Current Branch (HEAD)", .current)
        if config.branchesIncludeFetchHead,
           let gitDir = repository?.gitDirectory, FileManager.default.fileExists(atPath: gitDir.appending("FETCH_HEAD").rawPath) {
            add("FETCH_HEAD", .refs(["FETCH_HEAD"]))
        }
        menu.addItem(.separator())
        add("All Refs", .allRefs)
        add("All Branches, Tags and Remotes", .basicRefs)
        add("Local Branches", .localBranches)
        menu.addItem(.separator())

        let labels = refMap.allLabels
        let groups: [(String, (GitRefLabel) -> Bool)] = [
            ("Local Branch", { $0.kind == .localBranch }),
            ("Remote Branch", { $0.kind == .remoteBranch }),
            ("Tag", { $0.isTag })
        ]
        for (title, predicate) in groups {
            var names = labels.filter(predicate).map(\.shortName)
            if title == "Tag" {
                names.sort { $0.compare($1, options: .numeric) == (config.sortTagsReversed ? .orderedDescending : .orderedAscending) }
            }
            guard !names.isEmpty else { continue }
            let submenu = NSMenu(title: title)
            for name in names {
                let item = ClosureMenuItem(title: name) { [weak self] in self?.setScope(.refs([name])) }
                if case .refs(let refs) = query.scope, refs == [name] { item.state = .on }
                submenu.addItem(item)
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Browse References…", symbol: "tag") { [weak self] in
            guard let self else { return }
            let root = self.repositoryPath
            WindowRegistry.shared.present({
                BrowseRefsWindowController(repositoryPath: root) { [weak self] ref in self?.setScope(.refs([ref])) }
            }, repository: root)
        })
        menu.addItem(ClosureMenuItem(title: "Revisions or Range…") { [weak self] in self?.askForRange() })
    }

    private func askForRange() {
        let alert = NSAlert()
        alert.messageText = "Show Log of Revisions"
        alert.informativeText = "Enter one or more revisions or a range: main, A..B (in B, not in A), A...B (in either, not both)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        if case .refs(let refs) = query.scope { field.stringValue = refs.joined(separator: " ") }
        alert.accessoryView = field
        alert.addButton(withTitle: "Show")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        setScope(text.isEmpty ? .current : .refs([text]))
    }

    /// TortoiseGit's "View" / walk options (LG-07) and list toggles.
    private func buildViewMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "View", action: nil, keyEquivalent: "")
        func toggle(_ title: String, _ isOn: Bool, enabled: Bool = true, _ change: @escaping (LogWindowController) -> Void) {
            let item = ClosureMenuItem(title: title) { [weak self] in
                guard let self else { return }
                change(self)
            }
            item.state = isOn ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }
        toggle("First Parent Only", query.firstParent) { $0.query.firstParent.toggle(); $0.loadLog() }
        toggle("No Merges", query.noMerges) { $0.query.noMerges.toggle(); $0.loadLog() }
        toggle("Full History", query.fullHistory) { $0.query.fullHistory.toggle(); $0.loadLog() }
        toggle("Show Labelled Commits Only (Compressed Graph)", query.simplifyByDecoration) { $0.query.simplifyByDecoration.toggle(); $0.loadLog() }
        menu.addItem(.separator())
        let hasPath = query.path != nil
        toggle("Follow Renames", query.followRenames, enabled: hasPath) { $0.query.followRenames.toggle(); $0.loadLog() }
        toggle("Hide Unrelated Changed Paths", config.logHideUnrelatedPaths, enabled: hasPath) {
            $0.config.logHideUnrelatedPaths.toggle()
            $0.setChangedFiles($0.changedFiles, parent: $0.changedFilesParent)
        }
        menu.addItem(.separator())
        toggle("Show Working Tree Changes", config.logShowWorkingTreeChanges) { $0.config.logShowWorkingTreeChanges.toggle(); $0.loadLog() }
        toggle("Show Unversioned Files", config.logShowUnversioned, enabled: config.logShowWorkingTreeChanges) {
            $0.config.logShowUnversioned.toggle(); $0.applyFilter()
        }
        toggle("Show Ref Labels", config.logShowRefLabels) { $0.config.logShowRefLabels.toggle(); $0.tableView.reloadData() }
        toggle("Labels on the Right", config.logLabelsOnRight) { $0.config.logLabelsOnRight.toggle(); $0.tableView.reloadData() }
        toggle("Subject and Body on the Log Line", config.logFullMessageOnLine) { $0.config.logFullMessageOnLine.toggle(); $0.tableView.reloadData() }
        toggle("Relative Dates", config.logRelativeTimes) { $0.config.logRelativeTimes.toggle(); $0.tableView.reloadData() }
    }

    private func buildGoMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Go To", action: nil, keyEquivalent: "")
        let items: [(String, Navigation)] = [
            ("HEAD", .head),
            ("First Parent (⌥↓)", .firstParent), ("Second Parent", .secondParent), ("Child (⌥↑)", .child),
            ("Newer Commit by Same Author", .newerSameAuthor), ("Older Commit by Same Author", .olderSameAuthor),
            ("Newer Merge", .newerMerge), ("Older Merge", .olderMerge),
            ("Newer Tag", .newerTag), ("Older Tag", .olderTag),
            ("Newer Branch", .newerBranch), ("Older Branch", .olderBranch)
        ]
        for (index, (title, navigation)) in items.enumerated() {
            if [1, 4, 6, 8, 10].contains(index) { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem(title: title) { [weak self] in self?.navigate(navigation) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Paste Hash to Jump (⌘V)") { [weak self] in self?.paste(nil) })
    }
}
