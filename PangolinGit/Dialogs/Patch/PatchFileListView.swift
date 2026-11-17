import Cocoa
import UniformTypeIdentifiers
import PangolinGitCore

/// Ordered list of patch files with Add / Remove / Up / Down, drag-and-drop from Finder and
/// reordering by drag (the file lists of TortoiseGit's `ImportPatchDlg` and `SendMailDlg`).
@MainActor
final class PatchFileListView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private(set) var files: [URL] = []
    /// Called after the list changed.
    var onChange: (() -> Void)?
    /// Double-click on a row (TortoiseGit previews the patch).
    var onOpen: ((URL) -> Void)?
    /// Optional status per file (e.g. "applied"), shown in the second column.
    var statusProvider: ((URL) -> String?)?

    private let tableView = NSTableView()
    private static let rowType = NSPasteboard.PasteboardType("be.macbit.pangolingit.patchrow")

    init(showsButtons: Bool = true) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(showsButtons: showsButtons)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFiles(_ urls: [URL]) {
        files = urls
        tableView.reloadData()
        onChange?()
    }

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) {
            files.append(url)
        }
        tableView.reloadData()
        onChange?()
    }

    func reload() {
        tableView.reloadData()
    }

    private func buildUI(showsButtons: Bool) {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Patch"
        name.width = 360
        tableView.addTableColumn(name)
        let status = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        status.title = "Status"
        status.width = 90
        tableView.addTableColumn(status)
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClicked)
        tableView.registerForDraggedTypes([.fileURL, Self.rowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        scroll.documentView = tableView
        addSubview(scroll)

        var constraints = [
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        if showsButtons {
            let buttons = NSStackView(views: [
                button("Add…", #selector(addClicked)),
                button("Remove", #selector(removeClicked)),
                button("Up", #selector(upClicked)),
                button("Down", #selector(downClicked))
            ])
            buttons.orientation = .vertical
            buttons.alignment = .leading
            buttons.translatesAutoresizingMaskIntoConstraints = false
            addSubview(buttons)
            constraints += [
                buttons.topAnchor.constraint(equalTo: topAnchor),
                buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
                buttons.widthAnchor.constraint(equalToConstant: 90),
                scroll.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -8)
            ]
        } else {
            constraints.append(scroll.trailingAnchor.constraint(equalTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 90).isActive = true
        return button
    }

    // MARK: - Actions

    @objc private func addClicked() {
        let panel = NSOpenPanel()
        panel.title = "Add Patch Files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let last = files.last {
            panel.directoryURL = last.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK else { return }
        add(panel.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
    }

    @objc private func removeClicked() {
        let selection = tableView.selectedRowIndexes
        guard !selection.isEmpty else { return }
        files = files.enumerated().filter { !selection.contains($0.offset) }.map(\.element)
        tableView.reloadData()
        onChange?()
    }

    @objc private func upClicked() { move(by: -1) }
    @objc private func downClicked() { move(by: 1) }

    private func move(by offset: Int) {
        let row = tableView.selectedRow
        let target = row + offset
        guard row >= 0, target >= 0, target < files.count else { return }
        files.swapAt(row, target)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        onChange?()
    }

    @objc private func openClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < files.count else { return }
        onOpen?(files[row])
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }()
        let url = files[row]
        if id.rawValue == "name" {
            cell.stringValue = url.lastPathComponent
            cell.toolTip = url.path
        } else {
            cell.stringValue = statusProvider?(url) ?? ""
            cell.textColor = .secondaryLabelColor
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingSource as? NSTableView === tableView ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let pasteboard = info.draggingPasteboard
        if info.draggingSource as? NSTableView === tableView {
            let rows = (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) }.sorted()
            let moving = rows.map { files[$0] }
            var remaining = files.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
            let insertAt = row - rows.filter { $0 < row }.count
            remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
            files = remaining
        } else {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let new = urls.filter { !files.contains($0) && !$0.hasDirectoryPath }
            files.insert(contentsOf: new, at: max(0, min(row, files.count)))
        }
        tableView.reloadData()
        onChange?()
        return true
    }
}

/// Small helpers shared by the patch, mail, submodule and worktree dialogs.
@MainActor
enum ToolDialog {
    static func window(title: String, repository: PangolinPath?, width: CGFloat, height: CGFloat, resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = repository.map { "\(title) — \($0.filename)" } ?? title
        window.minSize = NSSize(width: min(width, 480), height: min(height, 300))
        return window
    }

    static func label(_ text: String, bold: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        if bold { label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) }
        return label
    }

    static func showError(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    static func showMessage(_ title: String, _ text: String, in window: NSWindow?, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Asks for a folder, starting in `initial` when given.
    static func chooseFolder(title: String, initial: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if let initial, !initial.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: initial)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A text field with a folder `Browse…` button beside it.
    static func folderRow(field: NSTextField, title: String) -> NSStackView {
        let browse = ClosureButton(title: "Browse…") { [weak field] in
            guard let field, let url = chooseFolder(title: title, initial: field.stringValue) else { return }
            field.stringValue = url.path
        }
        browse.bezelStyle = .rounded
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let row = NSStackView(views: [field, browse])
        row.spacing = 6
        return row
    }

    /// Bottom-right button row (Cancel + default action).
    static func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer] + buttons)
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        buttons.forEach { $0.bezelStyle = .rounded }
        return row
    }
}
