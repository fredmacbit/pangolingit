import Cocoa
import PangolinGitCore

/// Settings ▸ Advanced (TortoiseGit's `SetAdvanced.cpp`): a typed list of documented options, each
/// with its default and the place that reads it (`AdvancedSetting`). Values are validated by type;
/// an empty value restores the default.
public final class AdvancedSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private let tableView = NSTableView()
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let settings = AdvancedSetting.all

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
        setupUI()
        loadData()
    }

    private func setupUI() {
        let title = NSTextField(labelWithString: "Advanced Settings")
        title.font = .boldSystemFont(ofSize: 13)
        let hint = NSTextField(wrappingLabelWithString: "Double-click a value to change it. Leave it empty to use the default. "
            + "Administrators can preset these keys with a configuration profile (domain group.be.macbit.pangolingit, key advancedSettings).")
        hint.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for (identifier, title, width) in [("key", "Option", 170.0), ("value", "Value", 170.0), ("default", "Default", 120.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView

        descriptionLabel.textColor = .secondaryLabelColor
        let resetButton = NSButton(title: "Reset to Default", target: self, action: #selector(resetClicked))
        resetButton.bezelStyle = .rounded
        resetButton.toolTip = "Restore the default of the selected option."

        let stack = NSStackView(views: [title, hint, scroll, descriptionLabel, resetButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            descriptionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    public func loadData() {
        tableView.reloadData()
    }

    /// Values are saved as they are edited.
    public func save() {}

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int { settings.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < settings.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let setting = settings[row]
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = setting.summary
        switch identifier {
        case "key":
            field.stringValue = setting.key
        case "value":
            field.stringValue = ConfigManager.shared.advancedValue(setting) ?? ""
            field.placeholderString = setting.defaultString
            field.isEditable = true
            field.delegate = self
            field.tag = row
        default:
            field.stringValue = setting.defaultString
            field.textColor = .secondaryLabelColor
        }
        return field
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        descriptionLabel.stringValue = row >= 0 && row < settings.count ? settings[row].summary : ""
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field.tag < settings.count else { return }
        let setting = settings[field.tag]
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty && !setting.accepts(value) {
            NSSound.beep()
            descriptionLabel.stringValue = "“\(value)” is not a valid value for \(setting.key). " + setting.summary
            field.stringValue = ConfigManager.shared.advancedValue(setting) ?? ""
            return
        }
        ConfigManager.shared.setAdvancedValue(value, for: setting)
    }

    @objc private func resetClicked() {
        let row = tableView.selectedRow
        guard row >= 0, row < settings.count else { return }
        ConfigManager.shared.setAdvancedValue(nil, for: settings[row])
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<3))
    }
}
