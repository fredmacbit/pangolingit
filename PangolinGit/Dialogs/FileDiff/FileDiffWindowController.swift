import Cocoa
import UniformTypeIdentifiers
import PangolinGitCore

/// Dialog listing all files changed between two revisions, or between a revision and the working
/// tree (`FileDiffDlg.cpp` in TortoiseGit). Offers revision pickers, *Diff Options*, a context menu
/// (compare, unified diff, revert to either side, blame, log, export, save list, copy) and patches
/// for the selection.
public final class FileDiffWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    public struct ChangedEntry {
        public let path: String
        /// Source path of a rename or copy.
        public let oldPath: String?
        public let statusChar: String
        public let statusDescription: String
        public let linesAdded: Int
        public let linesDeleted: Int
        public let isBinary: Bool

        public var displayPath: String {
            oldPath.map { "\($0) → \(path)" } ?? path
        }

        @MainActor public var statusColor: NSColor {
            switch statusChar.prefix(1) {
            case "M": return DiffColors.modified
            case "A": return DiffColors.added
            case "D": return DiffColors.deleted
            case "R": return .systemPurple
            case "C": return .systemOrange
            default: return .labelColor
            }
        }
    }

    /// git's well-known empty tree; lets "HEAD~1" fall back gracefully in a single-commit repository.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    public let repositoryPath: PangolinPath
    /// Restricts the comparison to a folder or file (TortoiseGit passes the Explorer selection).
    private let pathFilter: String
    private var rev1Field: NSTextField!
    private var rev2Field: NSTextField!
    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var statsLabel: NSTextField!
    private var emptyLabel: NSTextField!
    private var viewDiffBtn: NSButton!
    private var savePatchBtn: NSButton!
    private var exportFilesBtn: NSButton!
    private var optionsButton: NSPopUpButton!

    private var allEntries: [ChangedEntry] = []
    private var filteredEntries: [ChangedEntry] = []
    private var diffOptions = GitDiffOptions()
    /// Compare against the merge base of the two revisions (`rev1...rev2`), Diff Options' *Common ancestor*.
    private var useMergeBase = false
    private var loadGeneration = 0

    /// - Parameters:
    ///   - rev2: target revision; an empty string compares with the working tree.
    ///   - pathFilter: repository-relative path the comparison is limited to ("" = whole repository).
    public init(repositoryPath: PangolinPath, rev1: String = "HEAD~1", rev2: String = "HEAD", pathFilter: String = "") {
        self.repositoryPath = repositoryPath
        self.pathFilter = pathFilter

        let window = NSWindow(
            contentRect: NSRect(x: 140, y: 140, width: 920, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Compare Revisions — \(repositoryPath.filename)" + (pathFilter.isEmpty ? "" : " / \(pathFilter)")
        window.minSize = NSSize(width: 700, height: 450)

        super.init(window: window)
        setupUI(defaultRev1: rev1, defaultRev2: rev2)
        loadDiff()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in
            guard let self, self.targetRevision == nil else { return }
            self.loadDiff()
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var baseRevision: String { rev1Field.stringValue.trimmingCharacters(in: .whitespaces) }
    /// nil means the working tree.
    private var targetRevision: String? {
        let value = rev2Field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
    private var targetLabel: String { targetRevision ?? "working tree" }

    private func setupUI(defaultRev1: String, defaultRev2: String) {
        guard let window = self.window, let contentView = window.contentView else { return }

        let rev1Label = NSTextField(labelWithString: "Base (From):")
        rev1Label.font = NSFont.boldSystemFont(ofSize: 12)
        rev1Field = NSTextField(string: defaultRev1)
        rev1Field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        let swapBtn = NSButton(title: "⇄", target: self, action: #selector(onSwapRevs))
        swapBtn.bezelStyle = .texturedRounded
        swapBtn.toolTip = "Swap Base and Target revisions"

        let rev2Label = NSTextField(labelWithString: "Target (To):")
        rev2Label.font = NSFont.boldSystemFont(ofSize: 12)
        rev2Field = NSTextField(string: defaultRev2)
        rev2Field.placeholderString = "Working tree"
        rev2Field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        let compareBtn = NSButton(title: "Compare", target: self, action: #selector(onCompareClicked))
        compareBtn.bezelStyle = .rounded
        compareBtn.keyEquivalent = "\r"

        let rev1Picker = RevisionPickerButton(repository: repositoryPath) { [weak self] in self?.rev1Field.stringValue = $0; self?.loadDiff() }
        let rev2Picker = RevisionPickerButton(repository: repositoryPath) { [weak self] in self?.rev2Field.stringValue = $0; self?.loadDiff() }
        let workingTreeBtn = NSButton(title: "WT", target: self, action: #selector(onTargetWorkingTree))
        workingTreeBtn.bezelStyle = .texturedRounded
        workingTreeBtn.toolTip = "Compare with the working tree"
        let topBar = NSStackView(views: [rev1Label, rev1Field, rev1Picker, swapBtn, rev2Label, rev2Field, rev2Picker, workingTreeBtn, compareBtn])
        topBar.orientation = .horizontal
        topBar.spacing = 6
        topBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topBar)

        searchField = NSSearchField()
        searchField.placeholderString = "Filter files..."
        searchField.target = self
        searchField.action = #selector(onSearchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(searchField)

        optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
        optionsButton.bezelStyle = .texturedRounded
        optionsButton.translatesAutoresizingMaskIntoConstraints = false
        optionsButton.menu = makeOptionsMenu()
        contentView.addSubview(optionsButton)

        let logButton = NSButton(title: "Show Log", target: self, action: #selector(onShowLog))
        logButton.bezelStyle = .texturedRounded
        logButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(logButton)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(onRowDoubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        for (id, title, width) in [("status", "Status", 90.0), ("path", "File Path", 520.0), ("added", "Added (+)", 80.0), ("deleted", "Deleted (-)", 80.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }

        scroll.documentView = tableView
        contentView.addSubview(scroll)

        emptyLabel = NSTextField(labelWithString: "No differences found!")
        emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emptyLabel)

        statsLabel = NSTextField(labelWithString: "Loading changes...")
        statsLabel.font = NSFont.systemFont(ofSize: 11)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statsLabel)

        viewDiffBtn = NSButton(title: "View Diff", target: self, action: #selector(onViewDiffClicked))
        viewDiffBtn.bezelStyle = .rounded
        viewDiffBtn.isEnabled = false

        savePatchBtn = NSButton(title: "Create Patch...", target: self, action: #selector(onCreatePatchClicked))
        savePatchBtn.bezelStyle = .rounded
        savePatchBtn.toolTip = "Patch of the selected files, or of all files when nothing is selected"

        exportFilesBtn = NSButton(title: "Export Files...", target: self, action: #selector(onExportFilesClicked))
        exportFilesBtn.bezelStyle = .rounded

        let bottomStack = NSStackView(views: [viewDiffBtn, savePatchBtn, exportFilesBtn])
        bottomStack.orientation = .horizontal
        bottomStack.spacing = 8
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),

            searchField.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            searchField.widthAnchor.constraint(equalToConstant: 260),
            optionsButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            optionsButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 10),
            logButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            logButton.leadingAnchor.constraint(equalTo: optionsButton.trailingAnchor, constant: 8),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            statsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statsLabel.centerYAnchor.constraint(equalTo: bottomStack.centerYAnchor),
            statsLabel.trailingAnchor.constraint(lessThanOrEqualTo: bottomStack.leadingAnchor, constant: -12),

            bottomStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bottomStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    /// TortoiseGit's *Diff Options* drop-down.
    private func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Diff Options", action: nil, keyEquivalent: "")
        func item(_ title: String, _ on: Bool, _ handler: @escaping () -> Void) {
            let entry = ClosureMenuItem(title: title) { [weak self] in
                handler()
                self?.optionsButton.menu = self?.makeOptionsMenu()
                self?.loadDiff()
            }
            entry.state = on ? .on : .off
            menu.addItem(entry)
        }
        item("Ignore space at EOL", diffOptions.whitespace == .ignoreAtEOL) { [weak self] in
            guard let self else { return }
            self.diffOptions.whitespace = self.diffOptions.whitespace == .ignoreAtEOL ? .compare : .ignoreAtEOL
        }
        item("Ignore space change", diffOptions.whitespace == .ignoreChanges) { [weak self] in
            guard let self else { return }
            self.diffOptions.whitespace = self.diffOptions.whitespace == .ignoreChanges ? .compare : .ignoreChanges
        }
        item("Ignore all space", diffOptions.whitespace == .ignoreAll) { [weak self] in
            guard let self else { return }
            self.diffOptions.whitespace = self.diffOptions.whitespace == .ignoreAll ? .compare : .ignoreAll
        }
        item("Ignore blank lines", diffOptions.ignoreBlankLines) { [weak self] in self?.diffOptions.ignoreBlankLines.toggle() }
        menu.addItem(.separator())
        item("Compare with common ancestor", useMergeBase) { [weak self] in self?.useMergeBase.toggle() }
        return menu
    }

    // MARK: - Loading

    /// Revision arguments for `git diff`: `a b`, `a...b` for the common ancestor, or `a` for the working tree.
    private func revisionArguments(base: String) -> [String] {
        guard let target = targetRevision else { return [base] }
        return useMergeBase ? ["\(base)...\(target)"] : [base, target]
    }

    private var pathspec: [String] {
        pathFilter.isEmpty ? [] : ["--", pathFilter]
    }

    private func loadDiff() {
        let requestedBase = baseRevision
        loadGeneration += 1
        let generation = loadGeneration
        statsLabel.stringValue = "Running diff for \(requestedBase) ↔ \(targetLabel)…"

        Task { @MainActor in
            // A single-commit repository has no HEAD~1: compare with the empty tree instead.
            var base = requestedBase
            if (try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "--verify", "--quiet", "\(base)^{tree}"], workingDirectory: self.repositoryPath)) == nil,
               base.hasSuffix("~1") || base.hasSuffix("^") {
                base = Self.emptyTree
            }
            let common = ["diff", "-M", "-C"] + self.diffOptions.arguments + self.revisionArguments(base: base) + self.pathspec
            do {
                async let nameStatus = GitCLIRunner.runAsync(arguments: Array(common.prefix(1)) + ["--name-status", "-z"] + common.dropFirst(), workingDirectory: self.repositoryPath)
                async let numstat = try? GitCLIRunner.runAsync(arguments: Array(common.prefix(1)) + ["--numstat", "-z"] + common.dropFirst(), workingDirectory: self.repositoryPath)
                let parsed = Self.parseDiffOutput(nameStatusZ: try await nameStatus, numstat: await numstat ?? "")
                guard generation == self.loadGeneration else { return }
                self.allEntries = parsed
                self.applySearchFilter()
                self.updateStatsLabel(base: base)
            } catch {
                guard generation == self.loadGeneration else { return }
                self.allEntries = []
                self.applySearchFilter()
                self.emptyLabel.isHidden = true
                self.statsLabel.stringValue = "Diff error: \(error.localizedDescription)"
            }
        }
    }

    /// Parses `--name-status -z` (`M\0path\0`, `R100\0old\0new\0`) and `--numstat -z`.
    static func parseDiffOutput(nameStatusZ: String, numstat: String) -> [ChangedEntry] {
        // -z numstat: "add\tdel\tpath\0", or for renames/copies "add\tdel\t\0old\0new\0"; binaries show "-".
        var numstatMap: [String: (added: Int, deleted: Int, binary: Bool)] = [:]
        var fields = numstat.components(separatedBy: "\0")[...]
        while let record = fields.popFirst() {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map { String($0) }
            guard parts.count == 3 else { continue }
            var path = parts[2]
            if path.isEmpty {
                _ = fields.popFirst()
                path = fields.popFirst() ?? ""
            }
            numstatMap[path] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0, parts[0] == "-")
        }

        var result: [ChangedEntry] = []
        var tokens = nameStatusZ.components(separatedBy: "\0").filter { !$0.isEmpty }[...]
        while let status = tokens.popFirst() {
            let isPair = status.hasPrefix("R") || status.hasPrefix("C")
            let oldPath = isPair ? tokens.popFirst() : nil
            guard let path = tokens.popFirst() else { break }
            let desc: String
            switch status.prefix(1) {
            case "M": desc = "Modified"
            case "A": desc = "Added"
            case "D": desc = "Deleted"
            case "R": desc = "Renamed"
            case "C": desc = "Copied"
            case "T": desc = "Type changed"
            case "U": desc = "Unmerged"
            default: desc = status
            }
            let numbers = numstatMap[path] ?? (0, 0, false)
            result.append(ChangedEntry(path: path, oldPath: oldPath, statusChar: status, statusDescription: desc,
                                       linesAdded: numbers.added, linesDeleted: numbers.deleted, isBinary: numbers.binary))
        }
        return result
    }

    private func applySearchFilter() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            filteredEntries = allEntries
        } else {
            filteredEntries = allEntries.filter {
                $0.displayPath.lowercased().contains(q) || $0.statusDescription.lowercased().contains(q)
            }
        }
        tableView.reloadData()
        viewDiffBtn.isEnabled = tableView.selectedRow >= 0
    }

    private func updateStatsLabel(base: String) {
        let totalFiles = allEntries.count
        let totalAdded = allEntries.reduce(0) { $0 + $1.linesAdded }
        let totalDeleted = allEntries.reduce(0) { $0 + $1.linesDeleted }
        emptyLabel.isHidden = totalFiles > 0
        let shownBase = base == Self.emptyTree ? "(empty tree)" : base
        statsLabel.stringValue = "\(shownBase) ↔ \(targetLabel): \(totalFiles) file(s) changed, +\(totalAdded) / -\(totalDeleted) lines"
    }

    // MARK: - Selection helpers

    private var selectedEntries: [ChangedEntry] {
        var rows = tableView.selectedRowIndexes
        if tableView.clickedRow >= 0, !rows.contains(tableView.clickedRow) {
            rows = IndexSet(integer: tableView.clickedRow)
        }
        return rows.filter { $0 < filteredEntries.count }.map { filteredEntries[$0] }
    }

    private func fullPath(_ entry: ChangedEntry) -> PangolinPath {
        PangolinPath(repositoryPath.appending(entry.path).rawPath)
    }

    // MARK: - Actions

    @objc private func onSwapRevs() {
        // The working tree can only be the target.
        guard targetRevision != nil else { NSSound.beep(); return }
        let temp = rev1Field.stringValue
        rev1Field.stringValue = rev2Field.stringValue
        rev2Field.stringValue = temp
        loadDiff()
    }

    @objc private func onTargetWorkingTree() {
        rev2Field.stringValue = ""
        loadDiff()
    }

    @objc private func onCompareClicked() {
        loadDiff()
    }

    @objc private func onSearchChanged() {
        applySearchFilter()
    }

    @objc private func onShowLog() {
        let path = repositoryPath
        WindowRegistry.shared.present({ LogWindowController(repositoryPath: path) }, key: "log|\(path.rawPath)", repository: path)
    }

    @objc private func onRowDoubleClicked() {
        guard tableView.clickedRow >= 0 else { return }
        onViewDiffClicked()
    }

    @objc private func onViewDiffClicked() {
        // TortoiseGit opens one viewer per selected file; cap it so a select-all does not flood the screen.
        for entry in selectedEntries.prefix(12) { showDiff(entry) }
    }

    private func showDiff(_ entry: ChangedEntry) {
        let base = baseRevision
        if let oldPath = entry.oldPath, entry.statusChar.hasPrefix("R") {
            // A rename: compare the old blob with the new one so the content diff survives the move.
            Task { @MainActor in
                guard let leftURL = await DiffWindowController.extract(oldPath, at: base, root: self.repositoryPath) else { return }
                let rightURL: URL?
                if let target = self.targetRevision {
                    rightURL = await DiffWindowController.extract(entry.path, at: target, root: self.repositoryPath)
                } else {
                    rightURL = self.fullPath(entry).url
                }
                guard let rightURL else { return }
                DiffWindowController.presentFiles(left: leftURL, right: rightURL)
            }
            return
        }
        DiffWindowController.present(filePath: fullPath(entry), oldRevision: base, newRevision: targetRevision, repository: repositoryPath)
    }

    @objc private func onCreatePatchClicked() {
        let paths = selectedEntries.flatMap { [$0.oldPath, $0.path].compactMap { $0 } }
        savePatch(paths: paths)
    }

    private func savePatch(paths: [String]) {
        let base = baseRevision
        let savePanel = NSSavePanel()
        savePanel.title = "Save Patch File"
        let safe = { (rev: String) in rev.replacingOccurrences(of: "/", with: "_") }
        savePanel.nameFieldStringValue = "\(repositoryPath.filename)_\(safe(base))_\(safe(targetRevision ?? "working")).patch"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]

        guard savePanel.runModal() == .OK, let targetURL = savePanel.url else { return }
        let args = ["diff", "--no-color", "--binary", "-M"] + diffOptions.arguments + revisionArguments(base: base)
            + (paths.isEmpty ? pathspec : ["--"] + paths)
        Task { @MainActor in
            do {
                let data = try await GitCLIRunner.runDataAsync(arguments: args, workingDirectory: self.repositoryPath)
                try data.write(to: targetURL)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Opens the selection's combined diff in the unified-diff viewer (TortoiseGit's *Show unified diff*).
    private func showUnifiedDiff(_ entries: [ChangedEntry]) {
        let paths = entries.flatMap { [$0.oldPath, $0.path].compactMap { $0 } }
        let args = ["diff", "--no-color", "-M"] + diffOptions.arguments + revisionArguments(base: baseRevision) + ["--"] + paths
        let title = entries.count == 1 ? entries[0].path : "\(entries.count) files"
        let root = repositoryPath
        Task { @MainActor in
            do {
                let text = try await GitCLIRunner.runAsync(arguments: args, workingDirectory: root)
                UnifiedDiffWindowController.present(text: text, title: "\(title) (\(self.baseRevision) ↔ \(self.targetLabel))", repository: root)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// TortoiseGit's *Revert to revision A/B*: checks the files out at `revision` (removing those that
    /// do not exist there). The working tree and index change, so it asks first.
    private func revert(_ entries: [ChangedEntry], to revision: String) {
        guard !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Revert \(entries.count) file(s) to \(revision)?"
        alert.informativeText = "Local changes to these files in the working tree are overwritten."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let root = repositoryPath
        Task { @MainActor in
            var failures: [String] = []
            for entry in entries {
                let exists = (try? await GitCLIRunner.runAsync(arguments: ["cat-file", "-e", "\(revision):\(entry.path)"], workingDirectory: root)) != nil
                let args = exists ? ["checkout", revision, "--", entry.path] : ["rm", "-f", "--ignore-unmatch", "--", entry.path]
                do {
                    try await GitCLIRunner.runAsync(arguments: args, workingDirectory: root)
                } catch {
                    failures.append("\(entry.path): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                let failed = NSAlert()
                failed.messageText = "Some files could not be reverted"
                failed.informativeText = failures.prefix(10).joined(separator: "\n")
                failed.runModal()
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveList(_ entries: [ChangedEntry]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "changed-files.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (entries.map(\.path).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Context menu (TortoiseGit's file-diff list menu)

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        let single = entries.count == 1 ? entries[0] : nil
        let base = baseRevision
        let target = targetRevision

        menu.addItem(ClosureMenuItem(title: entries.count > 1 ? "Compare \(entries.count) Files" : "Compare", symbol: "plusminus") { [weak self] in
            entries.prefix(12).forEach { self?.showDiff($0) }
        })
        menu.addItem(ClosureMenuItem(title: "Show Unified Diff", symbol: "doc.plaintext") { [weak self] in self?.showUnifiedDiff(entries) })
        if let single, ExternalToolLauncher.hasExternalDiffTool {
            menu.addItem(ClosureMenuItem(title: "Compare with External Tool", symbol: "arrow.up.forward.app") { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    let old = await DiffWindowController.extract(single.oldPath ?? single.path, at: base, root: self.repositoryPath)?.path ?? "/dev/null"
                    let new = target != nil ? (await DiffWindowController.extract(single.path, at: target!, root: self.repositoryPath)?.path ?? "/dev/null")
                        : self.fullPath(single).rawPath
                    let command = ExternalToolLauncher.diffCommand(for: single.path, alternative: !ConfigManager.shared.useExternalDiffTool) ?? ""
                    ExternalToolLauncher.launchDiff(commandLine: command, files: ExternalToolCommand.Files(
                        base: old, mine: new, baseName: "\(single.path) (\(base))", mineName: "\(single.path) (\(target ?? "working tree"))",
                        baseRevision: base, mineRevision: target ?? "", workingTreeRoot: self.repositoryPath.rawPath))
                }
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Revert to \(base)", symbol: "arrow.uturn.backward") { [weak self] in self?.revert(entries, to: base) })
        if let target {
            menu.addItem(ClosureMenuItem(title: "Revert to \(target)", symbol: "arrow.uturn.backward") { [weak self] in self?.revert(entries, to: target) })
        }
        menu.addItem(.separator())
        if let single {
            let path = fullPath(single)
            if FileManager.default.fileExists(atPath: path.rawPath), !path.isDirectory {
                menu.addItem(ClosureMenuItem(title: "Blame", symbol: "person.text.rectangle") { [weak self] in
                    WindowRegistry.shared.present({ BlameWindowController(filePath: path) }, key: "blame|\(path.rawPath)", repository: self?.repositoryPath)
                })
            }
            if single.statusChar.hasPrefix("M"), single.linesAdded == 0, single.linesDeleted == 0,
               SubmoduleDiffWindowController.isSubmodule(path, root: repositoryPath) {
                menu.addItem(ClosureMenuItem(title: "Show Submodule Diff", symbol: "shippingbox") { [weak self] in
                    guard let self else { return }
                    WindowRegistry.shared.present({ SubmoduleDiffWindowController(root: self.repositoryPath, submodulePath: single.path,
                                                                                  oldRevision: base, newRevision: target) }, repository: self.repositoryPath)
                })
            }
        }
        menu.addItem(ClosureMenuItem(title: "Show Log", symbol: "clock") { [weak self] in self?.onShowLog() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Create Patch for Selection…", symbol: "doc.badge.plus") { [weak self] in
            self?.savePatch(paths: entries.flatMap { [$0.oldPath, $0.path].compactMap { $0 } })
        })
        menu.addItem(ClosureMenuItem(title: "Export Selection To…", symbol: "square.and.arrow.up") { [weak self] in self?.export(entries) })
        menu.addItem(ClosureMenuItem(title: "Save List of Selected Files To…", symbol: "list.bullet") { [weak self] in self?.saveList(entries) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Copy Paths", symbol: "doc.on.doc") { [weak self] in
            self?.copyToPasteboard(entries.map(\.path).joined(separator: "\n"))
        })
        menu.addItem(ClosureMenuItem(title: "Copy All Information", symbol: "doc.on.clipboard") { [weak self] in
            self?.copyToPasteboard(entries.map { "\($0.statusDescription)\t\($0.displayPath)\t+\($0.linesAdded)\t-\($0.linesDeleted)" }.joined(separator: "\n"))
        })
    }

    @objc private func onExportFilesClicked() {
        let rows = tableView.selectedRowIndexes
        export(rows.isEmpty ? filteredEntries : rows.map { filteredEntries[$0] })
    }

    private func export(_ targetEntries: [ChangedEntry]) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Export Destination Directory"
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true

        guard openPanel.runModal() == .OK, let destURL = openPanel.url else { return }

        let rev2 = targetRevision
        let repoPath = repositoryPath
        // Deleted files have no content on the target side
        let paths = targetEntries.filter { !$0.statusChar.hasPrefix("D") }.map { $0.path }

        Task.detached {
            var exportedCount = 0
            var failures: [String] = []
            for path in paths {
                let destFile = destURL.appendingPathComponent(path)
                do {
                    // Export the blob as committed in rev2 (raw bytes, so binaries survive), or the working file.
                    let data: Data
                    if let rev2 {
                        data = try GitCLIRunner.runData(arguments: ["cat-file", "blob", "\(rev2):\(path)"], workingDirectory: repoPath)
                    } else {
                        data = try Data(contentsOf: repoPath.url.appendingPathComponent(path))
                    }
                    try FileManager.default.createDirectory(at: destFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destFile, options: .atomic)
                    exportedCount += 1
                } catch {
                    failures.append("\(path): \(error.localizedDescription)")
                }
            }

            let count = exportedCount
            let failed = failures
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = failed.isEmpty ? "Export Complete" : "Export Finished With Errors"
                var info = "Exported \(count) file(s) at \(rev2 ?? "working tree") to:\n\(destURL.path)"
                if !failed.isEmpty {
                    info += "\n\nFailed:\n" + failed.prefix(10).joined(separator: "\n")
                }
                alert.informativeText = info
                alert.runModal()
            }
        }
    }

    // MARK: - TableView DataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredEntries.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredEntries.count, let col = tableColumn else { return nil }
        let entry = filteredEntries[row]
        let colId = col.identifier.rawValue

        let cellId = NSUserInterfaceItemIdentifier("FileDiffCell_\(colId)")
        var text = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTextField
        if text == nil {
            text = NSTextField(labelWithString: "")
            text?.identifier = cellId
            text?.isBordered = false
            text?.drawsBackground = false
            text?.lineBreakMode = .byTruncatingMiddle
        }

        switch colId {
        case "status":
            text?.stringValue = entry.statusDescription
            text?.textColor = entry.statusColor
            text?.font = NSFont.boldSystemFont(ofSize: 11)
        case "path":
            text?.stringValue = entry.displayPath
            text?.textColor = .labelColor
            text?.font = NSFont.systemFont(ofSize: 12)
        case "added":
            text?.stringValue = entry.isBinary ? "bin" : (entry.linesAdded > 0 ? "+\(entry.linesAdded)" : "-")
            text?.textColor = DiffColors.added
            text?.alignment = .right
            text?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        case "deleted":
            text?.stringValue = entry.isBinary ? "bin" : (entry.linesDeleted > 0 ? "-\(entry.linesDeleted)" : "-")
            text?.textColor = DiffColors.deleted
            text?.alignment = .right
            text?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        default:
            break
        }
        return text
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        viewDiffBtn.isEnabled = tableView.selectedRow >= 0
    }
}
