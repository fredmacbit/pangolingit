import Cocoa
import PangolinGitCore

/// Settings pane for the Finder context menu: per command top level / submenu / hidden and "only with
/// Shift", plus exclusions (TortoiseGit `SettingsContextMenu.cpp` and `SettingsContextMenu2.cpp`).
/// The Finder extension reads these through the agent the next time a menu opens.
public final class ContextMenuSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private struct Row {
        let entry: ShellMenuEntry
        var placement: ContextMenuPlacement
        var extended: Bool
    }

    private static let commandColumn = NSUserInterfaceItemIdentifier("command")
    private static let placementColumn = NSUserInterfaceItemIdentifier("placement")
    private static let extendedColumn = NSUserInterfaceItemIdentifier("extended")

    private let tableView = NSTableView()
    private let hideOutsideCheckbox = NSButton(checkboxWithTitle: "Hide the menu outside repositories (hold Shift to show it)", target: nil, action: nil)
    private let iconsCheckbox = NSButton(checkboxWithTitle: "Show icons in the menu", target: nil, action: nil)
    private var rows: [Row] = []

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 470))
        setupUI()
        loadData()
    }

    private func setupUI() {
        let intro = NSTextField(wrappingLabelWithString: "Choose where each command appears in Finder. Commands marked “Shift only” appear when you hold Shift while opening the menu. Entries are offered only when they apply to the clicked item.")
        intro.textColor = .secondaryLabelColor

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Self.commandColumn, "Command", 280),
            (Self.placementColumn, "Placement", 140),
            (Self.extendedColumn, "Shift only", 80)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView

        let excludedLabel = NSTextField(labelWithString: "No menu for these paths (one per line; end with * to include everything below):")
        let excludedScroll = NSTextView.scrollableTextView()
        excludedScroll.borderType = .bezelBorder
        if let textView = excludedScroll.documentView as? NSTextView {
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            excludedPathsViewHolder = textView
        }

        for checkbox in [hideOutsideCheckbox, iconsCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(optionChanged)
        }
        let restoreButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))

        for subview in [intro, scrollView, hideOutsideCheckbox, iconsCheckbox, excludedLabel, excludedScroll, restoreButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),

            hideOutsideCheckbox.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            hideOutsideCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            iconsCheckbox.topAnchor.constraint(equalTo: hideOutsideCheckbox.bottomAnchor, constant: 6),
            iconsCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            excludedLabel.topAnchor.constraint(equalTo: iconsCheckbox.bottomAnchor, constant: 12),
            excludedLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            excludedScroll.topAnchor.constraint(equalTo: excludedLabel.bottomAnchor, constant: 6),
            excludedScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            excludedScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            excludedScroll.heightAnchor.constraint(equalToConstant: 54),

            restoreButton.topAnchor.constraint(equalTo: excludedScroll.bottomAnchor, constant: 12),
            restoreButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            restoreButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
    }

    /// The text view inside the exclusions scroll view (created by `scrollableTextView()`).
    private var excludedPathsViewHolder: NSTextView?

    public func loadData() {
        let config = ConfigManager.shared
        let extended = config.contextMenuExtendedCommands
        rows = ShellMenuCatalog.configurableEntries.map {
            Row(entry: $0, placement: config.contextMenuPlacement(for: $0.command), extended: extended.contains($0.command))
        }
        hideOutsideCheckbox.state = config.hideMenusOutsideRepositories ? .on : .off
        iconsCheckbox.state = config.showContextMenuIcons ? .on : .off
        excludedPathsViewHolder?.string = config.contextMenuExcludedPaths.joined(separator: "\n")
        tableView.reloadData()
    }

    public func save() {
        let config = ConfigManager.shared
        for row in rows where row.placement != config.contextMenuPlacement(for: row.entry.command) {
            config.setContextMenuPlacement(row.placement, for: row.entry.command)
        }
        config.contextMenuExtendedCommands = Set(rows.filter(\.extended).map(\.entry.command))
        config.hideMenusOutsideRepositories = hideOutsideCheckbox.state == .on
        config.showContextMenuIcons = iconsCheckbox.state == .on
        if let text = excludedPathsViewHolder?.string {
            config.contextMenuExcludedPaths = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let item = rows[row]
        switch identifier {
        case Self.commandColumn:
            let label = NSTextField(labelWithString: item.entry.title)
            label.lineBreakMode = .byTruncatingTail
            let image = NSImageView(image: NSImage(systemSymbolName: item.entry.symbol, accessibilityDescription: nil) ?? NSImage())
            let stack = NSStackView(views: [image, label])
            stack.spacing = 6
            return stack
        case Self.placementColumn:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.addItems(withTitles: ContextMenuPlacement.allCases.map(\.title))
            popup.selectItem(at: ContextMenuPlacement.allCases.firstIndex(of: item.placement) ?? 1)
            popup.tag = row
            popup.target = self
            popup.action = #selector(placementChanged(_:))
            return popup
        default:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(extendedToggled(_:)))
            checkbox.state = item.extended ? .on : .off
            checkbox.isEnabled = item.placement != .hidden
            checkbox.tag = row
            return checkbox
        }
    }

    @objc private func placementChanged(_ sender: NSPopUpButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].placement = ContextMenuPlacement.allCases[max(0, sender.indexOfSelectedItem)]
        tableView.reloadData(forRowIndexes: IndexSet(integer: sender.tag), columnIndexes: IndexSet(integer: 2))
        save()
    }

    @objc private func extendedToggled(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].extended = sender.state == .on
        save()
    }

    @objc private func optionChanged() {
        save()
    }

    @objc private func restoreDefaults() {
        let config = ConfigManager.shared
        config.resetContextMenu()
        config.hideMenusOutsideRepositories = false
        config.showContextMenuIcons = true
        config.contextMenuExcludedPaths = []
        loadData()
    }
}
