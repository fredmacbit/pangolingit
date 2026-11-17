import Cocoa
import PangolinGitCore

/// Status list item wrapping a versioned file status entry with UI selection state.
public final class StatusListItem: NSObject {
    public let info: GitItemStatusInfo
    public var isChecked: Bool
    /// Changelist the file belongs to (TortoiseGit changelists); nil when ungrouped.
    public var changelist: String?
    /// Assume-unchanged / skip-worktree flag, for rows listed by "Show flagged files".
    public var flag: GitLocalChangeFlag?
    /// Lines added/removed against HEAD, when the owner supplied them.
    public var lineCount: GitLineCount?
    /// Size and modification date of the working-tree file, read once on demand.
    fileprivate var fileAttributes: (size: Int64?, modified: Date?)?

    public init(info: GitItemStatusInfo, isChecked: Bool = true) {
        self.info = info
        self.isChecked = isChecked
    }

    public var path: String { info.path }
    public var status: GitItemStatus { info.status }
    public var fileExtension: String { (info.path as NSString).pathExtension }

    /// Status text: the flag for flagged files, a rename's origin, git's status otherwise.
    public var statusText: String {
        if let flag, status == .clean { return flag.title }
        return status.description
    }
}

/// Reusable multi-file status selection table view (`GitStatusListCtrl.cpp` in TortoiseGit).
/// Used across Commit, Changed Files, Add, Revert and Resolve dialogs. Columns can be sorted, shown
/// or hidden from the header's context menu and are remembered per `autosaveName`; files in
/// changelists are grouped under a header row whose checkbox toggles the group; Space toggles the
/// checkboxes of the selected rows.
public final class StatusListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    public var onSelectionChanged: (([StatusListItem]) -> Void)?
    public var onDoubleClickItem: ((StatusListItem) -> Void)?
    /// Called when the highlighted (selected, not checked) rows change, e.g. to preview a diff.
    public var onHighlightChanged: (([StatusListItem]) -> Void)?
    /// Builds the right-click menu for the rows it applies to: the whole selection when the clicked
    /// row is part of it, otherwise just the clicked row. Return nil for no menu.
    public var contextMenuProvider: (([StatusListItem]) -> NSMenu?)?
    /// Called after the user toggled one row's checkbox (Commit's staging mode stages/unstages it).
    public var onItemCheckToggled: ((StatusListItem) -> Void)?
    /// Rows whose checkbox is drawn mixed (partially staged files in Commit's staging mode).
    public var mixedPaths: Set<String> = [] {
        didSet { tableView.reloadData() }
    }
    /// Called after Select All / None changed the check marks.
    public var onBulkCheckChanged: (() -> Void)?
    /// Called when the highlighted row changes.
    public var onRowSelectionChanged: ((StatusListItem?) -> Void)?
    
    /// Changelist assignments to group rows by; set before `setItems`.
    public var changelists: ChangelistStore?
    /// Leave files of the `ignore-on-commit` changelist unchecked (the Commit dialog's behaviour).
    public var uncheckIgnoreOnCommit = false
    /// Shown in place of the list when it has no rows (TortoiseGit's empty-list hint).
    public var emptyMessage = "There are no files to show." {
        didSet { updateEmptyState() }
    }
    /// Remembers column widths, order and visibility under this name.
    public var autosaveName: String? {
        didSet {
            guard let autosaveName else { return }
            tableView.autosaveName = "StatusList." + autosaveName
            tableView.autosaveTableColumns = true
        }
    }

    private var scrollView: NSScrollView!
    private var tableView: StatusTableView!
    private var filterField: NSSearchField!
    private var statsLabel: NSTextField!
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    private var allItems: [StatusListItem] = []
    private var filteredItems: [StatusListItem] = []
    private var rows: [Row] = []

    private enum Row {
        case header(String, [StatusListItem])
        case item(StatusListItem)
    }

    /// Columns besides the checkbox: identifier, title, width, hidden by default.
    private static let columns: [(id: String, title: String, width: CGFloat, hidden: Bool)] = [
        ("status", "Status", 110, false),
        ("path", "File Path", 320, false),
        ("extension", "Extension", 70, false),
        ("linesAdded", "Lines Added", 80, true),
        ("linesRemoved", "Lines Removed", 90, true),
        ("modified", "Last Modified", 140, true),
        ("size", "Size", 80, true)
    ]

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        // Search / filter field
        filterField = NSSearchField()
        filterField.placeholderString = "Filter files..."
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterField)

        // Select All / Deselect buttons
        let selectAllBtn = NSButton(title: "Select All", target: self, action: #selector(selectAllClicked))
        selectAllBtn.bezelStyle = .inline
        selectAllBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectAllBtn)

        let deselectAllBtn = NSButton(title: "None", target: self, action: #selector(deselectAllClicked))
        deselectAllBtn.bezelStyle = .inline
        deselectAllBtn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deselectAllBtn)

        // Scroll view & table
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView = StatusTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.target = self
        tableView.doubleAction = #selector(onRowDoubleClicked)
        tableView.onToggleKey = { [weak self] in self?.toggleSelectedRows() }
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu

        // Checkbox column
        let checkCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check"))
        checkCol.title = ""
        checkCol.width = 30
        checkCol.minWidth = 30
        checkCol.maxWidth = 30
        tableView.addTableColumn(checkCol)

        let headerMenu = NSMenu()
        for spec in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.isHidden = spec.hidden
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            tableView.addTableColumn(column)
            if spec.id != "path" {
                let item = NSMenuItem(title: spec.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = spec.id
                headerMenu.addItem(item)
            }
        }
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu

        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        addSubview(scrollView)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        // Statistics label
        statsLabel = NSTextField(labelWithString: "0 files")
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.font = NSFont.systemFont(ofSize: 11)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statsLabel)

        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: topAnchor),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterField.widthAnchor.constraint(equalToConstant: 220),

            selectAllBtn.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            selectAllBtn.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 8),

            deselectAllBtn.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            deselectAllBtn.leadingAnchor.constraint(equalTo: selectAllBtn.trailingAnchor, constant: 6),

            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statsLabel.topAnchor, constant: -6),

            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -24),

            statsLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            statsLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Data Management

    public func setItems(_ items: [GitItemStatusInfo], defaultChecked: Bool = true) {
        setItems(items) { _ in defaultChecked }
    }

    public func setItems(_ items: [GitItemStatusInfo], isChecked: (GitItemStatusInfo) -> Bool) {
        let previous = Set(allItems.map(\.path))
        self.allItems = items.map { info in
            let item = StatusListItem(info: info, isChecked: isChecked(info))
            item.changelist = changelists?.changelist(for: info.path)
            // Only newly listed files: a reload must not undo the user's own checkmark.
            if uncheckIgnoreOnCommit && item.changelist == ChangelistStore.ignoreOnCommit && !previous.contains(info.path) {
                item.isChecked = false
            }
            return item
        }
        applyFilter()
    }

    /// Marks rows as assume-unchanged / skip-worktree (shown in the Status column).
    public func setFlags(_ flags: [String: GitLocalChangeFlag]) {
        for item in allItems { item.flag = flags[item.path] }
        tableView.reloadData()
    }

    /// Fills the Lines Added / Lines Removed columns.
    public func setLineCounts(_ counts: [String: GitLineCount]) {
        for item in allItems { item.lineCount = counts[item.path] }
        tableView.reloadData()
    }

    /// Re-reads changelist assignments (after "Move to changelist") and regroups the rows.
    public func reloadChangelists() {
        for item in allItems { item.changelist = changelists?.changelist(for: item.path) }
        applyFilter()
    }

    /// Checked items that are currently visible; rows hidden by the filter are never acted upon.
    public var checkedItems: [StatusListItem] {
        return filteredItems.filter { $0.isChecked }
    }

    public var checkedPaths: [String] {
        return checkedItems.map { $0.path }
    }

    /// Every row, including those hidden by the filter.
    public var listedItems: [StatusListItem] {
        return allItems
    }

    /// Rows currently visible (after the filter), in display order.
    public var visibleItems: [StatusListItem] {
        return filteredItems
    }

    /// Rows highlighted in the table (not the checkboxes).
    public var selectedItems: [StatusListItem] {
        return items(atRows: tableView.selectedRowIndexes)
    }

    /// Highlights the first file row (for dialogs that preview the highlighted file).
    public func highlightFirstItem() {
        guard let index = rows.firstIndex(where: { if case .item = $0 { return true } else { return false } }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    /// Paths that are checked, including rows hidden by the filter (for restoring state after a reload).
    public var allCheckedPaths: Set<String> {
        return Set(allItems.filter { $0.isChecked }.map { $0.path })
    }

    private func applyFilter() {
        let filterText = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if filterText.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter {
                $0.path.lowercased().contains(filterText) || $0.statusText.lowercased().contains(filterText)
                    || ($0.changelist?.lowercased().contains(filterText) ?? false)
            }
        }
        sortItems()
        rebuildRows()
        tableView.reloadData()
        updateStatsLabel()
        updateEmptyState()
    }

    /// Groups by changelist (ungrouped first) once any visible file is in one.
    private func rebuildRows() {
        guard filteredItems.contains(where: { $0.changelist != nil }) else {
            rows = filteredItems.map { .item($0) }
            return
        }
        var groups: [String: [StatusListItem]] = [:]
        var ungrouped: [StatusListItem] = []
        for item in filteredItems {
            if let name = item.changelist {
                groups[name, default: []].append(item)
            } else {
                ungrouped.append(item)
            }
        }
        rows = []
        if !ungrouped.isEmpty {
            rows.append(.header("(no changelist)", ungrouped))
            rows += ungrouped.map { .item($0) }
        }
        let order = (changelists?.names ?? []) + groups.keys.sorted()
        var seen = Set<String>()
        for name in order where seen.insert(name).inserted {
            guard let members = groups[name] else { continue }
            rows.append(.header(name, members))
            rows += members.map { .item($0) }
        }
    }

    private func items(atRows indexes: IndexSet) -> [StatusListItem] {
        var result: [StatusListItem] = []
        var seen = Set<ObjectIdentifier>()
        for index in indexes where index < rows.count {
            let members: [StatusListItem]
            switch rows[index] {
            case .header(_, let group): members = group
            case .item(let item): members = [item]
            }
            for item in members where seen.insert(ObjectIdentifier(item)).inserted {
                result.append(item)
            }
        }
        return result
    }

    private func updateStatsLabel() {
        let selectedCount = checkedItems.count
        let totalCount = allItems.count
        statsLabel.stringValue = "\(totalCount) item(s) total (\(selectedCount) selected)"
        onSelectionChanged?(checkedItems)
    }

    private func updateEmptyState() {
        let isEmpty = rows.isEmpty
        emptyLabel.isHidden = !isEmpty
        emptyLabel.stringValue = allItems.isEmpty ? emptyMessage : "No files match the filter."
    }

    // MARK: - Sorting

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyFilter()
    }

    private func sortItems() {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        let ascending = descriptor.ascending
        filteredItems.sort { lhs, rhs in
            let result = compare(lhs, rhs, key: key)
            if result == .orderedSame {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func compare(_ lhs: StatusListItem, _ rhs: StatusListItem, key: String) -> ComparisonResult {
        func order<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
            switch (a, b) {
            case let (a?, b?): return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
            case (nil, _?): return .orderedAscending
            case (_?, nil): return .orderedDescending
            default: return .orderedSame
            }
        }
        switch key {
        case "status": return lhs.statusText.localizedStandardCompare(rhs.statusText)
        case "path": return lhs.path.localizedStandardCompare(rhs.path)
        case "extension": return lhs.fileExtension.localizedStandardCompare(rhs.fileExtension)
        case "linesAdded": return order(lhs.lineCount?.added, rhs.lineCount?.added)
        case "linesRemoved": return order(lhs.lineCount?.removed, rhs.lineCount?.removed)
        case "modified": return order(attributes(of: lhs).modified, attributes(of: rhs).modified)
        case "size": return order(attributes(of: lhs).size, attributes(of: rhs).size)
        default: return .orderedSame
        }
    }

    private func attributes(of item: StatusListItem) -> (size: Int64?, modified: Date?) {
        if let cached = item.fileAttributes { return cached }
        var result: (size: Int64?, modified: Date?) = (nil, nil)
        if let root = repositoryRoot,
           let attributes = try? FileManager.default.attributesOfItem(atPath: root.appending(item.path).rawPath) {
            let isFile = (attributes[.type] as? FileAttributeType) == .typeRegular
            result = (isFile ? (attributes[.size] as? NSNumber)?.int64Value : nil, attributes[.modificationDate] as? Date)
        }
        item.fileAttributes = result
        return result
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - NSTableViewDataSource & Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        return rows.count
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < rows.count, case .header = rows[row] else { return false }
        return true
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        onHighlightChanged?(selectedItems)
        onRowSelectionChanged?(selectedItem)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let item: StatusListItem
        switch rows[row] {
        case .header(let name, let members):
            // Group rows are drawn once across all columns.
            guard tableColumn == nil else { return nil }
            let checked = members.filter(\.isChecked).count
            let button = NSButton(checkboxWithTitle: "\(name) (\(members.count))", target: self, action: #selector(groupCheckboxToggled(_:)))
            button.allowsMixedState = true
            button.state = checked == 0 ? .off : (checked == members.count ? .on : .mixed)
            button.font = NSFont.boldSystemFont(ofSize: 12)
            button.tag = row
            return button
        case .item(let rowItem):
            guard let tableColumn else { return nil }
            item = rowItem
            let col = tableColumn
            return cell(for: item, column: col.identifier.rawValue, row: row)
        }
    }

    private func label(_ id: String) -> NSTextField {
        let cellId = NSUserInterfaceItemIdentifier(id)
        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTextField {
            return existing
        }
        let text = NSTextField(labelWithString: "")
        text.identifier = cellId
        text.lineBreakMode = .byTruncatingMiddle
        return text
    }

    private func cell(for item: StatusListItem, column: String, row: Int) -> NSView? {
        switch column {
        case "check":
            let cellId = NSUserInterfaceItemIdentifier("StatusCheckCell")
            var button = tableView.makeView(withIdentifier: cellId, owner: self) as? NSButton
            if button == nil {
                button = NSButton(checkboxWithTitle: "", target: self, action: #selector(itemCheckboxToggled(_:)))
                button?.identifier = cellId
            }
            button?.allowsMixedState = mixedPaths.contains(item.path)
            button?.state = mixedPaths.contains(item.path) ? .mixed : (item.isChecked ? .on : .off)
            button?.tag = row
            return button

        case "status":
            let text = label("StatusNameCell")
            text.stringValue = item.statusText
            text.textColor = item.flag != nil && item.status == .clean ? .secondaryLabelColor : statusColor(for: item.status)
            text.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            return text

        case "path":
            let text = label("StatusPathCell")
            if let original = item.info.originalPath, item.status == .renamed || item.status == .copied {
                text.stringValue = "\(item.path) (from \(original))"
            } else {
                text.stringValue = item.path
            }
            text.textColor = .labelColor
            return text

        case "extension":
            let text = label("StatusExtCell")
            text.stringValue = item.fileExtension.isEmpty ? "-" : item.fileExtension
            text.textColor = .secondaryLabelColor
            return text

        case "linesAdded", "linesRemoved":
            let text = label("StatusLinesCell")
            let value = column == "linesAdded" ? item.lineCount?.added : item.lineCount?.removed
            text.stringValue = item.lineCount == nil ? "" : (value.map(String.init) ?? "binary")
            text.textColor = .secondaryLabelColor
            text.alignment = .right
            return text

        case "modified":
            let text = label("StatusModifiedCell")
            text.stringValue = attributes(of: item).modified.map { Self.dateFormatter.string(from: $0) } ?? ""
            text.textColor = .secondaryLabelColor
            return text

        case "size":
            let text = label("StatusSizeCell")
            text.stringValue = attributes(of: item).size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            text.textColor = .secondaryLabelColor
            text.alignment = .right
            return text

        default:
            return nil
        }
    }

    /// Status colours; modified / added / deleted follow Settings ▸ Colors (TortoiseGit's Colors 1 page).
    private func statusColor(for status: GitItemStatus) -> NSColor {
        switch status {
        case .modified, .stagedModified, .renamed, .copied:
            return DiffColors.modified
        case .added, .staged:
            return DiffColors.added
        case .deleted, .missing:
            return DiffColors.deleted
        case .conflicted:
            return .systemOrange
        case .untracked:
            return .systemPurple
        case .ignored:
            return .tertiaryLabelColor
        default:
            return .labelColor
        }
    }
    
    

    // MARK: - Context Menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === tableView.headerView?.menu {
            for item in menu.items {
                guard let id = item.representedObject as? String,
                      let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { continue }
                item.state = column.isHidden ? .off : .on
            }
            return
        }
        menu.removeAllItems()
        let clicked = tableView.clickedRow
        guard clicked >= 0, clicked < rows.count, let provider = contextMenuProvider else { return }
        let indexes = tableView.selectedRowIndexes.contains(clicked) ? tableView.selectedRowIndexes : IndexSet(integer: clicked)
        let targets = items(atRows: indexes)
        guard !targets.isEmpty, let built = provider(targets) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) else { return }
        column.isHidden.toggle()
    }

    // MARK: - Actions

    @objc private func itemCheckboxToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row < rows.count, case .item(let item) = rows[row] else { return }
        // A mixed box cycles to "on" when clicked; stop drawing it mixed.
        if sender.state == .mixed { sender.state = .on }
        sender.allowsMixedState = false
        item.isChecked = (sender.state == .on)
        mixedPaths.remove(item.path)
        reloadGroupHeaders()
        updateStatsLabel()
        onItemCheckToggled?(item)
    }

    /// Clicking a changelist header checks or unchecks the whole group.
    @objc private func groupCheckboxToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row < rows.count, case .header(_, let members) = rows[row] else { return }
        let check = !members.allSatisfy(\.isChecked)
        members.forEach { $0.isChecked = check }
        tableView.reloadData()
        updateStatsLabel()
    }

    /// Space bar: toggles the checkboxes of the selected rows (all on unless all are already on).
    private func toggleSelectedRows() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let check = !targets.allSatisfy(\.isChecked)
        targets.forEach { $0.isChecked = check }
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
        updateStatsLabel()
    }

    private func reloadGroupHeaders() {
        let headerRows = IndexSet(rows.indices.filter { if case .header = rows[$0] { return true } else { return false } })
        guard !headerRows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: headerRows, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    @objc private func selectAllClicked() {
        for item in allItems { item.isChecked = true }
        tableView.reloadData()
        updateStatsLabel()
        onBulkCheckChanged?()
    }

    @objc private func deselectAllClicked() {
        for item in allItems { item.isChecked = false }
        tableView.reloadData()
        updateStatsLabel()
        onBulkCheckChanged?()
    }
    
    /// Checks or unchecks every row matching `predicate`, leaving the others alone
    /// (TortoiseGit's "Check: Unversioned / Added / Modified …" links, `CGitStatusListCtrl::Check`).
    public func setChecked(_ checked: Bool, where predicate: (StatusListItem) -> Bool) {
        for item in allItems where predicate(item) { item.isChecked = checked }
        tableView.reloadData()
        updateStatsLabel()
    }
    
    /// The row the user selected last (for a patch preview beside the list).
    public var selectedItem: StatusListItem? {
        // Table rows include changelist headers, so map through `rows`.
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return nil }
        return item
    }

    @objc private func filterChanged() {
        applyFilter()
    }

    @objc private func onRowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return }
        onDoubleClickItem?(item)
    }

    // MARK: - Drag and drop (SH-09, TortoiseGit's `CGitStatusListCtrl` OLE drag source / drop target)

    /// Root the listed paths are relative to. Enables the Size and Last Modified columns, and rows can be
    /// dragged into Finder or an editor as files.
    public var repositoryRoot: PangolinPath? {
        didSet { tableView.setDraggingSourceOperationMask(.copy, forLocal: false) }
    }

    /// Called with the file URLs dropped onto the list from Finder; setting it enables dropping.
    public var onDropFiles: (([URL]) -> Void)? {
        didSet {
            if onDropFiles == nil {
                tableView.unregisterDraggedTypes()
            } else {
                tableView.registerForDraggedTypes([.fileURL])
            }
        }
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let repositoryRoot, row < rows.count, case .item(let item) = rows[row] else { return nil }
        let url = repositoryRoot.appending(item.path).url
        // Deleted or missing rows have no file to hand over.
        return FileManager.default.fileExists(atPath: url.path) ? url as NSURL : nil
    }

    public func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                          proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard onDropFiles != nil, (info.draggingSource as? NSTableView) !== tableView else { return [] }
        // Highlight the whole list rather than a row: dropped files are not inserted at a position.
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    public func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                          dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let onDropFiles, !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
    }
}

/// Table that reports the Space bar so the list can toggle checkboxes from the keyboard.
private final class StatusTableView: NSTableView {
    var onToggleKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onToggleKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}
