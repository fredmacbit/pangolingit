import Cocoa
import PangolinGitCore

/// Settings pane for the diff viewer, the merge tool and the alternative editor — TortoiseGit's
/// *Diff Viewer* and *Merge Tool* pages (`SettingsProgsDiff.cpp`, `SettingsProgsMerge.cpp`,
/// `SettingsProgsAlternativeEditor.cpp`, the *Advanced* per-extension dialogs) plus TortoiseGitMerge's
/// own options (`SetMainPage.cpp`).
public final class ExternalToolsSettingsViewController: NSViewController {

    private var diffToolField: NSTextField!
    private var diffArgsField: NSTextField!
    private var useExternalDiff: NSButton!
    private var unifiedViewerField: NSTextField!
    private var diffOverrides: OverrideTable!

    private var mergeToolField: NSTextField!
    private var mergeArgsField: NSTextField!
    private var useExternalMerge: NSButton!
    private var blockTrustPopup: NSPopUpButton!
    private var mergeOverrides: OverrideTable!
    private var showBaseCheckbox: NSButton!
    private var gitResultCheckbox: NSButton!
    private var backupCheckbox: NSButton!

    private var editorField: NSTextField!
    private var inlinePopup: NSPopUpButton!
    private var maxInlineField: NSTextField!
    private var collapseCheckbox: NSButton!
    private var wrapCheckbox: NSButton!

    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 430))
        setupUI()
        loadData()
    }

    private func setupUI() {
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("Diff Viewer", makeDiffPage()))
        tabs.addTabViewItem(tab("Merge Tool", makeMergePage()))
        tabs.addTabViewItem(tab("Viewer & Editor", makeEditorPage()))
        view.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tabs.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    private func tab(_ title: String, _ content: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = title
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8),
        ])
        item.view = container
        return item
    }

    // MARK: - Pages

    private func makeDiffPage() -> NSView {
        useExternalDiff = checkbox("Use the external diff tool instead of the built-in viewer (⌥ inverts)")
        diffToolField = NSTextField()
        diffToolField.placeholderString = "/usr/bin/opendiff, /Applications/Beyond Compare.app, code, ksdiff…"
        diffArgsField = NSTextField()
        unifiedViewerField = NSTextField()
        unifiedViewerField.placeholderString = "Empty: built-in unified diff viewer"
        diffOverrides = OverrideTable(placeholder: ".png")
        let legend = note("Placeholders: %base %mine %bname %yname %brev %yrev %wtroot, or git's $LOCAL $REMOTE. Without any, the two files are appended.")
        return stack([
            useExternalDiff,
            row("Program:", diffToolField, browseButton { [weak self] in self?.diffToolField.stringValue = $0 }),
            row("Arguments:", diffArgsField),
            legend,
            row("Unified diff viewer:", unifiedViewerField, browseButton { [weak self] in self?.unifiedViewerField.stringValue = $0 }),
            label("Per-extension or per-file diff programs (full command line; used even when the built-in viewer is selected):"),
            diffOverrides,
        ])
    }

    private func makeMergePage() -> NSView {
        useExternalMerge = checkbox("Use the external merge tool instead of the built-in conflict editor (⌥ inverts)")
        mergeToolField = NSTextField()
        mergeToolField.placeholderString = "/usr/bin/opendiff, /Applications/P4Merge.app, meld, code…"
        mergeArgsField = NSTextField()
        blockTrustPopup = NSPopUpButton()
        blockTrustPopup.addItems(withTitles: ConfigManager.MergeBlockTrust.allCases.map(\.title))
        mergeOverrides = OverrideTable(placeholder: ".xib")
        showBaseCheckbox = checkbox("Show the Base pane in the conflict editor")
        gitResultCheckbox = checkbox("Start from git's merge result (git merge-file --diff3) when restarting a merge")
        backupCheckbox = checkbox("Keep a backup of the conflicted file (<file>.orig) when saving")
        let legend = note("Placeholders: %base %mine %theirs %merged %bname %yname %tname %mname, or $BASE $LOCAL $REMOTE $MERGED.")
        return stack([
            useExternalMerge,
            row("Program:", mergeToolField, browseButton { [weak self] in self?.mergeToolField.stringValue = $0 }),
            row("Arguments:", mergeArgsField),
            legend,
            row("After launching:", blockTrustPopup),
            label("Per-extension or per-file merge programs:"),
            mergeOverrides,
            showBaseCheckbox, gitResultCheckbox, backupCheckbox,
        ])
    }

    private func makeEditorPage() -> NSView {
        editorField = NSTextField()
        editorField.placeholderString = "Empty: the default application for the file"
        inlinePopup = NSPopUpButton()
        inlinePopup.addItems(withTitles: ["Character-wise", "Word-wise", "Off"])
        maxInlineField = NSTextField()
        maxInlineField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        collapseCheckbox = checkbox("Collapse unchanged sections by default")
        wrapCheckbox = checkbox("Wrap long lines by default")
        return stack([
            row("Alternative editor:", editorField, browseButton { [weak self] in self?.editorField.stringValue = $0 }),
            note("Used by “Open with alternative editor” in file lists."),
            label("Built-in diff viewer"),
            row("Inline differences:", inlinePopup),
            row("Max line length for inline diffs:", maxInlineField),
            collapseCheckbox, wrapCheckbox,
            note("Fonts, tab width and colours are on the Colors page."),
        ])
    }

    // MARK: - Data

    public func loadData() {
        let config = ConfigManager.shared
        diffToolField.stringValue = config.externalDiffTool
        diffArgsField.stringValue = config.externalDiffToolArgs
        useExternalDiff.state = config.useExternalDiffTool ? .on : .off
        unifiedViewerField.stringValue = config.unifiedDiffViewer
        diffOverrides.entries = config.diffToolOverrides.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }

        mergeToolField.stringValue = config.externalMergeTool
        mergeArgsField.stringValue = config.externalMergeToolArgs
        useExternalMerge.state = config.useExternalMergeTool ? .on : .off
        blockTrustPopup.selectItem(at: config.mergeToolBlockTrust.rawValue)
        mergeOverrides.entries = config.mergeToolOverrides.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        showBaseCheckbox.state = config.mergeShowBasePane ? .on : .off
        gitResultCheckbox.state = config.mergeUseGitResult ? .on : .off
        backupCheckbox.state = config.mergeBackupOriginal ? .on : .off

        editorField.stringValue = config.alternativeEditor
        inlinePopup.selectItem(at: [InlineDiffMode.character, .word, .off].firstIndex(of: config.inlineDiffMode) ?? 0)
        maxInlineField.stringValue = "\(config.maxInlineLength)"
        collapseCheckbox.state = config.diffCollapseUnchanged ? .on : .off
        wrapCheckbox.state = config.diffWrapLines ? .on : .off
    }

    public func save() {
        guard isViewLoaded else { return }
        let config = ConfigManager.shared
        func trimmed(_ field: NSTextField) -> String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        config.externalDiffTool = trimmed(diffToolField)
        config.externalDiffToolArgs = trimmed(diffArgsField)
        config.useExternalDiffTool = useExternalDiff.state == .on
        config.unifiedDiffViewer = trimmed(unifiedViewerField)
        config.diffToolOverrides = diffOverrides.dictionary

        config.externalMergeTool = trimmed(mergeToolField)
        config.externalMergeToolArgs = trimmed(mergeArgsField)
        config.useExternalMergeTool = useExternalMerge.state == .on
        config.mergeToolBlockTrust = ConfigManager.MergeBlockTrust(rawValue: blockTrustPopup.indexOfSelectedItem) ?? .dontWait
        config.mergeToolOverrides = mergeOverrides.dictionary
        config.mergeShowBasePane = showBaseCheckbox.state == .on
        config.mergeUseGitResult = gitResultCheckbox.state == .on
        config.mergeBackupOriginal = backupCheckbox.state == .on

        config.alternativeEditor = trimmed(editorField)
        config.inlineDiffMode = [InlineDiffMode.character, .word, .off][max(0, inlinePopup.indexOfSelectedItem)]
        if let length = Int(trimmed(maxInlineField)), length > 0 { config.maxInlineLength = length }
        config.diffCollapseUnchanged = collapseCheckbox.state == .on
        config.diffWrapLines = wrapCheckbox.state == .on
    }

    @objc private func controlChanged() {
        save()
    }

    // MARK: - Layout helpers

    private func checkbox(_ title: String) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: #selector(controlChanged))
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        return field
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 560
        return field
    }

    private func row(_ title: String, _ views: NSView...) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.alignment = .right
        titleLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
        for case let popup as NSPopUpButton in views {
            popup.target = self
            popup.action = #selector(controlChanged)
        }
        let row = NSStackView(views: [titleLabel] + views)
        row.spacing = 8
        return row
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for case let row as NSStackView in views {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for case let table as OverrideTable in views {
            table.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            table.onChange = { [weak self] in self?.save() }
        }
        return stack
    }

    private func browseButton(_ handler: @escaping (String) -> Void) -> NSButton {
        ClosureButton(title: "Browse…") { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            if panel.runModal() == .OK, let url = panel.url {
                handler(url.path)
                self?.save()
            }
        }
    }
}

/// Two-column editable table of extension (or file name) → command line, with add/remove buttons.
private final class OverrideTable: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var entries: [(key: String, command: String)] = [] {
        didSet { tableView.reloadData() }
    }
    var onChange: (() -> Void)?
    private let tableView = NSTableView()
    private let placeholder: String

    var dictionary: [String: String] {
        entries.reduce(into: [String: String]()) { result, entry in
            let key = entry.key.trimmingCharacters(in: .whitespaces)
            let command = entry.command.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !command.isEmpty else { return }
            result[key.hasPrefix(".") ? key : "." + key] = command
        }
    }

    init(placeholder: String) {
        self.placeholder = placeholder
        super.init(frame: .zero)
        for (id, title, width) in [("key", "Extension / file", 110.0), ("command", "Command line", 380.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 20
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let add = ClosureButton(title: "+") { [weak self] in
            guard let self else { return }
            self.entries.append((self.placeholder, ""))
            self.tableView.editColumn(1, row: self.entries.count - 1, with: nil, select: true)
        }
        let remove = ClosureButton(title: "−") { [weak self] in
            guard let self, self.tableView.selectedRow >= 0 else { return }
            self.entries.remove(at: self.tableView.selectedRow)
            self.onChange?()
        }
        for button in [add, remove] { button.bezelStyle = .smallSquare }
        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 0
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 72),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(string: tableColumn?.identifier.rawValue == "key" ? entries[row].key : entries[row].command)
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = self
        field.tag = row * 2 + (tableColumn?.identifier.rawValue == "key" ? 0 : 1)
        return field
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = field.tag / 2
        guard row < entries.count else { return }
        if field.tag % 2 == 0 { entries[row].key = field.stringValue } else { entries[row].command = field.stringValue }
        onChange?()
    }
}
