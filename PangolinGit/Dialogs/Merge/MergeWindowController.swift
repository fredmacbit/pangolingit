import Cocoa
import PangolinGitCore

/// Three-way conflict editor mirroring TortoiseGitMerge (`src/TortoiseMerge/`): Theirs and Mine on
/// top (with an optional Base pane), the editable Merged result below. The merged text is the single
/// source of truth — conflict blocks are its `<<<<<<<`/`>>>>>>>` regions — so block choices, hand
/// edits and undo mix freely. Pane titles follow the operation (merge, rebase, cherry-pick, revert),
/// the file's encoding and line endings are preserved, and delete/modify, binary and submodule
/// conflicts get TortoiseGit's dedicated choices instead of a bogus text merge.
public final class MergeWindowController: NSWindowController, NSTextViewDelegate, NSWindowDelegate {

    private let targetFile: PangolinPath
    private let root: PangolinPath?
    private let relativePath: String

    private var stages: [Int: UnmergedStage] = [:]
    private var titles = ConflictSideTitles.make(operation: .other, currentBranch: nil, incoming: nil, rebasedBranch: nil, onto: nil)
    /// Encoding/BOM/EOL used to write the result back (the working file's, else Mine's).
    private var fileFormat: DecodedText?
    private var mineText = "" { didSet { sideChanges = nil } }
    private var theirsText = "" { didSet { sideChanges = nil } }
    private var baseText = "" { didSet { sideChanges = nil } }
    /// Lines of Mine/Theirs that differ from Base; computed once per load (the sides never change).
    private var sideChanges: (mine: (changed: Set<Int>, added: Int, removed: Int), theirs: (changed: Set<Int>, added: Int, removed: Int))?
    /// Whether the first section of each conflict block in the merged text is Mine. git writes stage 2
    /// first, which is Theirs during a rebase; `git merge-file` output written by this window puts Mine first.
    private var oursSectionIsMine = true
    private var currentConflict = 0
    private var isDirty = false
    private var helperFiles: [URL] = []
    private var highlightWorkItem: DispatchWorkItem?

    // UI
    private let theirsPane = MergePane(title: "Theirs")
    private let basePane = MergePane(title: "Base")
    private let minePane = MergePane(title: "Mine")
    private let mergedTextView = NSTextView()
    private var mergedHeader = NSTextField(labelWithString: "Merged")
    private var topSplit: NSSplitView!
    private var counterLabel = NSTextField(labelWithString: "")
    private var statusLabel = NSTextField(labelWithString: "Loading…")
    private var formatLabel = NSTextField(labelWithString: "")
    private var blockButtons: [NSButton] = []
    private var useBaseButton: NSButton!
    private var showBaseCheckbox: NSButton!
    private var markResolvedButton: NSButton!
    private var saveButton: NSButton!

    /// Opens the conflict editor, or the external merge tool when one is configured (⌥ inverts).
    @MainActor
    static func present(file: PangolinPath, repository: PangolinPath?) {
        if ExternalToolLauncher.mergeCommand(for: file.filename) != nil {
            // The window still drives the hand-off so helper files and "trust exit code" are handled once.
            let controller = MergeWindowController(targetFile: file, startExternalTool: true)
            WindowRegistry.shared.present({ controller }, key: "merge|\(file.rawPath)", repository: repository)
            return
        }
        WindowRegistry.shared.present({ MergeWindowController(targetFile: file) }, key: "merge|\(file.rawPath)", repository: repository)
    }

    private var startExternalToolAfterLoad: Bool

    public init(targetFile: PangolinPath, startExternalTool: Bool = false) {
        self.targetFile = targetFile
        self.startExternalToolAfterLoad = startExternalTool
        self.root = GitRepository.open(at: targetFile)?.workingDirectory
        self.relativePath = root.flatMap { targetFile.relative(to: $0) } ?? targetFile.filename
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Merge — \(targetFile.filename)"
        window.minSize = NSSize(width: 860, height: 560)
        window.setFrameAutosaveName("PangolinGitMergeWindow")
        super.init(window: window)
        window.delegate = self

        setupUI()
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let toolbar = makeToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(toolbar)

        topSplit = NSSplitView()
        topSplit.isVertical = true
        topSplit.dividerStyle = .thin
        topSplit.addArrangedSubview(theirsPane)
        topSplit.addArrangedSubview(basePane)
        topSplit.addArrangedSubview(minePane)
        basePane.isHidden = !ConfigManager.shared.mergeShowBasePane

        let mergedContainer = NSView()
        mergedHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        mergedHeader.textColor = .secondaryLabelColor
        mergedHeader.translatesAutoresizingMaskIntoConstraints = false
        let mergedScroll = NSScrollView()
        mergedScroll.hasVerticalScroller = true
        mergedScroll.hasHorizontalScroller = true
        mergedScroll.borderType = .bezelBorder
        mergedScroll.translatesAutoresizingMaskIntoConstraints = false
        mergedTextView.frame = NSRect(origin: .zero, size: mergedScroll.contentSize)
        mergedTextView.minSize = .zero
        mergedTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        mergedTextView.isVerticallyResizable = true
        mergedTextView.isHorizontallyResizable = true
        mergedTextView.autoresizingMask = [.width]
        mergedTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        mergedTextView.textContainer?.widthTracksTextView = false
        mergedTextView.font = SideBySideDiffView.diffFont
        mergedTextView.defaultParagraphStyle = SideBySideDiffView.paragraphStyle
        mergedTextView.isRichText = false
        mergedTextView.allowsUndo = true
        mergedTextView.usesFindBar = true
        mergedTextView.isIncrementalSearchingEnabled = true
        mergedTextView.isAutomaticQuoteSubstitutionEnabled = false
        mergedTextView.isAutomaticDashSubstitutionEnabled = false
        mergedTextView.isAutomaticTextReplacementEnabled = false
        mergedTextView.isAutomaticSpellingCorrectionEnabled = false
        mergedTextView.isContinuousSpellCheckingEnabled = false
        mergedTextView.delegate = self
        mergedTextView.menu = nil
        mergedScroll.documentView = mergedTextView
        mergedContainer.addSubview(mergedHeader)
        mergedContainer.addSubview(mergedScroll)
        NSLayoutConstraint.activate([
            mergedHeader.topAnchor.constraint(equalTo: mergedContainer.topAnchor, constant: 4),
            mergedHeader.leadingAnchor.constraint(equalTo: mergedContainer.leadingAnchor, constant: 4),
            mergedScroll.topAnchor.constraint(equalTo: mergedHeader.bottomAnchor, constant: 4),
            mergedScroll.leadingAnchor.constraint(equalTo: mergedContainer.leadingAnchor),
            mergedScroll.trailingAnchor.constraint(equalTo: mergedContainer.trailingAnchor),
            mergedScroll.bottomAnchor.constraint(equalTo: mergedContainer.bottomAnchor),
        ])

        let mainSplit = NSSplitView()
        mainSplit.isVertical = false
        mainSplit.dividerStyle = .thick
        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.addArrangedSubview(topSplit)
        mainSplit.addArrangedSubview(mergedContainer)
        contentView.addSubview(mainSplit)

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        formatLabel.font = .systemFont(ofSize: 11)
        formatLabel.textColor = .secondaryLabelColor
        let footerText = NSStackView(views: [statusLabel, formatLabel])
        footerText.orientation = .vertical
        footerText.alignment = .leading
        footerText.spacing = 2
        footerText.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(footerText)

        let cancel = NSButton(title: "Close", target: self, action: #selector(onCancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "Save", target: self, action: #selector(onSave))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.toolTip = "Save the merged file without marking it resolved (⌘S)"
        markResolvedButton = NSButton(title: "Mark as Resolved", target: self, action: #selector(onMarkResolved))
        markResolvedButton.keyEquivalent = "\r"
        markResolvedButton.keyEquivalentModifierMask = [.command]
        markResolvedButton.toolTip = "Save and stage the file (git add) — ⌘↩"
        let buttons = NSStackView(views: [cancel, saveButton, markResolvedButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttons)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),

            mainSplit.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            mainSplit.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            mainSplit.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            mainSplit.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),

            footerText.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            footerText.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            footerText.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),

            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        DispatchQueue.main.async {
            mainSplit.setPosition(mainSplit.bounds.height * 0.45, ofDividerAt: 0)
        }
    }

    private func makeToolbar() -> NSStackView {
        func key(_ scalar: Int) -> String { String(UnicodeScalar(scalar)!) }
        func button(_ title: String, _ tip: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .texturedRounded
            button.toolTip = tip
            if !key.isEmpty {
                button.keyEquivalent = key
                button.keyEquivalentModifierMask = modifiers
            }
            return button
        }
        let previous = button("◀", "Previous conflict (⇧F8)", #selector(onPreviousConflict), key: key(NSF8FunctionKey), modifiers: [.shift])
        let next = button("▶", "Next conflict (F8)", #selector(onNextConflict), key: key(NSF8FunctionKey))
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let useTheirs = button("Use Theirs", "Use the Theirs block for this conflict (⌃F9)", #selector(onUseTheirs), key: key(NSF9FunctionKey), modifiers: [.control])
        let useMine = button("Use Mine", "Use the Mine block for this conflict (⌃F10)", #selector(onUseMine), key: key(NSF10FunctionKey), modifiers: [.control])
        let theirsFirst = button("Theirs, then Mine", "Use both blocks, Theirs first (⇧⌃F9)", #selector(onTheirsThenMine), key: key(NSF9FunctionKey), modifiers: [.control, .shift])
        let mineFirst = button("Mine, then Theirs", "Use both blocks, Mine first (⇧⌃F10)", #selector(onMineThenTheirs), key: key(NSF10FunctionKey), modifiers: [.control, .shift])
        useBaseButton = button("Use Base", "Use the common ancestor's text for this conflict", #selector(onUseBase))
        blockButtons = [useTheirs, useMine, theirsFirst, mineFirst, useBaseButton]

        let wholeFile = NSPopUpButton(frame: .zero, pullsDown: true)
        wholeFile.bezelStyle = .texturedRounded
        let menu = NSMenu()
        menu.addItem(withTitle: "All Conflicts", action: nil, keyEquivalent: "")
        menu.addItem(ClosureMenuItem(title: "Use Theirs for All Conflicts") { [weak self] in self?.resolveAll(mine: false) })
        menu.addItem(ClosureMenuItem(title: "Use Mine for All Conflicts") { [weak self] in self?.resolveAll(mine: true) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Restart from Git's Merge Result") { [weak self] in self?.restartMerge() })
        menu.addItem(ClosureMenuItem(title: "Go to Line…") { [weak self] in self?.onGoToLine() })
        wholeFile.menu = menu

        showBaseCheckbox = NSButton(checkboxWithTitle: "Base", target: self, action: #selector(onToggleBase))
        showBaseCheckbox.state = ConfigManager.shared.mergeShowBasePane ? .on : .off
        showBaseCheckbox.toolTip = "Show the common ancestor pane"

        let find = button("Find", "Find in the merged text (⌘F)", #selector(onFind), key: "f", modifiers: [.command])
        let goTo = button("Line…", "Go to line (⌘L)", #selector(onGoToLine), key: "l", modifiers: [.command])
        let external = button("External Tool…", "Open the configured external merge tool", #selector(onExternalTool))
        external.isEnabled = ExternalToolLauncher.hasExternalMergeTool || !ConfigManager.shared.mergeToolOverrides.isEmpty

        let stack = NSStackView(views: [previous, counterLabel, next, useTheirs, useMine, theirsFirst, mineFirst, useBaseButton,
                                        wholeFile, showBaseCheckbox, find, goTo, external])
        stack.spacing = 6
        return stack
    }

    // MARK: - Loading

    private func load() {
        Task { @MainActor in
            guard let root else {
                await self.loadFromMarkersOnly()
                return
            }
            let listing = (try? await GitCLIRunner.runAsync(arguments: ["ls-files", "-u", "-z", "--", self.relativePath], workingDirectory: root)) ?? ""
            self.stages = UnmergedEntries.parse(listing)[self.relativePath] ?? [:]
            await self.loadTitles(root: root)

            guard !self.stages.isEmpty else {
                await self.loadFromMarkersOnly()
                return
            }
            let kind = UnmergedEntries.kind(of: self.stages)
            guard kind == .content else {
                self.showSpecialConflict(kind)
                return
            }
            // Stage 2 is git's "ours"; during a rebase that is the branch being rebased onto.
            let swap = self.titles.swapsStages
            async let baseData = self.stageData(1)
            async let oursData = self.stageData(2)
            async let theirsData = self.stageData(3)
            let (base, ours, theirs) = await (baseData, oursData, theirsData)
            let decoded = [base, ours, theirs].map { $0.flatMap(TextFileEncoding.decode) }
            if [ours, theirs].contains(where: { $0 != nil && TextFileEncoding.decode($0!) == nil }) {
                self.showSpecialConflict(nil)
                return
            }
            self.baseText = decoded[0]?.text ?? ""
            self.mineText = (swap ? decoded[2] : decoded[1])?.text ?? ""
            self.theirsText = (swap ? decoded[1] : decoded[2])?.text ?? ""

            let working = (try? Data(contentsOf: self.targetFile.url)).flatMap(TextFileEncoding.decode)
            self.fileFormat = working ?? decoded[1] ?? decoded[2]
            if let working, !working.text.isEmpty {
                // Start from what git (and possibly the user) left in the working file; git writes stage 2 first.
                self.oursSectionIsMine = !swap
                self.setMergedText(working.text, resetUndo: true)
            } else {
                await self.restartMergeAsync()
            }
            self.refreshSidePanes()
            self.goToConflict(0)
            if self.startExternalToolAfterLoad {
                self.startExternalToolAfterLoad = false
                self.onExternalTool()
            }
        }
    }

    /// No index stages: either a file whose conflict was already staged/resolved, or one with markers
    /// pasted in. Only claim "clean" when there really is nothing to resolve (QF-28).
    private func loadFromMarkersOnly() async {
        guard let data = try? Data(contentsOf: targetFile.url) else {
            showNotConflicted("The file could not be read.")
            return
        }
        guard let decoded = TextFileEncoding.decode(data) else {
            showNotConflicted("This is a binary file and has no unresolved conflict.")
            return
        }
        fileFormat = decoded
        let blocks = ConflictMarkers.blocks(in: decoded.text)
        guard !blocks.isEmpty else {
            showNotConflicted("“\(relativePath)” is not in a conflicted state and contains no conflict markers.")
            return
        }
        let sides = ConflictMarkers.sides(of: decoded.text)
        let swap = titles.swapsStages
        baseText = sides.base
        mineText = swap ? sides.theirs : sides.ours
        theirsText = swap ? sides.ours : sides.theirs
        oursSectionIsMine = !swap
        setMergedText(decoded.text, resetUndo: true)
        refreshSidePanes()
        goToConflict(0)
    }

    private func showNotConflicted(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        mergedTextView.string = ""
        mergedTextView.isEditable = false
        for control in blockButtons + [markResolvedButton!, saveButton!] { control.isEnabled = false }
        counterLabel.stringValue = "—"
    }

    private func stageData(_ stage: Int) async -> Data? {
        guard let root, stages[stage] != nil else { return nil }
        return try? await GitCLIRunner.runDataAsync(arguments: ["show", ":\(stage):\(relativePath)"], workingDirectory: root)
    }

    /// Friendly side names from the admin directory (`CAppUtils::GetConflictTitles`).
    private func loadTitles(root: PangolinPath) async {
        guard let gitDirRaw = try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "--absolute-git-dir"], workingDirectory: root) else { return }
        let gitDir = URL(fileURLWithPath: gitDirRaw.trimmingCharacters(in: .whitespacesAndNewlines))
        let operation = ConflictSideTitles.operation(gitDirectory: gitDir)
        func run(_ args: [String]) async -> String? {
            let output = try? await GitCLIRunner.runAsync(arguments: args, workingDirectory: root)
            let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let branch = await run(["symbolic-ref", "--short", "-q", "HEAD"])
        var incoming: String?
        let headFile: String?
        switch operation {
        case .merge: headFile = "MERGE_HEAD"
        case .cherryPick: headFile = "CHERRY_PICK_HEAD"
        case .revert: headFile = "REVERT_HEAD"
        case .rebase, .other: headFile = nil
        }
        if let headFile, let hash = await run(["rev-parse", "--short", headFile]) {
            let name = operation == .merge ? await run(["name-rev", "--name-only", "--no-undefined", headFile]) : nil
            incoming = name.map { "\($0), \(hash)" } ?? hash
        }
        var onto: String?
        if operation == .rebase {
            for file in ["rebase-merge/onto", "rebase-apply/onto"] {
                if let hash = try? String(contentsOf: gitDir.appendingPathComponent(file), encoding: .utf8) {
                    let trimmed = hash.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = await run(["name-rev", "--name-only", "--no-undefined", trimmed])
                    onto = name.map { "\($0), \(String(trimmed.prefix(8)))" } ?? String(trimmed.prefix(8))
                    break
                }
            }
        }
        titles = ConflictSideTitles.make(operation: operation, currentBranch: branch, incoming: incoming,
                                         rebasedBranch: ConflictSideTitles.rebasedBranch(gitDirectory: gitDir), onto: onto)
        theirsPane.title = titles.theirs
        minePane.title = titles.mine
        basePane.title = "Base (common ancestor)"
        mergedHeader.stringValue = "Merged — \(relativePath) (editable)"
    }

    /// Recomputes the merged text from the stages: `git merge-file --diff3` (git's own conflict
    /// hunks, MG-07) or PangolinGit's engine when that is turned off in Settings.
    private func restartMerge() {
        if isDirty || mergedTextView.undoManager?.canUndo == true {
            let alert = NSAlert()
            alert.messageText = "Restart the merge?"
            alert.informativeText = "Your resolutions and edits in the merged text are replaced by a fresh merge of Mine and Theirs."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { @MainActor in await self.restartMergeAsync() }
    }

    private func restartMergeAsync() async {
        var merged: String?
        if ConfigManager.shared.mergeUseGitResult, let root {
            merged = await gitMergeFile(root: root)
        }
        if merged == nil {
            merged = MergeEngine().merge3Way(base: baseText, ours: mineText, theirs: theirsText).mergedText
        }
        oursSectionIsMine = true
        setMergedText(merged ?? "", resetUndo: false)
        goToConflict(0)
    }

    private func gitMergeFile(root: PangolinPath) async -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinGit-Merge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let format = fileFormat
            func write(_ text: String, _ name: String) throws -> String {
                let url = folder.appendingPathComponent(name)
                try (format?.encode(text) ?? Data(text.utf8)).write(to: url)
                return url.path
            }
            let mine = try write(mineText, "mine")
            let base = try write(baseText, "base")
            let theirs = try write(theirsText, "theirs")
            let args = ["merge-file", "-p", "--diff3", "-L", titles.mine, "-L", "base", "-L", titles.theirs, mine, base, theirs]
            let result = try await GitCLIRunner().run(arguments: args, workingDirectory: root)
            // The exit status is the number of conflicts; only a negative value (>127 here) is an error.
            guard result.exitCode >= 0, result.exitCode < 128 else { return nil }
            let data = result.standardOutputData
            if let format, let text = String(data: data, encoding: format.encoding) { return text }
            return TextFileEncoding.decode(data)?.text
        } catch {
            return nil
        }
    }

    // MARK: - Special conflicts (MG-06)

    /// Delete/modify, binary, symlink and submodule conflicts: TortoiseGit's *Delete conflict* and
    /// *Submodule conflict* dialogs offer keeping one side instead of a text merge.
    private func showSpecialConflict(_ kind: ConflictKind?) {
        mergedTextView.isEditable = false
        for control in blockButtons + [saveButton!, markResolvedButton!] { control.isEnabled = false }
        let swap = titles.swapsStages
        let mineStage = swap ? 3 : 2
        let theirsStage = swap ? 2 : 3
        func describe(_ stage: Int) -> String {
            guard let entry = stages[stage] else { return "deleted" }
            if entry.mode == "160000" { return "submodule at \(entry.object.prefix(10))" }
            if entry.mode == "120000" { return "symbolic link" }
            return "modified (\(entry.object.prefix(10)))"
        }
        let what: String
        switch kind {
        case .deleted?: what = "One side deleted the file while the other changed it."
        case .submodule?: what = "Both sides moved the submodule to different commits."
        case .symlink?: what = "A symbolic link conflicts."
        default: what = "The file is binary, so it cannot be merged line by line."
        }
        statusLabel.stringValue = what
        let alert = NSAlert()
        alert.messageText = "Resolve “\(relativePath)”"
        alert.informativeText = "\(what)\n\n\(titles.mine): \(describe(mineStage))\n\(titles.theirs): \(describe(theirsStage))"
        alert.addButton(withTitle: "Use Mine")
        alert.addButton(withTitle: "Use Theirs")
        alert.addButton(withTitle: "Cancel")
        if DiffWindowController.isImage(targetFile), stages[2] != nil, stages[3] != nil {
            alert.addButton(withTitle: "Compare Images")
        }
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.keepStage(mineStage)
            case .alertSecondButtonReturn: self.keepStage(theirsStage)
            case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
                self.compareImages(mine: mineStage, theirs: theirsStage)
            default: break
            }
        }
    }

    /// Resolves by taking one stage as-is; a missing stage means the file is deleted.
    private func keepStage(_ stage: Int) {
        guard let root else { return }
        let path = relativePath
        var commands: [[String]]
        if let entry = stages[stage] {
            if entry.mode == "160000" {
                commands = [["update-index", "--cacheinfo", "160000,\(entry.object),\(path)"]]
            } else {
                commands = [["checkout", stage == 2 ? "--ours" : "--theirs", "--", path], ["add", "--", path]]
            }
        } else {
            commands = [["rm", "-f", "--", path]]
        }
        let operation = titles.operation
        ProgressWindowController.run(title: "Resolve Conflict", commands: commands, workingDirectory: root, repository: root,
                                     onFinish: { [weak self] outcome in
            guard outcome.succeeded else { return }
            self?.close()
            MergeWindowController.afterResolve(root: root, operation: operation)
        })
    }

    private func compareImages(mine: Int, theirs: Int) {
        guard let root else { return }
        let path = relativePath
        Task { @MainActor in
            let mineURL = await DiffWindowController.extract(path, at: ":\(mine)", root: root)
            let theirsURL = await DiffWindowController.extract(path, at: ":\(theirs)", root: root)
            WindowRegistry.shared.present({ ImageDiffWindowController(oldImageURL: theirsURL, newImageURL: mineURL) }, repository: root)
            self.showSpecialConflict(.content)
        }
    }

    // MARK: - Merged text and conflict blocks

    private func setMergedText(_ text: String, resetUndo: Bool) {
        let range = NSRange(location: 0, length: (mergedTextView.string as NSString).length)
        if resetUndo {
            mergedTextView.string = text
            mergedTextView.undoManager?.removeAllActions()
        } else if mergedTextView.shouldChangeText(in: range, replacementString: text) {
            mergedTextView.textStorage?.replaceCharacters(in: range, with: text)
            mergedTextView.didChangeText()
            mergedTextView.undoManager?.setActionName("Restart Merge")
        }
        mergedTextView.font = SideBySideDiffView.diffFont
        isDirty = !resetUndo
        updateState()
    }

    private var blocks: [ConflictBlock] {
        ConflictMarkers.blocks(in: mergedTextView.string)
    }

    /// UTF-16 offset of each line start, splitting on LF only like `ConflictMarkers` (a CR stays in its line).
    private static func lineStarts(of string: String) -> [Int] {
        var starts = [0]
        for (offset, unit) in string.utf16.enumerated() where unit == 0x0A {
            starts.append(offset + 1)
        }
        return starts
    }

    /// Character range of whole lines `lines` in the merged text, including the final line break.
    private func characterRange(ofLines lines: Range<Int>, starts: [Int]? = nil) -> NSRange {
        let starts = starts ?? Self.lineStarts(of: mergedTextView.string)
        let length = (mergedTextView.string as NSString).length
        let start = lines.lowerBound < starts.count ? starts[lines.lowerBound] : length
        let end = lines.upperBound < starts.count ? starts[lines.upperBound] : length
        return NSRange(location: start, length: max(0, end - start))
    }

    private func choice(mine: Bool) -> ConflictChoice {
        mine == oursSectionIsMine ? .ours : .theirs
    }

    private func resolveCurrent(_ choice: ConflictChoice, actionName: String) {
        let all = blocks
        guard all.indices.contains(currentConflict) else { NSSound.beep(); return }
        let block = all[currentConflict]
        let range = characterRange(ofLines: block.lineRange)
        let lines = ConflictMarkers.lines(for: block, choice: choice)
        let original = (mergedTextView.string as NSString).substring(with: range)
        var replacement = lines.map { $0 + "\n" }.joined()
        if !original.hasSuffix("\n"), replacement.hasSuffix("\n") { replacement.removeLast() }
        guard mergedTextView.shouldChangeText(in: range, replacementString: replacement) else { return }
        mergedTextView.textStorage?.replaceCharacters(in: range, with: replacement)
        mergedTextView.didChangeText()
        mergedTextView.undoManager?.setActionName(actionName)
        isDirty = true
        // The resolved block is gone; the next unresolved one now has the same index.
        goToConflict(min(currentConflict, max(0, blocks.count - 1)))
    }

    private func resolveAll(mine: Bool) {
        let resolved = ConflictMarkers.resolveAll(mergedTextView.string, choice: choice(mine: mine))
        setMergedText(resolved, resetUndo: false)
        mergedTextView.undoManager?.setActionName(mine ? "Use Mine for All" : "Use Theirs for All")
    }

    @objc private func onUseMine() { resolveCurrent(choice(mine: true), actionName: "Use Mine Block") }
    @objc private func onUseTheirs() { resolveCurrent(choice(mine: false), actionName: "Use Theirs Block") }
    @objc private func onUseBase() { resolveCurrent(.base, actionName: "Use Base Block") }
    @objc private func onMineThenTheirs() {
        resolveCurrent(oursSectionIsMine ? .oursThenTheirs : .theirsThenOurs, actionName: "Use Mine Then Theirs")
    }
    @objc private func onTheirsThenMine() {
        resolveCurrent(oursSectionIsMine ? .theirsThenOurs : .oursThenTheirs, actionName: "Use Theirs Then Mine")
    }

    @objc private func onNextConflict() {
        let count = blocks.count
        guard count > 0 else { NSSound.beep(); return }
        goToConflict(currentConflict + 1 < count ? currentConflict + 1 : 0)
    }

    @objc private func onPreviousConflict() {
        let count = blocks.count
        guard count > 0 else { NSSound.beep(); return }
        goToConflict(currentConflict > 0 ? currentConflict - 1 : count - 1)
    }

    private func goToConflict(_ index: Int) {
        let all = blocks
        currentConflict = all.isEmpty ? 0 : min(max(0, index), all.count - 1)
        if all.indices.contains(currentConflict) {
            let range = characterRange(ofLines: all[currentConflict].lineRange)
            mergedTextView.scrollRangeToVisible(range)
            mergedTextView.setSelectedRange(NSRange(location: range.location, length: 0))
        }
        updateState()
        refreshSidePanes()
    }

    // MARK: - Highlighting and status

    public func textDidChange(_ notification: Notification) {
        isDirty = true
        // Re-scan after typing pauses; the merged text may be large.
        highlightWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentConflict = min(self.currentConflict, max(0, self.blocks.count - 1))
                self.updateState()
            }
        }
        highlightWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func updateState() {
        let all = blocks
        highlightMerged(all)
        let hasBlocks = !all.isEmpty
        for button in blockButtons { button.isEnabled = hasBlocks && mergedTextView.isEditable }
        useBaseButton.isEnabled = hasBlocks && all.indices.contains(currentConflict) && all[currentConflict].base != nil
        counterLabel.stringValue = hasBlocks ? "Conflict \(currentConflict + 1) of \(all.count)" : "No conflicts"

        let (mineStats, theirsStats) = changesAgainstBase()
        if hasBlocks {
            statusLabel.stringValue = "⚠️ \(all.count) unresolved conflict\(all.count == 1 ? "" : "s")"
            statusLabel.textColor = .systemOrange
        } else if mergedTextView.isEditable {
            statusLabel.stringValue = "✓ No conflict markers left — review the result, then Mark as Resolved."
            statusLabel.textColor = .systemGreen
        }
        var format = "Mine: +\(mineStats.added) −\(mineStats.removed) · Theirs: +\(theirsStats.added) −\(theirsStats.removed) vs. base"
        if let fileFormat { format += " · \(fileFormat.encodingName) · \(fileFormat.lineEnding.rawValue)" }
        formatLabel.stringValue = format
        window?.isDocumentEdited = isDirty
    }

    private func changesAgainstBase() -> (mine: (changed: Set<Int>, added: Int, removed: Int), theirs: (changed: Set<Int>, added: Int, removed: Int)) {
        if let sideChanges { return sideChanges }
        let base = lines(baseText)
        let result = (mine: ConflictMarkers.lineChanges(base: base, side: lines(mineText)),
                      theirs: ConflictMarkers.lineChanges(base: base, side: lines(theirsText)))
        sideChanges = result
        return result
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Conflict regions in the merged pane, the current one stronger (temporary attributes keep undo clean).
    private func highlightMerged(_ all: [ConflictBlock]) {
        guard let layoutManager = mergedTextView.layoutManager else { return }
        let full = NSRange(location: 0, length: (mergedTextView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        let starts = Self.lineStarts(of: mergedTextView.string)
        for (index, block) in all.enumerated() {
            let color = NSColor.systemOrange.withAlphaComponent(index == currentConflict ? 0.32 : 0.14)
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color,
                                                forCharacterRange: characterRange(ofLines: block.lineRange, starts: starts))
        }
    }

    /// Fills Theirs / Base / Mine, colouring lines that differ from the base and marking the lines of
    /// the current conflict in each pane.
    private func refreshSidePanes() {
        let baseLines = lines(baseText)
        let mineLines = lines(mineText)
        let theirsLines = lines(theirsText)
        let all = blocks
        var current: ConflictBlock? = all.indices.contains(currentConflict) ? all[currentConflict] : nil
        if current != nil, !oursSectionIsMine, let block = current {
            current = ConflictBlock(lineRange: block.lineRange, ours: block.theirs, base: block.base, theirs: block.ours,
                                    oursLabel: block.theirsLabel, theirsLabel: block.oursLabel)
        }
        let hint = current?.lineRange.lowerBound ?? 0
        func clean(_ lines: [String]) -> [String] { lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 } }

        let changes = changesAgainstBase()
        minePane.show(lines: mineLines, changed: changes.mine.changed,
                      highlight: current.flatMap { ConflictMarkers.locate(clean($0.ours), in: mineLines, near: hint) })
        theirsPane.show(lines: theirsLines, changed: changes.theirs.changed,
                        highlight: current.flatMap { ConflictMarkers.locate(clean($0.theirs), in: theirsLines, near: hint) })
        basePane.show(lines: baseLines, changed: [],
                      highlight: current.flatMap { $0.base }.flatMap { ConflictMarkers.locate(clean($0), in: baseLines, near: hint) })
    }

    // MARK: - Toolbar actions

    @objc private func onToggleBase() {
        let show = showBaseCheckbox.state == .on
        basePane.isHidden = !show
        ConfigManager.shared.mergeShowBasePane = show
        topSplit.adjustSubviews()
    }

    @objc private func onFind() {
        window?.makeFirstResponder(mergedTextView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        mergedTextView.performTextFinderAction(item)
    }

    @objc private func onGoToLine() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Line in the merged text:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, let line = Int(field.stringValue), line > 0 else { return }
            let range = self.characterRange(ofLines: (line - 1)..<line)
            self.window?.makeFirstResponder(self.mergedTextView)
            self.mergedTextView.setSelectedRange(range)
            self.mergedTextView.scrollRangeToVisible(range)
        }
    }

    /// Hands the conflict to the external merge tool with `file.BASE.ext` / `.LOCAL` / `.REMOTE`
    /// helper files (TortoiseGit's `GetMergeTempFile`), honouring *Block while running* / *Trust exit code*.
    @objc private func onExternalTool() {
        guard let root, let command = ExternalToolLauncher.mergeCommand(for: targetFile.filename, alternative: !ConfigManager.shared.useExternalMergeTool)
                ?? ExternalToolLauncher.mergeCommand(for: targetFile.filename, alternative: false) else {
            NSSound.beep()
            return
        }
        if isDirty, !save() { return }
        let directory = targetFile.url.deletingLastPathComponent()
        let ext = targetFile.url.pathExtension.isEmpty ? "" : ".\(targetFile.url.pathExtension)"
        func helper(_ tag: String, _ text: String) -> String {
            let url = directory.appendingPathComponent("\(targetFile.filename).\(tag)\(ext)")
            try? (fileFormat?.encode(text) ?? Data(text.utf8)).write(to: url)
            helperFiles.append(url)
            return url.path
        }
        let files = ExternalToolCommand.Files(
            base: helper("BASE", baseText), mine: helper("LOCAL", mineText), theirs: helper("REMOTE", theirsText),
            merged: targetFile.rawPath, baseName: "Base", mineName: titles.mine, theirsName: titles.theirs,
            mergedName: "Merged: \(relativePath)", workingTreeRoot: root.rawPath)
        let trust = ConfigManager.shared.mergeToolBlockTrust
        ExternalToolLauncher.launchMerge(commandLine: command, files: files, wait: trust != .dontWait) { [weak self] status in
            guard let self, let status else { return }
            self.reloadWorkingFile()
            if trust == .waitAndTrustExitCode {
                if status == 0 { self.markResolved(skipMarkerCheck: false) }
                return
            }
            let alert = NSAlert()
            alert.messageText = "Mark “\(self.relativePath)” as resolved?"
            alert.informativeText = "The external merge tool finished (exit status \(status))."
            alert.addButton(withTitle: "Mark as Resolved")
            alert.addButton(withTitle: "Not Yet")
            if alert.runModal() == .alertFirstButtonReturn { self.markResolved(skipMarkerCheck: false) }
        }
        statusLabel.stringValue = trust == .dontWait ? "Opened in the external merge tool. Mark as Resolved here when done." : "Waiting for the external merge tool…"
    }

    private func reloadWorkingFile() {
        guard let data = try? Data(contentsOf: targetFile.url), let decoded = TextFileEncoding.decode(data) else { return }
        oursSectionIsMine = !titles.swapsStages
        setMergedText(decoded.text, resetUndo: true)
    }

    // MARK: - Save / resolve

    /// Writes the merged text with the file's original encoding, BOM and line endings.
    @discardableResult
    private func save() -> Bool {
        let text = mergedTextView.string
        var data = fileFormat?.encode(text)
        if data == nil {
            let alert = NSAlert()
            alert.messageText = "Save as UTF-8?"
            alert.informativeText = "The merged text contains characters that \(fileFormat?.encodingName ?? "the original encoding") cannot represent."
            alert.addButton(withTitle: "Save as UTF-8")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            data = Data(text.utf8)
        }
        do {
            if ConfigManager.shared.mergeBackupOriginal, FileManager.default.fileExists(atPath: targetFile.rawPath) {
                let backup = URL(fileURLWithPath: targetFile.rawPath + ".orig")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: targetFile.url, to: backup)
            }
            try data!.write(to: targetFile.url)
            isDirty = false
            window?.isDocumentEdited = false
            if let root { RepositoryEvents.post(root) }
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @objc private func onSave() {
        save()
    }

    @objc private func onMarkResolved() {
        markResolved(skipMarkerCheck: false)
    }

    private func markResolved(skipMarkerCheck: Bool) {
        if !skipMarkerCheck, !blocks.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Conflict Markers Remain"
            alert.informativeText = "The merged text still contains \(blocks.count) conflict block(s). You can save the file, but it is not marked as resolved."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Keep Resolving")
            alert.addButton(withTitle: "Save Without Resolving")
            if alert.runModal() == .alertSecondButtonReturn { save() }
            return
        }
        guard save() else { return }
        removeHelperFiles()
        guard let root else {
            close()
            return
        }
        let path = relativePath
        let operation = titles.operation
        Task { @MainActor in
            do {
                try await GitCLIRunner.runAsync(arguments: ["add", "--", path], workingDirectory: root)
                self.close()
                MergeWindowController.afterResolve(root: root, operation: operation)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could Not Mark Resolved"
                alert.informativeText = "The file was saved, but staging it failed:\n\(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// After the last conflict is resolved, offer the next step (TortoiseGit's post-resolve
    /// *Commit…* / continue-rebase hand-off); otherwise offer the next conflicted file.
    @MainActor
    static func afterResolve(root: PangolinPath, operation: ConflictOperation) {
        Task { @MainActor in
            let remaining = ((try? await GitCLIRunner.runAsync(arguments: ["diff", "--name-only", "--diff-filter=U", "-z"], workingDirectory: root)) ?? "")
                .split(separator: "\0").map(String.init)
            let alert = NSAlert()
            if let next = remaining.first {
                alert.messageText = "\(remaining.count) conflicted file(s) remain"
                alert.informativeText = "Next: \(next)"
                alert.addButton(withTitle: "Edit Next Conflict")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    present(file: PangolinPath(root.appending(next).rawPath), repository: root)
                }
                return
            }
            let continueCommand: (title: String, args: [String])?
            switch operation {
            case .rebase: continueCommand = ("Continue Rebase", ["rebase", "--continue"])
            case .cherryPick: continueCommand = ("Continue Cherry-pick", ["cherry-pick", "--continue"])
            case .revert: continueCommand = ("Continue Revert", ["revert", "--continue"])
            case .merge, .other: continueCommand = nil
            }
            alert.messageText = "All conflicts are resolved"
            alert.informativeText = continueCommand == nil ? "Commit the result to finish the merge." : "Continue the operation, or commit by hand."
            alert.addButton(withTitle: continueCommand?.title ?? "Commit…")
            alert.addButton(withTitle: "Later")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let continueCommand {
                // Keep git from opening an editor for the commit message.
                ProgressWindowController.run(title: continueCommand.title, commands: [continueCommand.args], workingDirectory: root,
                                             repository: root, environment: ["GIT_EDITOR": "true"])
            } else {
                WindowRegistry.shared.present({ CommitWindowController(repositoryPath: root) }, key: "commit|\(root.rawPath)", repository: root)
            }
        }
    }

    private func removeHelperFiles() {
        for url in helperFiles { try? FileManager.default.removeItem(at: url) }
        helperFiles.removeAll()
    }

    @objc private func onCancel() {
        close()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the merged file?"
        alert.informativeText = "Your changes to “\(relativePath)” have not been saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return false
        default: return true
        }
    }

    public func windowWillClose(_ notification: Notification) {
        removeHelperFiles()
    }
}

/// One read-only side of the merge editor: title, line-number gutter, lines that differ from the
/// base tinted, and the current conflict's lines highlighted.
private final class MergePane: NSView {
    private let header = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView: DiffTextView
    private let layoutManager = DiffLayoutManager()
    private var scrollObserver: NSObjectProtocol?

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    var title: String {
        get { header.stringValue }
        set { header.stringValue = newValue }
    }

    init(title: String) {
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        textView = DiffTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        header.stringValue = title
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        header.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 2, height: 2)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                                queue: .main) { [weak ruler] _ in
            ruler?.needsDisplay = true
        }
        scrollView.contentView.postsBoundsChangedNotifications = true

        addSubview(header)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(lines: [String], changed: Set<Int>, highlight: Range<Int>?) {
        let font = SideBySideDiffView.diffFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor,
                                                         .paragraphStyle: SideBySideDiffView.paragraphStyle]
        var starts: [Int] = []
        var backgrounds: [NSColor?] = []
        var offset = 0
        let text = NSMutableString()
        for (index, line) in lines.enumerated() {
            starts.append(offset)
            text.append(line)
            text.append("\n")
            offset += (line as NSString).length + 1
            if let highlight, highlight.contains(index) {
                backgrounds.append(NSColor.systemOrange.withAlphaComponent(0.30))
            } else if changed.contains(index) {
                backgrounds.append(DiffColors.modified.withAlphaComponent(0.12))
            } else {
                backgrounds.append(nil)
            }
        }
        layoutManager.paragraphStarts = starts
        layoutManager.rowBackgrounds = backgrounds
        if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
            ruler.numbers = lines.indices.map { $0 + 1 }
            ruler.changeMarkers = lines.indices.map { changed.contains($0) ? .modified : nil }
            ruler.updateThickness(maxNumber: lines.count)
        }
        textView.textStorage?.setAttributedString(NSAttributedString(string: text as String, attributes: attributes))
        if let highlight, highlight.lowerBound < starts.count {
            let location = starts[highlight.lowerBound]
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        }
        scrollView.verticalRulerView?.needsDisplay = true
    }
}
