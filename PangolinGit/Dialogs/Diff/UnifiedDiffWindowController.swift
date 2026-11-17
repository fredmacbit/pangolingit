import Cocoa
import UniformTypeIdentifiers
import PangolinGitCore

/// Unified-diff viewer and patch reviewer: TortoiseGitUDiff (coloured text, find, open, save, print)
/// combined with TortoiseGitMerge's patch mode (`FilePatchesDlg.cpp`): a list of the files the patch
/// touches, red when a file does not apply cleanly, a side-by-side preview per file and applying the
/// selected or all files.
final class UnifiedDiffWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private var text: String
    private var sourceURL: URL?
    private let repository: PangolinPath?
    private var files: [GitPatchFile] = []
    /// nil = not checked yet; true = applies cleanly.
    private var applies: [Int: Bool] = [:]

    private let textView = NSTextView()
    private let fileTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let reverseCheckbox = NSButton(checkboxWithTitle: "Reversed", target: nil, action: nil)
    private let addNewFilesCheckbox = NSButton(checkboxWithTitle: "Add new files to Git", target: nil, action: nil)
    private var applyButtons: [NSButton] = []

    /// Opens a diff text, in the external viewer from Settings ▸ Tools when one is configured.
    @MainActor
    static func present(text: String, title: String, repository: PangolinPath?) {
        let viewer = ConfigManager.shared.unifiedDiffViewer
        if !viewer.isEmpty {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinGit-\(UUID().uuidString.prefix(8)).diff")
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
                ExternalToolLauncher.launch([viewer, url.path], wait: false, workingDirectory: repository?.rawPath ?? "") { _ in }
                return
            }
        }
        WindowRegistry.shared.present({ UnifiedDiffWindowController(text: text, title: title, repository: repository) }, repository: repository)
    }

    /// TortoiseGit's *Review/apply single patch…*: opens a `.patch` / `.diff` file for review.
    @MainActor
    static func openPatchFile(_ url: URL, repository: PangolinPath?) {
        let content = (try? Data(contentsOf: url)).flatMap { TextFileEncoding.decode($0)?.text } ?? ""
        WindowRegistry.shared.present({ UnifiedDiffWindowController(text: content, title: url.lastPathComponent, repository: repository, sourceURL: url) },
                                      key: "udiff|\(url.path)", repository: repository)
    }

    init(text: String, title: String, repository: PangolinPath?, sourceURL: URL? = nil) {
        self.text = text
        self.repository = repository
        self.sourceURL = sourceURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Unified Diff — \(title)"
        window.minSize = NSSize(width: 640, height: 400)
        super.init(window: window)
        setupUI()
        reloadText()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        func button(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .texturedRounded
            if !key.isEmpty {
                button.keyEquivalent = key
                button.keyEquivalentModifierMask = modifiers
            }
            return button
        }
        let open = button("Open…", #selector(onOpen), key: "o")
        let paste = button("From Clipboard", #selector(onPaste))
        let save = button("Save As…", #selector(onSave), key: "s")
        let print = button("Print…", #selector(onPrint), key: "p")
        let find = button("Find", #selector(onFind), key: "f")
        let toolbar = NSStackView(views: [open, paste, save, print, find])
        toolbar.spacing = 6
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(toolbar)

        // File list (patch review).
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "Files in Patch"
        fileTable.addTableColumn(column)
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.allowsMultipleSelection = true
        fileTable.target = self
        fileTable.doubleAction = #selector(onPreview)
        let fileScroll = NSScrollView()
        fileScroll.documentView = fileTable
        fileScroll.hasVerticalScroller = true
        fileScroll.borderType = .bezelBorder

        let preview = button("Preview", #selector(onPreview))
        let applySelected = button("Apply Selected", #selector(onApplySelected))
        let applyAll = button("Apply All", #selector(onApplyAll))
        applyButtons = [applySelected, applyAll]
        reverseCheckbox.target = self
        reverseCheckbox.action = #selector(onReverseChanged)
        let fileButtons = NSStackView(views: [preview, applySelected, applyAll])
        fileButtons.spacing = 6
        let options = NSStackView(views: [reverseCheckbox, addNewFilesCheckbox])
        options.spacing = 10

        let sidebar = NSStackView(views: [fileScroll, fileButtons, options])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 6
        fileScroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true

        // Text pane.
        let textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.hasHorizontalScroller = true
        textScroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.autoresizingMask = [.width]
        textScroll.documentView = textView

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(textScroll)
        split.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(split)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            split.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        split.setPosition(260, ofDividerAt: 0)
    }

    private func reloadText() {
        textView.textStorage?.setAttributedString(UnifiedDiffFormatter.attributedString(for: text))
        files = GitPatch.parse(unifiedDiff: text)
        applies = [:]
        fileTable.reloadData()
        let canApply = repository != nil && !files.isEmpty
        applyButtons.forEach { $0.isEnabled = canApply }
        statusLabel.stringValue = "\(files.count) file(s), \(files.reduce(0) { $0 + $1.hunks.count }) hunk(s)"
            + (repository == nil ? " — open from inside a repository to apply" : "")
        checkApplicability()
    }

    private func path(of file: GitPatchFile) -> String {
        file.newPath ?? file.oldPath ?? "?"
    }

    // MARK: - Applying (git apply)

    /// Writes the patch to a temporary file for `git apply`.
    private func patchFileURL() -> URL? {
        if let sourceURL, (try? String(contentsOf: sourceURL, encoding: .utf8)) == text { return sourceURL }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinGit-\(UUID().uuidString.prefix(8)).patch")
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    private func applyArguments(check: Bool, include: [String]) -> [String]? {
        guard let url = patchFileURL() else { return nil }
        var args = ["apply"]
        if check { args.append("--check") }
        if reverseCheckbox.state == .on { args.append("-R") }
        args += include.map { "--include=\(Self.escapeGlob($0))" }
        args.append(url.path)
        return args
    }

    /// `--include` takes a glob; escape glob characters in literal paths.
    private static func escapeGlob(_ path: String) -> String {
        path.reduce(into: "") { result, character in
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    /// Marks each file black (applies) or red (does not), like TortoiseMerge's file list.
    private func checkApplicability() {
        guard let repository, !files.isEmpty else { return }
        let paths = files.map(path(of:))
        Task { @MainActor in
            for (index, path) in paths.enumerated() {
                guard let args = self.applyArguments(check: true, include: [path]) else { return }
                let result = try? await GitCLIRunner().run(arguments: args, workingDirectory: repository)
                self.applies[index] = result?.isSuccess ?? false
            }
            self.fileTable.reloadData()
        }
    }

    private func apply(paths: [String]) {
        guard let repository, let args = applyArguments(check: false, include: paths) else { return }
        let newFiles = files.filter { $0.oldPath == nil && $0.newPath != nil }.compactMap(\.newPath)
            .filter { paths.isEmpty || paths.contains($0) }
        var commands = [args]
        if addNewFilesCheckbox.state == .on, reverseCheckbox.state == .off, !newFiles.isEmpty {
            commands.append(["add", "--"] + newFiles)
        }
        ProgressWindowController.run(title: "Apply Patch", commands: commands, workingDirectory: repository, repository: repository,
                                     onFinish: { [weak self] _ in self?.checkApplicability() })
    }

    @objc private func onApplySelected() {
        let paths = fileTable.selectedRowIndexes.map { path(of: files[$0]) }
        guard !paths.isEmpty else { NSSound.beep(); return }
        apply(paths: paths)
    }

    @objc private func onApplyAll() {
        apply(paths: [])
    }

    @objc private func onReverseChanged() {
        checkApplicability()
    }

    /// Side-by-side view of the selected file's hunks.
    @objc private func onPreview() {
        let row = fileTable.clickedRow >= 0 ? fileTable.clickedRow : fileTable.selectedRow
        guard row >= 0, row < files.count else { return }
        let file = files[row]
        var section = ""
        for hunk in file.hunks {
            section += hunk.header + "\n" + hunk.lines.joined(separator: "\n") + "\n"
        }
        let title = path(of: file)
        WindowRegistry.shared.present({ PatchPreviewWindowController(title: title, diff: section) }, key: "patchpreview|\(title)|\(section.hashValue)")
    }

    // MARK: - Toolbar

    @objc private func onOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "patch"), UTType(filenameExtension: "diff"), .plainText].compactMap { $0 }
        guard let window, panel.runModal() == .OK, let url = panel.url else { return }
        text = (try? Data(contentsOf: url)).flatMap { TextFileEncoding.decode($0)?.text } ?? ""
        sourceURL = url
        window.title = "Unified Diff — \(url.lastPathComponent)"
        reloadText()
    }

    @objc private func onPaste() {
        guard let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty else { NSSound.beep(); return }
        text = pasted
        sourceURL = nil
        window?.title = "Unified Diff — clipboard"
        reloadText()
    }

    @objc private func onSave() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL?.lastPathComponent ?? "changes.patch"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func onPrint() {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        NSPrintOperation(view: textView, printInfo: info).run()
    }

    @objc private func onFind() {
        window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("PatchFileCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }()
        let file = files[row]
        var name = path(of: file)
        if file.oldPath == nil { name += " (new)" } else if file.newPath == nil { name += " (deleted)" }
        cell.stringValue = name
        cell.textColor = applies[row] == false ? .systemRed : .labelColor
        cell.toolTip = applies[row] == false ? "Does not apply cleanly to the working tree" : nil
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Scroll the text to the first selected file's section.
        let row = fileTable.selectedRow
        guard row >= 0, row < files.count else { return }
        let name = path(of: files[row])
        let string = textView.string as NSString
        for needle in ["+++ b/\(name)", "+++ \(name)", "--- a/\(name)", name] {
            let range = string.range(of: needle)
            if range.location != NSNotFound {
                textView.scrollRangeToVisible(range)
                textView.showFindIndicator(for: range)
                break
            }
        }
    }
}

/// Side-by-side preview of one file's hunks from a patch (TortoiseMerge's patch preview).
final class PatchPreviewWindowController: NSWindowController {
    init(title: String, diff: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Patch Preview — \(title)"
        super.init(window: window)
        let view = SideBySideDiffView()
        view.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(view)
        if let contentView = window.contentView {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
                view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
                view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            ])
        }
        view.setDiff(rawUnifiedText: diff)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
