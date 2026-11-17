import Cocoa
import PangolinGitCore

/// Blame viewer mirroring TortoiseGit's `TortoiseGitBlame` (`src/TortoiseGitBlame/`): annotates each
/// line with its commit, at the working tree or any revision; colours by author or age; highlights
/// the lines of the hovered / selected commit; *Blame previous revision*, *Compare with previous
/// revision* and Show Log from the line menu; a file-history pane that highlights a commit's lines;
/// moved/copied-line detection levels, encodings, Find, Go to line and block navigation.
/// Author names come from `git blame`, which already applies `.mailmap`.
@MainActor
public final class BlameWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    /// One commit of the file's history (the Git Log pane).
    struct FileCommit {
        let hash: String
        let author: String
        let time: TimeInterval
        let subject: String
    }

    private let filePath: PangolinPath
    /// Blamed revision; nil = the working-tree file (TortoiseGit's default).
    private let revision: String?
    private let initialLine: Int?
    private var repositoryRoot: PangolinPath?
    private var lines: [GitBlameLine] = []
    private var history: [FileCommit] = []
    private var oldestTime: TimeInterval = 0
    private var newestTime: TimeInterval = 0
    /// Commit whose lines are emphasised: the hovered line's, else the selected line's or history entry's.
    private var hoverHash: String? { didSet { if hoverHash != oldValue { refreshRowTints() } } }
    private var focusHash: String? { didSet { if focusHash != oldValue { refreshRowTints() } } }
    private var messageCache: [String: String] = [:]
    private let dateFormatter = DateFormatter()

    private let tableView = BlameTableView()
    private let historyTable = NSTableView()
    private let searchField = NSSearchField()
    private let colorModePopup = NSPopUpButton()
    private let detectionPopup = NSPopUpButton()
    private let encodingPopup = NSPopUpButton()
    private let ignoreWhitespaceCheck = NSButton(checkboxWithTitle: "Ignore whitespace", target: nil, action: nil)
    private let firstParentCheck = NSButton(checkboxWithTitle: "First parent", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Loading git blame…")
    private let inspectorTitle = NSTextField(labelWithString: "Select a line to see its commit.")
    private let inspectorMessage = NSTextField(wrappingLabelWithString: "")
    private var commitButtons: [NSButton] = []

    private static let encodings: [(String, String.Encoding)] = [
        ("UTF-8", .utf8), ("Western (ISO Latin 1)", .isoLatin1), ("Western (Windows 1252)", .windowsCP1252),
        ("Western (Mac OS Roman)", .macOSRoman), ("UTF-16", .utf16), ("Japanese (Shift JIS)", .shiftJIS)
    ]

    /// - Parameters:
    ///   - revision: blame the file as of this commit (TortoiseGit `/endrev`); nil = working tree.
    ///   - line: line to select and scroll to once loaded (`/line`).
    public init(filePath: PangolinPath, revision: String? = nil, line: Int? = nil) {
        self.filePath = filePath
        self.revision = revision
        self.initialLine = line
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Blame — \(filePath.filename)" + (revision.map { " @ \($0.count == 40 ? String($0.prefix(8)) : $0)" } ?? "")
        window.minSize = NSSize(width: 800, height: 500)
        super.init(window: window)
        let format = ConfigManager.shared.blameDateFormat.trimmingCharacters(in: .whitespaces)
        dateFormatter.dateFormat = format.isEmpty ? "yyyy-MM-dd HH:mm" : format
        setupUI()
        repositoryRoot = GitRepository.open(at: filePath)?.workingDirectory
        loadBlame()
        loadHistory()
        if let root = repositoryRoot, revision == nil {
            // The working-tree blame changes with every commit; one at a fixed revision does not.
            RepositoryEvents.observe(root, owner: self) { [weak self] in self?.loadBlame() }
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var relativePath: String {
        guard let root = repositoryRoot else { return filePath.rawPath }
        return filePath.relative(to: root) ?? filePath.rawPath
    }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        let config = ConfigManager.shared

        searchField.placeholderString = "Find (Return = next)"
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(findNext)
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let previousMatch = button("◀︎", #selector(findPrevious), key: "G", modifiers: [.command, .shift], tip: "Find previous (⇧⌘G)")
        let nextMatch = button("▶︎", #selector(findNext), key: "g", modifiers: [.command], tip: "Find next (⌘G)")
        let goTo = button("Go to Line…", #selector(goToLine), key: "l", modifiers: [.command], tip: "⌘L")
        let previousBlock = button("↑ Block", #selector(previousBlock), key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.option],
                                   tip: "Previous block of lines from one commit (⌥↑)")
        let nextBlock = button("↓ Block", #selector(nextBlock), key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.option],
                               tip: "Next block of lines from one commit (⌥↓)")

        colorModePopup.addItems(withTitles: ["Color by Author", "Color by Age", "No Color"])
        switch config.blameColorMode {
        case "date": colorModePopup.selectItem(at: 1)
        case "none": colorModePopup.selectItem(at: 2)
        default: colorModePopup.selectItem(at: 0)
        }
        colorModePopup.target = self
        colorModePopup.action = #selector(refreshRowTints)

        for detection in GitBlame.MoveDetection.allCases {
            detectionPopup.addItem(withTitle: "Moved/copied: " + detection.title)
        }
        detectionPopup.selectItem(at: config.blameMoveDetection.rawValue)
        detectionPopup.toolTip = "Detect lines moved or copied from elsewhere (-M / -C levels)"
        encodingPopup.addItems(withTitles: Self.encodings.map(\.0))
        encodingPopup.toolTip = "Text encoding of the file"
        ignoreWhitespaceCheck.state = config.blameIgnoreWhitespace ? .on : .off
        firstParentCheck.state = config.blameFirstParent ? .on : .off
        firstParentCheck.toolTip = "Follow only the first parent of merges (--first-parent)"
        for control in [detectionPopup, encodingPopup, ignoreWhitespaceCheck, firstParentCheck] as [NSControl] {
            control.target = self
            control.action = #selector(onOptionChanged)
        }

        let toolbar = NSStackView(views: [searchField, previousMatch, nextMatch, goTo, previousBlock, nextBlock])
        toolbar.spacing = 6
        let options = NSStackView(views: [colorModePopup, detectionPopup, encodingPopup, ignoreWhitespaceCheck, firstParentCheck])
        options.spacing = 10

        // Blame table
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 6, height: 0)
        tableView.rowHeight = max(16, CGFloat(config.blameFontSize) + 5)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(onRowDoubleClicked)
        tableView.autosaveName = "BlameColumns"
        tableView.autosaveTableColumns = true
        tableView.onHover = { [weak self] row in
            guard let self else { return }
            self.hoverHash = row.flatMap { $0 < self.lines.count ? self.lines[$0].hash : nil }
        }
        for (id, title, width, hidden) in [("line", "Line", 50.0, false), ("hash", "Commit", 75.0, false), ("author", "Author", 120.0, false),
                                           ("date", "Date", 120.0, false), ("file", "File", 140.0, true), ("orig", "Orig. Line", 60.0, true),
                                           ("code", "Code", 700.0, false)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            column.isHidden = hidden
            tableView.addTableColumn(column)
        }
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
        let lineMenu = NSMenu()
        lineMenu.delegate = self
        tableView.menu = lineMenu
        let blameScroll = NSScrollView()
        blameScroll.hasVerticalScroller = true
        blameScroll.hasHorizontalScroller = true
        blameScroll.borderType = .bezelBorder
        blameScroll.documentView = tableView

        // Git Log pane
        for (id, title, width) in [("hash", "Commit", 70.0), ("author", "Author", 100.0), ("subject", "Message", 220.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            historyTable.addTableColumn(column)
        }
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.usesAlternatingRowBackgroundColors = true
        let historyMenu = NSMenu()
        historyMenu.delegate = self
        historyTable.menu = historyMenu
        let historyScroll = NSScrollView()
        historyScroll.hasVerticalScroller = true
        historyScroll.borderType = .bezelBorder
        historyScroll.documentView = historyTable

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(blameScroll)
        split.addArrangedSubview(historyScroll)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        historyScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        // Commit details
        inspectorTitle.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        inspectorTitle.lineBreakMode = .byTruncatingTail
        inspectorMessage.maximumNumberOfLines = 3
        inspectorMessage.isSelectable = true
        commitButtons = [
            ClosureButton(title: "Blame Previous") { [weak self] in self?.blamePrevious() },
            ClosureButton(title: "Compare with Previous") { [weak self] in self?.compareWithPrevious() },
            ClosureButton(title: "Show Log") { [weak self] in self?.showLog() },
            ClosureButton(title: "Copy SHA-1") { [weak self] in self?.copyHash() }
        ]
        commitButtons.forEach { $0.bezelStyle = .rounded; $0.isEnabled = false }
        let buttons = NSStackView(views: commitButtons)
        buttons.spacing = 6
        let details = NSStackView(views: [inspectorTitle, inspectorMessage])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 2
        details.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inspector = NSStackView(views: [details, buttons])
        inspector.alignment = .top

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [toolbar, options, split, inspector, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate(LayoutHelper.pinEdges(stack, to: contentView, insets: NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)) + [
            split.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inspector.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        DispatchQueue.main.async { split.setPosition(max(500, split.bounds.width - 330), ofDividerAt: 0) }
    }

    private func button(_ title: String, _ action: Selector, key: String, modifiers: NSEvent.ModifierFlags, tip: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = modifiers
        button.toolTip = tip
        return button
    }

    // MARK: - Loading

    private func loadBlame() {
        guard let root = repositoryRoot else {
            statusLabel.stringValue = "Not a Git repository."
            return
        }
        let config = ConfigManager.shared
        let detection = GitBlame.MoveDetection(rawValue: detectionPopup.indexOfSelectedItem) ?? .disabled
        let args = GitBlame.arguments(path: relativePath, revision: revision, ignoreWhitespace: ignoreWhitespaceCheck.state == .on,
                                      detection: detection, threshold: config.blameMoveThreshold, firstParent: firstParentCheck.state == .on)
        let encoding = Self.encodings[max(0, encodingPopup.indexOfSelectedItem)].1
        statusLabel.stringValue = "Running git blame for \(filePath.filename)…"
        Task { @MainActor in
            do {
                let data = try await GitCLIRunner.runDataAsync(arguments: args, workingDirectory: root)
                let parsed = await Task.detached { () -> [GitBlameLine] in
                    // Headers are ASCII; only the code lines depend on the chosen encoding.
                    let text = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
                    return GitBlame.parse(linePorcelain: text)
                }.value
                self.lines = parsed
                let times = parsed.filter { !$0.isUncommitted }.map(\.authorTime)
                self.oldestTime = times.min() ?? 0
                self.newestTime = times.max() ?? 0
                self.tableView.reloadData()
                let commits = Set(parsed.map(\.hash)).count
                self.statusLabel.stringValue = "\(parsed.count) lines from \(commits) commit(s)" + (self.revision.map { " at \($0)" } ?? " (working tree)")
                if let line = self.initialLine, line > 0, line <= parsed.count {
                    self.select(row: line - 1)
                }
            } catch {
                self.statusLabel.stringValue = "Failed to run blame: \(error.localizedDescription)"
            }
        }
    }

    /// The file's history for the Git Log pane (`git log --follow`, as TortoiseGitBlame's log dock).
    private func loadHistory() {
        guard let root = repositoryRoot else { return }
        var args = ["log", "--follow", "--format=%H%x1f%an%x1f%at%x1f%s"]
        if let revision { args.append(revision) }
        args += ["--", relativePath]
        Task { @MainActor in
            let output = (try? await GitCLIRunner.runAsync(arguments: args, workingDirectory: root)) ?? ""
            self.history = output.split(separator: "\n").compactMap { line in
                let parts = line.components(separatedBy: "\u{1f}")
                guard parts.count >= 4 else { return nil }
                return FileCommit(hash: parts[0], author: parts[1], time: TimeInterval(parts[2]) ?? 0, subject: parts[3])
            }
            self.historyTable.reloadData()
        }
    }

    // MARK: - Colour

    private func tint(for line: GitBlameLine) -> NSColor {
        if line.isUncommitted { return NSColor.systemYellow.withAlphaComponent(0.18) }
        switch colorModePopup.indexOfSelectedItem {
        case 0: return authorColor(for: line.author)
        case 1: return ageColor(for: line.authorTime)
        default: return .clear
        }
    }

    private func authorColor(for author: String) -> NSColor {
        var hash: UInt32 = 5381
        for byte in author.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt32(byte)
        }
        return NSColor(calibratedHue: CGFloat(hash % 360) / 360.0, saturation: 0.35, brightness: 0.88, alpha: 0.25)
    }

    /// Interpolates between the *Newest* and *Oldest* colours of Settings ▸ Blame over this file's
    /// age range, as TortoiseGitBlame does.
    private func ageColor(for time: TimeInterval) -> NSColor {
        let config = ConfigManager.shared
        let newest = NSColor(hexString: config.blameNewestColorHex)?.usingColorSpace(.sRGB) ?? .systemOrange
        let oldest = NSColor(hexString: config.blameOldestColorHex)?.usingColorSpace(.sRGB) ?? .systemBlue
        let span = newestTime - oldestTime
        let fraction = span > 0 ? CGFloat((newestTime - time) / span) : 0
        return (newest.blended(withFraction: fraction, of: oldest) ?? newest).withAlphaComponent(0.28)
    }

    @objc private func refreshRowTints() {
        tableView.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? BlameRowView, row < self.lines.count else { return }
            self.configure(rowView, row: row)
        }
    }

    private func configure(_ rowView: BlameRowView, row: Int) {
        let line = lines[row]
        rowView.highlightColor = tint(for: line)
        let emphasised = line.hash == (hoverHash ?? focusHash)
        rowView.emphasis = emphasised ? NSColor.controlAccentColor.withAlphaComponent(hoverHash != nil ? 0.16 : 0.22) : nil
    }

    // MARK: - Find, go to line, blocks

    private func matches(_ line: GitBlameLine, _ query: String) -> Bool {
        line.code.lowercased().contains(query) || line.author.lowercased().contains(query) || line.hash.hasPrefix(query)
            || line.summary.lowercased().contains(query)
    }

    @objc private func findNext() { find(forward: true) }
    @objc private func findPrevious() { find(forward: false) }

    /// Moves the selection to the next match instead of filtering rows (TortoiseGitBlame's F3 / Shift-F3).
    private func find(forward: Bool) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, !lines.isEmpty else { return }
        if let number = Int(query), number > 0, number <= lines.count {
            select(row: number - 1)
            return
        }
        let start = tableView.selectedRow
        let count = lines.count
        for offset in 1...count {
            let row = ((start < 0 ? (forward ? -1 : 0) : start) + (forward ? offset : -offset) + count) % count
            if matches(lines[row], query) {
                select(row: row)
                return
            }
        }
        NSSound.beep()
        statusLabel.stringValue = "“\(query)” not found"
    }

    @objc private func goToLine() {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "1–\(lines.count)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let number = Int(field.stringValue), number > 0, number <= lines.count else { return }
        select(row: number - 1)
    }

    @objc private func nextBlock() { moveBlock(forward: true) }
    @objc private func previousBlock() { moveBlock(forward: false) }

    private func moveBlock(forward: Bool) {
        let starts = GitBlame.blockStarts(lines)
        let current = tableView.selectedRow
        let target: Int?
        if forward {
            target = starts.first { $0 > current }
        } else {
            // Start of the block before the one holding the selection.
            let currentStart = starts.last { $0 <= current } ?? lines.count
            target = starts.last { $0 < currentStart }
        }
        if let target { select(row: target) }
    }

    private func select(row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(min(lines.count - 1, row + 5))
        tableView.scrollRowToVisible(max(0, row - 5))
        window?.makeFirstResponder(tableView)
    }

    // MARK: - Commit actions

    /// Line the action applies to: the clicked row, else the first selected one.
    private var actionLine: GitBlameLine? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        return row >= 0 && row < lines.count ? lines[row] : nil
    }

    /// *Blame previous revision*: blames the line's file in the commit before the one that last
    /// changed it, following renames via the porcelain `previous` header.
    private func blamePrevious() {
        guard let line = actionLine, let root = repositoryRoot else { return }
        guard let previous = line.previousHash, let file = line.previousFilename else {
            ToolDialog.showMessage("No previous revision", "Commit \(line.hash.prefix(8)) added this line; there is nothing older to blame.", in: window)
            return
        }
        let target = root.appendingPathComponent(file)
        let originalLine = line.originalLine
        WindowRegistry.shared.present({ BlameWindowController(filePath: target, revision: previous, line: originalLine) },
                                      key: "blame|\(previous)|\(target.rawPath)", repository: root)
    }

    /// *Compare with previous revision*: the line's commit against its parent, for the file as
    /// named in each (a renamed file is shown as a unified diff).
    private func compareWithPrevious() {
        guard let line = actionLine, let root = repositoryRoot, !line.isUncommitted else { return }
        let file = line.filename.isEmpty ? relativePath : line.filename
        let previousFile = line.previousFilename ?? file
        if previousFile == file {
            DiffWindowController.present(filePath: root.appendingPathComponent(file), oldRevision: line.previousHash ?? "\(line.hash)~1",
                                         newRevision: line.hash, repository: root)
            return
        }
        let args = ["diff", "\(line.previousHash ?? line.hash + "~1"):\(previousFile)", "\(line.hash):\(file)"]
        Task { @MainActor in
            do {
                let data = try await GitCLIRunner.runDataAsync(arguments: args, workingDirectory: root)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinGit-Diff", isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let target = url.appendingPathComponent("\(line.hash.prefix(8))-\((file as NSString).lastPathComponent).diff")
                try data.write(to: target, options: .atomic)
                PatchViewerWindowController.present(target)
            } catch {
                ToolDialog.showError(error, in: self.window)
            }
        }
    }

    private func showLog() {
        guard let root = repositoryRoot else { return }
        CommandRouter.shared.execute(command: .log, targetPath: root.rawPath)
    }

    private func copyHash() {
        guard let line = actionLine else { return }
        copyToPasteboard(line.hash)
    }

    /// Full message of a commit (cached; the porcelain output only carries the summary).
    private func message(for hash: String) async -> String {
        if let cached = messageCache[hash] { return cached }
        guard let root = repositoryRoot else { return "" }
        let text = ((try? await GitCLIRunner.runAsync(arguments: ["log", "-1", "--format=%B", hash], workingDirectory: root)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        messageCache[hash] = text
        return text
    }

    private func copyLogMessage() {
        guard let line = actionLine, !line.isUncommitted else { return }
        Task { @MainActor in
            let text = await self.message(for: line.hash)
            self.copyToPasteboard("\(line.hash)\n\(line.author) <\(line.authorMail)>\n\(self.dateString(line.authorTime))\n\n\(text)")
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘C copies the selected lines' code.
    @objc func copy(_ sender: Any?) {
        let text = tableView.selectedRowIndexes.compactMap { $0 < lines.count ? lines[$0].code : nil }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        copyToPasteboard(text)
    }

    private func dateString(_ time: TimeInterval) -> String {
        dateFormatter.string(from: Date(timeIntervalSince1970: time))
    }

    // MARK: - User actions

    @objc private func onOptionChanged() {
        let config = ConfigManager.shared
        config.blameIgnoreWhitespace = ignoreWhitespaceCheck.state == .on
        config.blameMoveDetection = GitBlame.MoveDetection(rawValue: detectionPopup.indexOfSelectedItem) ?? .disabled
        config.blameFirstParent = firstParentCheck.state == .on
        loadBlame()
    }

    @objc private func onRowDoubleClicked() {
        guard tableView.clickedRow >= 0, tableView.clickedRow < lines.count else { return }
        compareWithPrevious()
    }

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === historyTable ? history.count : lines.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let cellId = NSUserInterfaceItemIdentifier((tableView === historyTable ? "History_" : "Blame_") + column.identifier.rawValue)
        let text = (tableView.makeView(withIdentifier: cellId, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = cellId
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        text.toolTip = nil
        if tableView === historyTable {
            let commit = history[row]
            switch column.identifier.rawValue {
            case "hash":
                text.stringValue = String(commit.hash.prefix(8))
                text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            case "author":
                text.stringValue = commit.author
            default:
                text.stringValue = commit.subject
                text.toolTip = "\(commit.subject)\n\(commit.author), \(dateString(commit.time))"
            }
            return text
        }

        let line = lines[row]
        let config = ConfigManager.shared
        let fontSize = CGFloat(config.blameFontSize)
        let codeFont = NSFont(name: config.blameFontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let tooltip = line.isUncommitted ? "Not committed yet" : "\(line.hash.prefix(10)) — \(line.author), \(dateString(line.authorTime))\n\(line.summary)"
        text.alignment = .left
        text.textColor = .labelColor
        switch column.identifier.rawValue {
        case "line":
            text.stringValue = "\(line.finalLine)"
            text.alignment = .right
            text.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            text.textColor = .tertiaryLabelColor
        case "hash":
            text.stringValue = line.isUncommitted ? "—" : String(line.hash.prefix(8))
            text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            text.textColor = .linkColor
            text.toolTip = tooltip
        case "author":
            text.stringValue = line.isUncommitted ? "(uncommitted)" : line.author
            text.font = NSFont.systemFont(ofSize: 11)
            text.toolTip = tooltip
        case "date":
            text.stringValue = line.isUncommitted ? "" : dateString(line.authorTime)
            text.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            text.textColor = .secondaryLabelColor
            text.toolTip = tooltip
        case "file":
            text.stringValue = line.filename
            text.font = NSFont.systemFont(ofSize: 11)
            text.textColor = line.filename == relativePath ? .tertiaryLabelColor : .labelColor
        case "orig":
            text.stringValue = "\(line.originalLine)"
            text.alignment = .right
            text.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            text.textColor = .tertiaryLabelColor
        default:
            text.stringValue = line.code
            text.font = codeFont
        }
        return text
    }

    /// Row views are reused (they used to be recreated for every row on every draw).
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard tableView === self.tableView else { return nil }
        let id = NSUserInterfaceItemIdentifier("BlameRow")
        let rowView = (tableView.makeView(withIdentifier: id, owner: self) as? BlameRowView) ?? {
            let view = BlameRowView()
            view.identifier = id
            return view
        }()
        if row < lines.count { configure(rowView, row: row) }
        return rowView
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === historyTable {
            let row = historyTable.selectedRow
            guard row >= 0, row < history.count else { return }
            let hash = history[row].hash
            focusHash = hash
            if let first = lines.firstIndex(where: { $0.hash == hash }) {
                tableView.scrollRowToVisible(first)
                statusLabel.stringValue = "\(lines.filter { $0.hash == hash }.count) line(s) from \(hash.prefix(8))"
            } else {
                statusLabel.stringValue = "No line of this version comes from \(hash.prefix(8))"
            }
            return
        }
        let row = tableView.selectedRow
        guard row >= 0, row < lines.count else {
            focusHash = nil
            inspectorTitle.stringValue = "Select a line to see its commit."
            inspectorMessage.stringValue = ""
            commitButtons.forEach { $0.isEnabled = false }
            return
        }
        let line = lines[row]
        focusHash = line.hash
        commitButtons.forEach { $0.isEnabled = !line.isUncommitted }
        if line.isUncommitted {
            inspectorTitle.stringValue = "Line \(line.finalLine): not committed yet"
            inspectorMessage.stringValue = ""
            return
        }
        inspectorTitle.stringValue = "\(line.hash.prefix(10))  \(line.author) <\(line.authorMail)>  \(dateString(line.authorTime))"
        inspectorMessage.stringValue = line.summary
        if let index = history.firstIndex(where: { $0.hash == line.hash }) {
            historyTable.scrollRowToVisible(index)
            historyTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            focusHash = line.hash
        }
        let hash = line.hash
        Task { @MainActor in
            let message = await self.message(for: hash)
            if self.focusHash == hash, !message.isEmpty { self.inspectorMessage.stringValue = message }
        }
    }
}

extension BlameWindowController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === tableView.headerView?.menu {
            // Column toggles (TortoiseGitBlame's View ▸ Show … entries).
            for column in tableView.tableColumns where column.identifier.rawValue != "code" {
                let item = ClosureMenuItem(title: column.title) { column.isHidden.toggle() }
                item.state = column.isHidden ? .off : .on
                menu.addItem(item)
            }
            return
        }
        if menu === historyTable.menu {
            let row = historyTable.clickedRow
            guard row >= 0, row < history.count, let root = repositoryRoot else { return }
            let commit = history[row]
            let file = filePath
            menu.addItem(ClosureMenuItem(title: "Blame This Revision", symbol: "person.text.rectangle") {
                WindowRegistry.shared.present({ BlameWindowController(filePath: file, revision: commit.hash) },
                                              key: "blame|\(commit.hash)|\(file.rawPath)", repository: root)
            })
            menu.addItem(ClosureMenuItem(title: "Compare with Previous Revision", symbol: "arrow.left.arrow.right") {
                DiffWindowController.present(filePath: file, oldRevision: "\(commit.hash)~1", newRevision: commit.hash, repository: root)
            })
            menu.addItem(ClosureMenuItem(title: "Copy SHA-1", symbol: "doc.on.clipboard") { [weak self] in self?.copyToPasteboard(commit.hash) })
            return
        }
        guard let line = actionLine else { return }
        let committed = !line.isUncommitted
        let items: [(String, String, Bool, () -> Void)] = [
            ("Blame Previous Revision", "person.text.rectangle", committed && line.previousHash != nil, { [weak self] in self?.blamePrevious() }),
            ("Compare with Previous Revision", "arrow.left.arrow.right", committed, { [weak self] in self?.compareWithPrevious() }),
            ("Show Log", "clock.arrow.circlepath", committed, { [weak self] in self?.showLog() }),
            ("Copy SHA-1", "doc.on.clipboard", committed, { [weak self] in self?.copyHash() }),
            ("Copy Log Message", "text.quote", committed, { [weak self] in self?.copyLogMessage() }),
            ("Copy Lines", "doc.on.doc", true, { [weak self] in self?.copy(nil) })
        ]
        for (title, symbol, enabled, handler) in items {
            let item = ClosureMenuItem(title: title, symbol: symbol, handler: handler)
            item.isEnabled = enabled
            menu.addItem(item)
        }
    }
}

/// Table that reports the row under the mouse, for TortoiseGitBlame's hover highlighting.
final class BlameTableView: NSTableView {
    var onHover: ((Int?) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        onHover?(row >= 0 ? row : nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }
}

/// Row view tinted by author/age, with an overlay for the lines of the emphasised commit.
public final class BlameRowView: NSTableRowView {
    public var highlightColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    public var emphasis: NSColor? {
        didSet { needsDisplay = true }
    }

    public override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if highlightColor != .clear {
            highlightColor.setFill()
            dirtyRect.fill()
        }
        if let emphasis {
            emphasis.setFill()
            dirtyRect.fill()
        }
    }
}
