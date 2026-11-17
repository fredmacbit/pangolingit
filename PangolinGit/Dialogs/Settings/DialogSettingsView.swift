import Cocoa
import PangolinGitCore

/// Settings pane for dialog defaults and behaviors (`SettingsDialogs.cpp` in TortoiseGit).
public final class DialogSettingsViewController: NSViewController {
    
    private var autoClosePopup: NSPopUpButton!
    private var defaultCommitAllCheckbox: NSButton!
    private var showPushAfterCommitCheckbox: NSButton!
    private var confirmOnRevertCheckbox: NSButton!
    private var maxHistoryField: NSTextField!
    private var useTrashCheckbox: NSButton!
    
    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 380))
        setupUI()
        loadData()
    }
    
    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Dialog Behavior Settings")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        
        let autoCloseLabel = NSTextField(labelWithString: "Progress window:")
        autoCloseLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(autoCloseLabel)
        autoClosePopup = NSPopUpButton()
        autoClosePopup.addItems(withTitles: ConfigManager.ProgressAutoClose.allCases.map(\.title))
        autoClosePopup.target = self
        autoClosePopup.action = #selector(settingChanged)
        autoClosePopup.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(autoClosePopup)
        
        defaultCommitAllCheckbox = NSButton(checkboxWithTitle: "Default commit dialog to check all modified files", target: self, action: #selector(settingChanged))
        defaultCommitAllCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(defaultCommitAllCheckbox)
        
        showPushAfterCommitCheckbox = NSButton(checkboxWithTitle: "Show the Push dialog after a successful commit", target: self, action: #selector(settingChanged))
        showPushAfterCommitCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(showPushAfterCommitCheckbox)
        
        confirmOnRevertCheckbox = NSButton(checkboxWithTitle: "Always ask confirmation before reverting local changes", target: self, action: #selector(settingChanged))
        confirmOnRevertCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(confirmOnRevertCheckbox)
        
        let historyLabel = NSTextField(labelWithString: "Maximum recent items in history dropdowns:")
        historyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(historyLabel)
        
        maxHistoryField = NSTextField()
        maxHistoryField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(maxHistoryField)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            autoCloseLabel.centerYAnchor.constraint(equalTo: autoClosePopup.centerYAnchor),
            autoCloseLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            autoClosePopup.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            autoClosePopup.leadingAnchor.constraint(equalTo: autoCloseLabel.trailingAnchor, constant: 8),
            
            defaultCommitAllCheckbox.topAnchor.constraint(equalTo: autoClosePopup.bottomAnchor, constant: 14),
            defaultCommitAllCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            showPushAfterCommitCheckbox.topAnchor.constraint(equalTo: defaultCommitAllCheckbox.bottomAnchor, constant: 12),
            showPushAfterCommitCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            confirmOnRevertCheckbox.topAnchor.constraint(equalTo: showPushAfterCommitCheckbox.bottomAnchor, constant: 12),
            confirmOnRevertCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            historyLabel.topAnchor.constraint(equalTo: confirmOnRevertCheckbox.bottomAnchor, constant: 18),
            historyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            maxHistoryField.centerYAnchor.constraint(equalTo: historyLabel.centerYAnchor),
            maxHistoryField.leadingAnchor.constraint(equalTo: historyLabel.trailingAnchor, constant: 8),
            maxHistoryField.widthAnchor.constraint(equalToConstant: 60)
        ])

        useTrashCheckbox = NSButton(checkboxWithTitle: "Move files to the Trash when reverting, deleting or cleaning up", target: self, action: #selector(settingChanged))
        useTrashCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(useTrashCheckbox)
        NSLayoutConstraint.activate([
            useTrashCheckbox.topAnchor.constraint(equalTo: historyLabel.bottomAnchor, constant: 18),
            useTrashCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20)
        ])
    }
    
    public func loadData() {
        let config = ConfigManager.shared
        autoClosePopup.selectItem(at: config.progressAutoClose.rawValue)
        defaultCommitAllCheckbox.state = config.defaultCommitAll ? .on : .off
        showPushAfterCommitCheckbox.state = config.showPushAfterCommit ? .on : .off
        confirmOnRevertCheckbox.state = config.confirmOnRevert ? .on : .off
        maxHistoryField.stringValue = "\(config.maxRecentHistory)"
        useTrashCheckbox.state = config.useTrashOnRevert ? .on : .off
    }
    
    public func save() {
        let config = ConfigManager.shared
        config.progressAutoClose = ConfigManager.ProgressAutoClose(rawValue: autoClosePopup.indexOfSelectedItem) ?? .manual
        config.defaultCommitAll = (defaultCommitAllCheckbox.state == .on)
        config.showPushAfterCommit = (showPushAfterCommitCheckbox.state == .on)
        config.confirmOnRevert = (confirmOnRevertCheckbox.state == .on)
        if let val = Int(maxHistoryField.stringValue) {
            config.maxRecentHistory = val
        }
        config.useTrashOnRevert = (useTrashCheckbox.state == .on)
    }
    
    @objc private func settingChanged() {
        save()
    }
}
