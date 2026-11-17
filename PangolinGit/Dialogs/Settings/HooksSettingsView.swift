import Cocoa
import PangolinGitCore

/// Settings ▸ Hook Scripts (TortoiseGit's `SettingsProgsHooks` / `SetHooks.cpp`): client-side scripts
/// that run around PangolinGit's commit, push and rebase (`ClientHookRunner`), plus the folder git's
/// own hooks are taken from (`core.hooksPath`, applied to every git run).
public final class HooksSettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let enableHooksCheckbox = NSButton(checkboxWithTitle: "Run client hook scripts", target: nil, action: nil)
    private let customHooksDirField = NSTextField()
    private let tableView = NSTableView()
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private var hooks: [ClientHook] = []

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
        setupUI()
        loadData()
    }

    private func setupUI() {
        let title = NSTextField(labelWithString: "Hook Scripts")
        title.font = .boldSystemFont(ofSize: 13)
        let description = NSTextField(wrappingLabelWithString:
            "Scripts run by PangolinGit around its own actions. The arguments listed per type are appended to the command line; "
            + "%root% is replaced by the working tree. Projects can provide hooks in .tgitconfig (hook.<type>.cmdline); "
            + "you are asked before such a script runs for the first time.")
        description.textColor = .secondaryLabelColor

        enableHooksCheckbox.target = self
        enableHooksCheckbox.action = #selector(settingChanged)
        enableHooksCheckbox.toolTip = "Master switch for the client hook scripts below (git's own hooks are not affected)."

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for (identifier, title, width) in [("enabled", "On", 30.0), ("type", "Type", 100.0), ("path", "Path", 160.0),
                                           ("command", "Command line", 220.0), ("wait", "Wait", 40.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(editClicked)
        scroll.documentView = tableView

        let addButton = NSButton(title: "Add…", target: self, action: #selector(addClicked))
        editButton.target = self
        editButton.action = #selector(editClicked)
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        let buttons = NSStackView(views: [addButton, editButton, removeButton])
        buttons.spacing = 8

        let dirLabel = NSTextField(labelWithString: "Git hooks folder (core.hooksPath):")
        customHooksDirField.placeholderString = "Default: .git/hooks of each repository"
        customHooksDirField.toolTip = "When set, git runs its own hooks (pre-commit, commit-msg, …) from this folder for every repository PangolinGit works with."
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browseClicked))
        let dirRow = NSStackView(views: [customHooksDirField, browse])
        dirRow.spacing = 8

        for button in [addButton, editButton, removeButton, browse] { button.bezelStyle = .rounded }
        let stack = NSStackView(views: [title, description, enableHooksCheckbox, scroll, buttons, dirLabel, dirRow])
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
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            dirRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateButtons()
    }

    public func loadData() {
        let config = ConfigManager.shared
        enableHooksCheckbox.state = config.hooksEnabled ? .on : .off
        customHooksDirField.stringValue = config.customHooksDirectory
        hooks = ClientHookStore.shared.hooks
        tableView.reloadData()
        updateButtons()
    }

    public func save() {
        let config = ConfigManager.shared
        config.hooksEnabled = (enableHooksCheckbox.state == .on)
        config.customHooksDirectory = customHooksDirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ClientHookStore.shared.hooks = hooks
    }

    private func updateButtons() {
        editButton.isEnabled = tableView.selectedRow >= 0
        removeButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int { hooks.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < hooks.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let hook = hooks[row]
        if identifier == "enabled" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
            checkbox.state = hook.enabled ? .on : .off
            checkbox.tag = row
            return checkbox
        }
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingMiddle
        switch identifier {
        case "type": cell.stringValue = hook.type.title
        case "path": cell.stringValue = hook.path == "*" ? "* (all)" : (hook.path as NSString).abbreviatingWithTildeInPath
        case "command": cell.stringValue = hook.commandLine
        default: cell.stringValue = hook.wait ? "yes" : "no"
        }
        cell.toolTip = cell.stringValue
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard sender.tag < hooks.count else { return }
        hooks[sender.tag].enabled = sender.state == .on
        save()
    }

    // MARK: - Actions

    @objc private func settingChanged() { save() }

    @objc private func browseClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            customHooksDirField.stringValue = url.path
            save()
        }
    }

    @objc private func addClicked() {
        let path = WindowRegistry.shared.currentRepository?.rawPath ?? "*"
        if let hook = editHook(ClientHook(type: .preCommit, path: path, commandLine: "")) {
            hooks.append(hook)
            tableView.reloadData()
            save()
        }
    }

    @objc private func editClicked() {
        let row = tableView.selectedRow
        guard row >= 0, row < hooks.count, let hook = editHook(hooks[row]) else { return }
        hooks[row] = hook
        tableView.reloadData()
        save()
    }

    @objc private func removeClicked() {
        let row = tableView.selectedRow
        guard row >= 0, row < hooks.count else { return }
        hooks.remove(at: row)
        tableView.reloadData()
        updateButtons()
        save()
    }

    /// TortoiseGit's `CSetHooksAdv` dialog: type, working-tree path, command line, wait, hide.
    private func editHook(_ original: ClientHook) -> ClientHook? {
        let alert = NSAlert()
        alert.messageText = "Hook Script"
        alert.informativeText = "The script runs with /bin/sh in the working tree."

        let typePopup = NSPopUpButton()
        for type in ClientHookType.allCases { typePopup.addItem(withTitle: type.title) }
        typePopup.selectItem(at: ClientHookType.allCases.firstIndex(of: original.type) ?? 0)
        let argumentsLabel = NSTextField(labelWithString: "")
        argumentsLabel.textColor = .secondaryLabelColor
        let updateArguments = { argumentsLabel.stringValue = "Arguments: " + ClientHookType.allCases[max(0, typePopup.indexOfSelectedItem)].argumentSummary }
        updateArguments()
        typePopup.target = AlertControlTarget.shared
        typePopup.action = #selector(AlertControlTarget.fire(_:))
        AlertControlTarget.shared.handlers[ObjectIdentifier(typePopup)] = updateArguments

        let pathField = NSTextField(string: original.path)
        pathField.placeholderString = "* = every repository"
        pathField.toolTip = "Working tree (or a folder above it) the script applies to; * for all repositories."
        let commandField = NSTextField(string: original.commandLine)
        commandField.placeholderString = "/path/to/script.sh"
        let waitCheckbox = NSButton(checkboxWithTitle: "Wait for the script to finish", target: nil, action: nil)
        waitCheckbox.state = original.wait ? .on : .off
        waitCheckbox.toolTip = "Without waiting the exit code is ignored and the action continues immediately."
        let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
        enabledCheckbox.state = original.enabled ? .on : .off

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Type:"), typePopup],
            [NSGridCell.emptyContentView, argumentsLabel],
            [NSTextField(labelWithString: "Path:"), pathField],
            [NSTextField(labelWithString: "Command:"), commandField],
            [NSGridCell.emptyContentView, waitCheckbox],
            [NSGridCell.emptyContentView, enabledCheckbox]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 170)
        pathField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        commandField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        defer { AlertControlTarget.shared.handlers.removeValue(forKey: ObjectIdentifier(typePopup)) }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        let path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        return ClientHook(type: ClientHookType.allCases[max(0, typePopup.indexOfSelectedItem)],
                          path: path.isEmpty ? "*" : path, commandLine: command,
                          wait: waitCheckbox.state == .on, show: original.show,
                          enabled: enabledCheckbox.state == .on)
    }
}

/// Routes control actions to closures for controls inside modal alerts.
@MainActor
private final class AlertControlTarget: NSObject {
    static let shared = AlertControlTarget()
    var handlers: [ObjectIdentifier: () -> Void] = [:]

    @objc func fire(_ sender: NSControl) {
        handlers[ObjectIdentifier(sender)]?()
    }
}
