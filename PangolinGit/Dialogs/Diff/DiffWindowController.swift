import Cocoa
import UniformTypeIdentifiers
import PangolinGitCore

/// Two-pane diff viewer mirroring TortoiseGitMerge in diff mode (`/base /mine`): side-by-side or
/// unified, whitespace options, F7/Shift-F7 navigation, find, go to line, collapse/wrap, encoding
/// and line-ending indicators, *Use left block* on working-tree files, Save patch and hand-off to an
/// external diff tool.
public final class DiffWindowController: NSWindowController, NSWindowDelegate {

    /// What the two panes compare (TortoiseGit's *Compare with base* / *Diff staged* / revision pairs).
    enum Comparison: Equatable {
        /// `old` against `new`, or against the working tree when `new` is nil.
        case revisions(old: String, new: String?)
        /// Index against the working tree (`git diff -- path`): unstaged changes only.
        case indexToWorkingTree
        /// HEAD against the index (`git diff --cached`): staged changes only.
        case headToIndex
        /// Two arbitrary files (`git diff --no-index`), TortoiseGit's *Diff* on two selected files.
        case files(left: URL, right: URL)
    }

    private let filePath: PangolinPath
    private var comparison: Comparison
    private let repositoryRoot: PangolinPath?
    private let diffView = SideBySideDiffView()
    private let statusLabel = NSTextField(labelWithString: "Loading diff…")
    private let encodingLabel = NSTextField(labelWithString: "")
    private var comparePopup: NSPopUpButton?
    private var optionsButton: NSPopUpButton!
    private var useLeftBlockButton: NSButton!
    private var options = ConfigManager.shared.diffOptions
    private var rawDiff = ""
    private var loadGeneration = 0

    public convenience init(filePath: PangolinPath, oldRevision: String = "HEAD", newRevision: String? = nil) {
        self.init(filePath: filePath, comparison: .revisions(old: oldRevision, new: newRevision))
    }

    /// Compares two files outside (or inside) a repository.
    public convenience init(leftFile: URL, rightFile: URL) {
        self.init(filePath: PangolinPath(rightFile.path), comparison: .files(left: leftFile, right: rightFile))
    }

    init(filePath: PangolinPath, comparison: Comparison) {
        self.filePath = filePath
        self.comparison = comparison
        self.repositoryRoot = GitRepository.open(at: filePath)?.workingDirectory
        let window = NSWindow(
            contentRect: NSRect(x: 140, y: 140, width: 1080, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 720, height: 420)
        window.setFrameAutosaveName("PangolinGitDiffWindow")
        super.init(window: window)
        window.delegate = self

        setupUI()
        updateTitle()
        loadDiff()
        if let repositoryRoot {
            // A working-tree diff follows edits made by other dialogs (and by *Use left block*).
            RepositoryEvents.observe(repositoryRoot, owner: self) { [weak self] in
                guard let self, self.showsWorkingTree else { return }
                self.loadDiff()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// True when the right pane is the file on disk, so blocks can be restored into it.
    private var showsWorkingTree: Bool {
        switch comparison {
        case .revisions(_, let new): return new == nil
        case .indexToWorkingTree: return true
        case .headToIndex, .files: return false
        }
    }

    private var relativePath: String {
        guard let repositoryRoot else { return filePath.rawPath }
        return filePath.relative(to: repositoryRoot) ?? filePath.rawPath
    }

    private func updateTitle() {
        let range: String
        switch comparison {
        case .revisions(let old, let new): range = new.map { "\(Self.short(old)) ↔ \(Self.short($0))" } ?? "\(Self.short(old)) ↔ working tree"
        case .indexToWorkingTree: range = "index ↔ working tree"
        case .headToIndex: range = "HEAD ↔ index"
        case .files(let left, _): range = "\(left.lastPathComponent) ↔ \(filePath.filename)"
        }
        window?.title = "Diff — \(filePath.filename) (\(range))"
    }

    private static func short(_ revision: String) -> String {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit) ? String(revision.prefix(8)) : revision
    }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        var toolbarItems: [NSView] = []
        if case .revisions("HEAD", nil) = comparison, !filePath.isDirectory {
            toolbarItems.append(makeComparePopup())
        }
        let previous = toolButton(symbol: "chevron.up", tip: "Previous difference (⇧F7)", action: #selector(onPreviousDifference))
        previous.keyEquivalent = String(UnicodeScalar(NSF7FunctionKey)!)
        previous.keyEquivalentModifierMask = [.shift]
        let next = toolButton(symbol: "chevron.down", tip: "Next difference (F7)", action: #selector(onNextDifference))
        next.keyEquivalent = String(UnicodeScalar(NSF7FunctionKey)!)
        next.keyEquivalentModifierMask = []
        toolbarItems += [previous, next]

        optionsButton = NSPopUpButton(frame: .zero, pullsDown: true)
        optionsButton.bezelStyle = .texturedRounded
        optionsButton.menu = makeOptionsMenu()
        optionsButton.toolTip = "Whitespace, line-ending and display options"
        toolbarItems.append(optionsButton)

        let find = toolButton(symbol: "magnifyingglass", tip: "Find (⌘F)", action: #selector(onFind))
        find.keyEquivalent = "f"
        find.keyEquivalentModifierMask = [.command]
        let goTo = toolButton(symbol: "arrow.right.to.line", tip: "Go to line (⌘L)", action: #selector(onGoToLine))
        goTo.keyEquivalent = "l"
        goTo.keyEquivalentModifierMask = [.command]
        let reload = toolButton(symbol: "arrow.clockwise", tip: "Reload (⌘R)", action: #selector(onReload))
        reload.keyEquivalent = "r"
        reload.keyEquivalentModifierMask = [.command]
        toolbarItems += [find, goTo, reload]

        useLeftBlockButton = NSButton(title: "Use Left Block", target: self, action: #selector(onUseLeftBlock))
        useLeftBlockButton.bezelStyle = .texturedRounded
        useLeftBlockButton.toolTip = "Replace the current difference in the working-tree file with the left version (F12)"
        useLeftBlockButton.keyEquivalent = String(UnicodeScalar(NSF12FunctionKey)!)
        useLeftBlockButton.keyEquivalentModifierMask = []
        useLeftBlockButton.isHidden = !showsWorkingTree
        useLeftBlockButton.isEnabled = false
        toolbarItems.append(useLeftBlockButton)

        let external = NSButton(title: "External Diff", target: self, action: #selector(onExternalDiff))
        external.bezelStyle = .texturedRounded
        external.toolTip = "Open this comparison in the external diff tool from Settings ▸ Tools"
        external.isEnabled = ExternalToolLauncher.hasExternalDiffTool || !ConfigManager.shared.diffToolOverrides.isEmpty
        let savePatch = NSButton(title: "Save Patch…", target: self, action: #selector(onSavePatch))
        savePatch.bezelStyle = .texturedRounded
        savePatch.keyEquivalent = "s"
        savePatch.keyEquivalentModifierMask = [.command, .shift]
        toolbarItems += [external, savePatch]

        let modeSwitch = NSSegmentedControl(labels: ["Side-by-Side", "Unified"], trackingMode: .selectOne,
                                            target: self, action: #selector(onModeChanged(_:)))
        modeSwitch.selectedSegment = 0
        toolbarItems.append(modeSwitch)

        let toolbar = NSStackView(views: toolbarItems)
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.setHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(toolbar)

        diffView.showsModeSwitch = false
        diffView.translatesAutoresizingMaskIntoConstraints = false
        diffView.onCurrentBlockChange = { [weak self] in self?.updateBlockActions() }
        diffView.contextMenuProvider = { [weak self] side, row in self?.blockMenuItems(side: side, row: row) ?? [] }
        contentView.addSubview(diffView)

        for label in [statusLabel, encodingLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .secondaryLabelColor
            label.font = NSFont.systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingMiddle
            contentView.addSubview(label)
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        encodingLabel.alignment = .right

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),

            diffView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            diffView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            diffView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            diffView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: encodingLabel.leadingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            encodingLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            encodingLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
        ])
    }

    private func toolButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        return button
    }

    private func makeComparePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["HEAD ↔ Working Tree", "Index ↔ Working Tree (unstaged)", "HEAD ↔ Index (staged)"])
        popup.target = self
        popup.action = #selector(onCompareChanged(_:))
        popup.toolTip = "What to compare (TortoiseGit's Compare with base / Diff staged)"
        comparePopup = popup
        return popup
    }

    private func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "View Options", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        menu.addItem(title)

        func header(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func toggle(_ text: String, on: Bool, key: String = "", indent: Int = 1, _ handler: @escaping () -> Void) {
            let item = ClosureMenuItem(title: text) { handler() }
            item.state = on ? .on : .off
            item.indentationLevel = indent
            if !key.isEmpty {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = [.control]
            }
            menu.addItem(item)
        }
        // Rebuilt after each change so the check marks follow the state.
        let rebuild = { [weak self] in
            guard let self else { return }
            self.optionsButton.menu = self.makeOptionsMenu()
        }

        header("Whitespace")
        let whitespaceTitles: [(GitDiffOptions.Whitespace, String)] = [
            (.compare, "Compare whitespace"), (.ignoreChanges, "Ignore whitespace changes"),
            (.ignoreAll, "Ignore all whitespace"), (.ignoreAtEOL, "Ignore whitespace at line end")]
        for (mode, text) in whitespaceTitles {
            toggle(text, on: options.whitespace == mode) { [weak self] in
                self?.options.whitespace = mode
                self?.optionsChanged(); rebuild()
            }
        }
        toggle("Ignore line endings (CR/LF)", on: options.ignoreLineEndings) { [weak self] in
            guard let self else { return }
            self.options.ignoreLineEndings.toggle()
            self.optionsChanged(); rebuild()
        }
        toggle("Ignore blank lines", on: options.ignoreBlankLines) { [weak self] in
            guard let self else { return }
            self.options.ignoreBlankLines.toggle()
            self.optionsChanged(); rebuild()
        }
        menu.addItem(.separator())
        header("Inline differences")
        for (mode, text) in [(InlineDiffMode.character, "Character-wise"), (.word, "Word-wise"), (.off, "Off")] {
            toggle(text, on: diffView.inlineMode == mode) { [weak self] in
                self?.diffView.inlineMode = mode
                ConfigManager.shared.inlineDiffMode = mode
                rebuild()
            }
        }
        menu.addItem(.separator())
        header("Display")
        toggle("Collapse unchanged sections", on: diffView.collapseUnchanged) { [weak self] in
            guard let self else { return }
            self.diffView.collapseUnchanged.toggle()
            ConfigManager.shared.diffCollapseUnchanged = self.diffView.collapseUnchanged
            self.updateStatus(); rebuild()
        }
        toggle("Wrap long lines", on: diffView.wrapLines) { [weak self] in
            guard let self else { return }
            self.diffView.wrapLines.toggle()
            ConfigManager.shared.diffWrapLines = self.diffView.wrapLines
            rebuild()
        }
        return menu
    }

    private func optionsChanged() {
        ConfigManager.shared.diffOptions = options
        loadDiff()
    }

    // MARK: - Loading

    /// - Parameter fullContext: whole files, so unchanged sections can be collapsed and expanded
    ///   without asking git again; false gives a normal three-line-context patch.
    private func diffArguments(fullContext: Bool = true) -> [String] {
        var args = ["diff", "--no-color", "--no-ext-diff", "-M"] + options.arguments
        if fullContext { args.append("--unified=1000000") }
        let path = relativePath.isEmpty ? "." : relativePath
        switch comparison {
        case .revisions(let old, let new):
            args.append(old)
            if let new { args.append(new) }
            args += ["--", path]
        case .indexToWorkingTree:
            args += ["--", path]
        case .headToIndex:
            args += ["--cached", "HEAD", "--", path]
        case .files(let left, let right):
            args += ["--no-index", "--", left.path, right.path]
        }
        return args
    }

    private func loadDiff() {
        loadGeneration += 1
        let generation = loadGeneration
        let args = diffArguments()
        let workingDirectory = repositoryRoot ?? PangolinPath(filePath.url.deletingLastPathComponent().path)
        let isNoIndex: Bool = { if case .files = comparison { return true } else { return false } }()

        Task { @MainActor in
            do {
                let result = try await GitCLIRunner().run(arguments: args, workingDirectory: workingDirectory)
                // `--no-index` exits 1 when the files differ.
                guard result.isSuccess || (isNoIndex && result.exitCode == 1) else {
                    throw GitCLIError.commandFailed(exitCode: result.exitCode, stderr: result.standardError, command: GitCLIRunner.commandLine(args))
                }
                guard generation == self.loadGeneration else { return }
                // Not every file is UTF-8; decode the way the file itself would be decoded.
                let text = TextFileEncoding.decode(result.standardOutputData)?.text ?? result.standardOutput
                self.rawDiff = text
                self.diffView.setDiff(rawUnifiedText: text)
                self.updateStatus()
                if self.diffView.currentBlockIndex == nil { self.diffView.goToFirstDifference() }
                self.updateBlockActions()
            } catch {
                self.statusLabel.stringValue = "Failed to run diff: \(error.localizedDescription)"
            }
            await self.loadEncodingInfo(generation: generation)
        }
    }

    private func updateStatus() {
        let rows = diffView.rows
        let added = rows.filter { $0.kind == .added || $0.kind == .modified }.count
        let removed = rows.filter { $0.kind == .deleted || $0.kind == .modified }.count
        if rawDiff.isEmpty {
            statusLabel.stringValue = "No differences" + (options.isDefault ? "." : " (with the current whitespace options).")
        } else if rows.contains(where: { $0.kind == .header && $0.leftText.hasPrefix("Binary files") }) && diffView.blocks.isEmpty {
            statusLabel.stringValue = "Binary files differ — no text comparison is possible."
        } else {
            let blocks = diffView.blocks.count
            let path = relativePath.isEmpty ? "Whole working tree" : relativePath
            statusLabel.stringValue = "\(path) — \(blocks) difference\(blocks == 1 ? "" : "s"), +\(added) / −\(removed) lines"
        }
    }

    /// Encoding and line-ending style of both sides (TortoiseMerge's status-bar combos).
    private func loadEncodingInfo(generation: Int) async {
        async let left = sideData(left: true)
        async let right = sideData(left: false)
        let (leftData, rightData) = await (left, right)
        guard generation == loadGeneration else { return }
        func describe(_ data: Data?) -> String {
            guard let data else { return "—" }
            guard let decoded = TextFileEncoding.decode(data) else { return "binary" }
            return "\(decoded.encodingName) · \(decoded.lineEnding.rawValue)"
        }
        encodingLabel.stringValue = "Left: \(describe(leftData))   Right: \(describe(rightData))"
    }

    private func sideData(left: Bool) async -> Data? {
        guard !filePath.isDirectory else { return nil }
        func blob(_ spec: String) async -> Data? {
            guard let repositoryRoot else { return nil }
            return try? await GitCLIRunner.runDataAsync(arguments: ["show", spec], workingDirectory: repositoryRoot)
        }
        let path = relativePath
        switch comparison {
        case .revisions(let old, let new):
            if left { return await blob("\(old):\(path)") }
            if let new { return await blob("\(new):\(path)") }
            return try? Data(contentsOf: filePath.url)
        case .indexToWorkingTree:
            return left ? await blob(":\(path)") : try? Data(contentsOf: filePath.url)
        case .headToIndex:
            return await blob(left ? "HEAD:\(path)" : ":\(path)")
        case .files(let leftURL, let rightURL):
            return try? Data(contentsOf: left ? leftURL : rightURL)
        }
    }

    // MARK: - Actions

    @objc private func onCompareChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 1: comparison = .indexToWorkingTree
        case 2: comparison = .headToIndex
        default: comparison = .revisions(old: "HEAD", new: nil)
        }
        useLeftBlockButton.isHidden = !showsWorkingTree
        updateTitle()
        loadDiff()
    }

    @objc private func onModeChanged(_ sender: NSSegmentedControl) {
        diffView.viewMode = SideBySideDiffView.ViewMode(rawValue: sender.selectedSegment) ?? .sideBySide
    }

    @objc private func onNextDifference() { diffView.goToNextDifference() }
    @objc private func onPreviousDifference() { diffView.goToPreviousDifference() }
    @objc private func onFind() { diffView.showFindBar() }
    @objc private func onReload() { loadDiff() }

    @objc private func onGoToLine() {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Line number in the right-hand file:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let line = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
            if self?.diffView.goToLine(line) == false { NSSound.beep() }
        }
    }

    private func updateBlockActions() {
        useLeftBlockButton.isEnabled = showsWorkingTree && diffView.currentBlockIndex != nil && !filePath.isDirectory
    }

    private func blockMenuItems(side: SideBySideDiffView.Side, row: Int?) -> [NSMenuItem] {
        guard showsWorkingTree, !filePath.isDirectory, let row, let block = diffView.blockIndex(containing: row) else { return [] }
        return [ClosureMenuItem(title: "Use Left Block (Restore This Change)", symbol: "arrow.uturn.backward") { [weak self] in
            self?.useLeftBlock(block)
        }]
    }

    @objc private func onUseLeftBlock() {
        guard let index = diffView.currentBlockIndex else { return }
        useLeftBlock(index)
    }

    /// Restores one difference in the working-tree file from the left side — TortoiseMerge's
    /// *Use left block* followed by Save. Undoable with ⌘Z while the window is open.
    private func useLeftBlock(_ blockIndex: Int) {
        guard showsWorkingTree, diffView.blocks.indices.contains(blockIndex) else { return }
        let url = filePath.url
        guard let data = try? Data(contentsOf: url), let decoded = TextFileEncoding.decode(data) else {
            showError("The working-tree file could not be read as text.")
            return
        }
        let lines = decoded.text.components(separatedBy: "\n")
        let eol = decoded.lineEnding == .crlf ? "\r" : ""
        guard let restored = SideBySideDiffBuilder.applyLeftBlock(rows: diffView.rows, block: diffView.blocks[blockIndex], to: lines, lineEnding: eol),
              let newData = decoded.encode(restored.joined(separator: "\n")) else {
            showError("The file changed since the diff was loaded. Reload (⌘R) and try again.")
            return
        }
        write(newData, to: url, undoData: data)
    }

    private func write(_ data: Data, to url: URL, undoData: Data) {
        do {
            try data.write(to: url)
        } catch {
            showError("Could not write the file: \(error.localizedDescription)")
            return
        }
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.write(undoData, to: url, undoData: data)
        }
        window?.undoManager?.setActionName("Use Left Block")
        if let repositoryRoot { RepositoryEvents.post(repositoryRoot) }
        loadDiff()
    }

    @objc private func onExternalDiff() {
        let command = ExternalToolLauncher.diffCommand(for: filePath.filename, alternative: !ConfigManager.shared.useExternalDiffTool)
        guard let command else {
            showError("No external diff tool is configured. Choose one in Settings ▸ Tools.")
            return
        }
        Task { @MainActor in
            guard let files = await self.externalFiles() else { return }
            ExternalToolLauncher.launchDiff(commandLine: command, files: files)
        }
    }

    /// Materialises both sides as files for an external tool.
    private func externalFiles() async -> ExternalToolCommand.Files? {
        let path = relativePath
        let root = repositoryRoot?.rawPath ?? ""
        func temp(_ revision: String) async -> String {
            guard let repositoryRoot, let url = await Self.extract(path, at: revision, root: repositoryRoot) else { return "/dev/null" }
            return url.path
        }
        switch comparison {
        case .revisions(let old, let new):
            let base = await temp(old)
            let mine = new != nil ? await temp(new!) : filePath.rawPath
            return ExternalToolCommand.Files(base: base, mine: mine, baseName: "\(filePath.filename) (\(Self.short(old)))",
                                             mineName: "\(filePath.filename) (\(new.map(Self.short) ?? "working tree"))",
                                             baseRevision: old, mineRevision: new ?? "", workingTreeRoot: root)
        case .indexToWorkingTree:
            return ExternalToolCommand.Files(base: await temp(""), mine: filePath.rawPath, baseName: "\(filePath.filename) (index)",
                                             mineName: "\(filePath.filename) (working tree)", workingTreeRoot: root)
        case .headToIndex:
            return ExternalToolCommand.Files(base: await temp("HEAD"), mine: await temp(""), baseName: "\(filePath.filename) (HEAD)",
                                             mineName: "\(filePath.filename) (index)", workingTreeRoot: root)
        case .files(let left, let right):
            return ExternalToolCommand.Files(base: left.path, mine: right.path, workingTreeRoot: root)
        }
    }

    @objc private func onSavePatch() {
        guard let window, !rawDiff.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(filePath.filename).patch"
        panel.allowedContentTypes = [UTType(filenameExtension: "patch") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let args = self.diffArguments(fullContext: false)
            Task { @MainActor in
                do {
                    let result = try await GitCLIRunner().run(arguments: args, workingDirectory: self.repositoryRoot)
                    try result.standardOutputData.write(to: url)
                } catch {
                    self.showError("Could not save the patch: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Diff"
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

extension DiffWindowController {
    /// Opens the right viewer for `filePath`: the Compare Revisions list for a folder, the submodule
    /// summary for a submodule, the image comparison for images (TortoiseGit hands those to
    /// TortoiseGitIDiff), an external diff tool when configured (⌥ inverts), the text diff otherwise.
    /// - Parameters:
    ///   - oldRevision: left side.
    ///   - newRevision: right side; nil means the working-tree file.
    @MainActor
    static func present(filePath: PangolinPath, oldRevision: String = "HEAD", newRevision: String? = nil, repository: PangolinPath?) {
        let key = "diff|\(oldRevision)|\(newRevision ?? "")|\(filePath.rawPath)"
        let root = repository ?? GitRepository.open(at: filePath)?.workingDirectory
        let relative = root.flatMap { filePath.relative(to: $0) }

        if filePath.isDirectory, let root, let relative {
            if SubmoduleDiffWindowController.isSubmodule(filePath, root: root) {
                WindowRegistry.shared.present({ SubmoduleDiffWindowController(root: root, submodulePath: relative, oldRevision: oldRevision, newRevision: newRevision) },
                                              key: key, repository: root)
                return
            }
            // TortoiseGit lists a folder's changes in the file-diff dialog rather than one giant text.
            WindowRegistry.shared.present({ FileDiffWindowController(repositoryPath: root, rev1: oldRevision, rev2: newRevision ?? "",
                                                                     pathFilter: relative) },
                                          key: key, repository: root)
            return
        }

        // TortoiseGit's PickDiffTool order: a per-extension tool, then the image viewer, then the global tool.
        let hasOverride = ExternalToolCommand.override(for: filePath.filename, in: ConfigManager.shared.diffToolOverrides) != nil
        if let command = ExternalToolLauncher.diffCommand(for: filePath.filename), hasOverride || !isImage(filePath), let root, let relative {
            Task { @MainActor in
                let base = await extract(relative, at: oldRevision, root: root)?.path ?? "/dev/null"
                let mine = newRevision != nil ? (await extract(relative, at: newRevision!, root: root)?.path ?? "/dev/null") : filePath.rawPath
                ExternalToolLauncher.launchDiff(commandLine: command, files: ExternalToolCommand.Files(
                    base: base, mine: mine, baseName: "\(filePath.filename) (\(short(oldRevision)))",
                    mineName: "\(filePath.filename) (\(newRevision.map(short) ?? "working tree"))",
                    baseRevision: oldRevision, mineRevision: newRevision ?? "", workingTreeRoot: root.rawPath))
            }
            return
        }

        guard isImage(filePath), let root, let relative else {
            WindowRegistry.shared.present({ DiffWindowController(filePath: filePath, oldRevision: oldRevision, newRevision: newRevision) },
                                          key: key, repository: repository)
            return
        }
        Task { @MainActor in
            let old = await extract(relative, at: oldRevision, root: root)
            let new: URL?
            if let newRevision {
                new = await extract(relative, at: newRevision, root: root)
            } else {
                new = FileManager.default.fileExists(atPath: filePath.rawPath) ? filePath.url : nil
            }
            WindowRegistry.shared.present({ ImageDiffWindowController(oldImageURL: old, newImageURL: new) }, key: key, repository: root)
        }
    }

    /// Diffs two arbitrary files (TortoiseGit's *Diff* with two files selected).
    @MainActor
    static func presentFiles(left: URL, right: URL) {
        let key = "difftwo|\(left.path)|\(right.path)"
        if let command = ExternalToolLauncher.diffCommand(for: right.lastPathComponent) {
            ExternalToolLauncher.launchDiff(commandLine: command, files: ExternalToolCommand.Files(base: left.path, mine: right.path))
            return
        }
        if isImage(PangolinPath(right.path)) {
            WindowRegistry.shared.present({ ImageDiffWindowController(oldImageURL: left, newImageURL: right) }, key: key)
            return
        }
        WindowRegistry.shared.present({ DiffWindowController(leftFile: left, rightFile: right) }, key: key)
    }

    /// TortoiseGit's *Diff with previous version*: the working file against the version before the
    /// last commit that touched it (`PrevDiffCommand.cpp`); for a folder, HEAD~1 against the working tree.
    @MainActor
    static func presentPrevious(filePath: PangolinPath, repository root: PangolinPath) {
        guard let relative = filePath.relative(to: root) else { return }
        if filePath.isDirectory {
            WindowRegistry.shared.present({ FileDiffWindowController(repositoryPath: root, rev1: "HEAD~1", rev2: "", pathFilter: relative) },
                                          key: "diffprevious|\(filePath.rawPath)", repository: root)
            return
        }
        Task { @MainActor in
            let output = (try? await GitCLIRunner.runAsync(arguments: ["log", "-2", "--format=%H", "--", relative.isEmpty ? "." : relative],
                                                           workingDirectory: root)) ?? ""
            let hashes = output.split(separator: "\n").map(String.init)
            guard hashes.count == 2 else {
                let alert = NSAlert()
                alert.messageText = "No Previous Version"
                alert.informativeText = "“\(filePath.filename)” has no earlier committed version to compare with."
                alert.runModal()
                return
            }
            present(filePath: filePath, oldRevision: hashes[1], newRevision: nil, repository: root)
        }
    }

    static func isImage(_ path: PangolinPath) -> Bool {
        UTType(filenameExtension: path.url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Writes `revision:path` to a temporary file (`revision` "" means the index); nil when the file
    /// does not exist at that revision.
    static func extract(_ relativePath: String, at revision: String, root: PangolinPath) async -> URL? {
        guard let data = try? await GitCLIRunner.runDataAsync(arguments: ["show", "\(revision):\(relativePath)"], workingDirectory: root) else {
            return nil
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinGit-Diff", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (relativePath as NSString).lastPathComponent
        let label = revision.isEmpty ? "index" : short(revision).replacingOccurrences(of: "/", with: "_")
        let url = folder.appendingPathComponent("\(label)-\(name)")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
