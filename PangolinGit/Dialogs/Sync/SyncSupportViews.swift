import Cocoa
import PangolinGitCore

/// A read-only table of strings with double-click and context-menu hooks, used for the Sync
/// dialog's commit, file, ref and tag tabs.
@MainActor
final class StringTable: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    struct Column {
        let id: String
        let title: String
        let width: CGFloat
        var monospaced = false
    }

    let tableView = NSTableView()
    let scrollView = NSScrollView()
    private let columns: [Column]
    /// Message shown when there are no rows ("No incoming commits", …).
    private let emptyLabel = NSTextField(labelWithString: "")
    var rows: [[String]] = [] {
        didSet {
            tableView.reloadData()
            emptyLabel.isHidden = !rows.isEmpty
        }
    }
    /// Optional per-row text colour (e.g. new / deleted refs).
    var rowColor: ((Int) -> NSColor?)?
    var onDoubleClick: ((Int) -> Void)?
    var menuProvider: ((Int) -> [NSMenuItem])?

    init(columns: [Column], emptyText: String) {
        self.columns = columns
        super.init()
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        emptyLabel.stringValue = emptyText
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    func setEmptyText(_ text: String) {
        emptyLabel.stringValue = text
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let index = columns.firstIndex(where: { $0.id == id }),
              row < rows.count, index < rows[row].count else { return nil }
        let label = NSTextField(labelWithString: rows[row][index])
        label.lineBreakMode = .byTruncatingTail
        if columns[index].monospaced { label.font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
        if let color = rowColor?(row) { label.textColor = color }
        return label
    }

    @objc private func doubleClicked() {
        let row = tableView.clickedRow
        if row >= 0 { onDoubleClick?(row) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, let items = menuProvider?(row) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        items.forEach(menu.addItem)
    }
}

/// Git output pane for the Sync dialog's Log tab: appends streamed text, lets a carriage return
/// overwrite the current line (git's progress counters) and colours error lines.
@MainActor
final class GitOutputView: NSScrollView {

    private let textView = NSTextView()
    private var lineStart = 0
    private var overwrite = false

    init() {
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        documentView = textView
        hasVerticalScroller = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func appendHeader(_ text: String) {
        append("\(text)\n", color: .secondaryLabelColor, bold: true)
    }

    func append(_ text: String, isError: Bool = false) {
        guard let storage = textView.textStorage else { return }
        var segment = ""
        func flush() {
            guard !segment.isEmpty else { return }
            if overwrite {
                storage.deleteCharacters(in: NSRange(location: lineStart, length: storage.length - lineStart))
                overwrite = false
            }
            let lower = segment.lowercased()
            let color: NSColor = lower.hasPrefix("error") || lower.hasPrefix("fatal") || lower.contains("rejected") || lower.contains("conflict")
                ? .systemRed : (isError ? .secondaryLabelColor : .labelColor)
            storage.append(NSAttributedString(string: segment, attributes: [.font: textView.font!, .foregroundColor: color]))
            segment = ""
        }
        for character in text {
            switch character {
            case "\r":
                flush()
                overwrite = true
            case "\n", "\r\n":
                segment.append("\n")
                flush()
                lineStart = storage.length
                overwrite = false
            default:
                segment.append(character)
            }
        }
        flush()
        textView.scrollToEndOfDocument(nil)
    }

    private func append(_ text: String, color: NSColor, bold: Bool) {
        guard let storage = textView.textStorage else { return }
        if lineStart < storage.length { storage.append(NSAttributedString(string: "\n")) }
        let font = bold ? NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold) : textView.font!
        storage.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        lineStart = storage.length
        overwrite = false
        textView.scrollToEndOfDocument(nil)
    }
}

/// A split button: the left part runs the last chosen action, the arrow opens the full menu
/// (TortoiseGit's `CMenuButton` in the Sync dialog).
@MainActor
final class SplitActionButton: NSSegmentedControl {

    struct Action {
        let title: String
        let handler: () -> Void
    }

    private var actions: [Action] = []
    private var current = 0

    convenience init(actions: [Action]) {
        self.init(frame: .zero)
        self.actions = actions
        segmentCount = 2
        trackingMode = .momentary
        segmentStyle = .rounded
        setLabel(actions.first?.title ?? "", forSegment: 0)
        setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More"), forSegment: 1)
        setWidth(22, forSegment: 1)
        target = self
        action = #selector(clicked)
    }

    var currentTitle: String { actions[current].title }

    /// Runs the shown action (the Shift-click full-dialog variant is decided by the handler).
    @objc private func clicked() {
        if selectedSegment == 1 {
            let menu = NSMenu()
            for (index, action) in actions.enumerated() {
                let item = ClosureMenuItem(title: action.title) { [weak self] in self?.choose(index) }
                item.state = index == current ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        } else {
            actions[current].handler()
        }
    }

    private func choose(_ index: Int) {
        current = index
        setLabel(actions[index].title, forSegment: 0)
        sizeToFit()
        actions[index].handler()
    }
}
