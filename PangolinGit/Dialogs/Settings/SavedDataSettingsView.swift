import Cocoa
import PangolinGitCore

/// Settings ▸ Saved Data (TortoiseGit's `SettingsSavedData.cpp`): histories, stored "don't ask again"
/// decisions, remembered window positions and the action log, each with a Clear button; plus export
/// and import of all preferences.
public final class SavedDataSettingsViewController: NSViewController {

    private let commitMsgCountLabel = NSTextField(labelWithString: "")
    private let repoCountLabel = NSTextField(labelWithString: "")
    private let urlCountLabel = NSTextField(labelWithString: "")
    private let decisionsLabel = NSTextField(labelWithString: "")
    private let framesLabel = NSTextField(labelWithString: "")
    private let actionLogLabel = NSTextField(labelWithString: "")

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        setupUI()
        loadData()
    }

    private func setupUI() {
        let title = NSTextField(labelWithString: "Saved Data & History")
        title.font = .boldSystemFont(ofSize: 13)
        let description = NSTextField(labelWithString: "Data PangolinGit remembers between sessions:")
        description.textColor = .secondaryLabelColor

        func clear(_ selector: Selector, tip: String) -> NSButton {
            let button = NSButton(title: "Clear", target: self, action: selector)
            button.bezelStyle = .rounded
            button.toolTip = tip
            return button
        }
        let showLog = NSButton(title: "Show", target: self, action: #selector(showActionLog))
        showLog.bezelStyle = .rounded
        showLog.toolTip = "Open the action log (~/Library/Logs/PangolinGit/action.log) in Console."

        let grid = NSGridView(views: [
            [commitMsgCountLabel, NSGridCell.emptyContentView, clear(#selector(clearMessagesClicked), tip: "Forget recent commit messages.")],
            [repoCountLabel, NSGridCell.emptyContentView, clear(#selector(clearReposClicked), tip: "Forget recent repositories (launcher, Open Recent, Dock menu).")],
            [urlCountLabel, NSGridCell.emptyContentView, clear(#selector(clearUrlsClicked), tip: "Forget URLs typed in Clone.")],
            [decisionsLabel, NSGridCell.emptyContentView, clear(#selector(clearDecisionsClicked), tip: "Ask again in every prompt where you chose “Don't show again”.")],
            [framesLabel, NSGridCell.emptyContentView, clear(#selector(clearFramesClicked), tip: "Forget remembered dialog sizes and positions.")],
            [actionLogLabel, showLog, clear(#selector(clearActionLogClicked), tip: "Delete the action log.")]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).width = 360

        let clearAll = NSButton(title: "Clear All Saved History", target: self, action: #selector(clearAllClicked))
        clearAll.bezelStyle = .rounded
        let export = NSButton(title: "Export Settings…", target: self, action: #selector(exportClicked))
        export.bezelStyle = .rounded
        export.toolTip = "Save all PangolinGit preferences to a property list."
        let importButton = NSButton(title: "Import Settings…", target: self, action: #selector(importClicked))
        importButton.bezelStyle = .rounded
        importButton.toolTip = "Load preferences from an exported property list."
        let buttons = NSStackView(views: [clearAll, NSView(), export, importButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, description, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    public func loadData() {
        let config = ConfigManager.shared
        commitMsgCountLabel.stringValue = "Recent commit messages: \(config.recentCommitMessages.count)"
        repoCountLabel.stringValue = "Recent repositories: \(config.recentRepositories.count)"
        urlCountLabel.stringValue = "Recent clone / remote URLs: \(config.recentUrls.count)"
        decisionsLabel.stringValue = "Stored “don't ask again” decisions: \(StoredDecisions.shared.count)"
        framesLabel.stringValue = "Remembered window positions: \(Self.frameKeys().count)"
        actionLogLabel.stringValue = "Action log: \(ActionLog.shared.lineCount) line(s)"
    }

    /// `NSWindow` frame-autosave entries in the app's defaults.
    static func frameKeys() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("NSWindow Frame ") }
    }

    @objc private func clearMessagesClicked() {
        ConfigManager.shared.clearRecentCommitMessages()
        loadData()
    }

    @objc private func clearReposClicked() {
        ConfigManager.shared.clearRecentRepositories()
        loadData()
    }

    @objc private func clearUrlsClicked() {
        ConfigManager.shared.clearRecentUrls()
        loadData()
    }

    @objc private func clearDecisionsClicked() {
        StoredDecisions.shared.removeAll()
        loadData()
    }

    @objc private func clearFramesClicked() {
        Self.frameKeys().forEach(UserDefaults.standard.removeObject(forKey:))
        loadData()
    }

    @objc private func showActionLog() {
        let url = ActionLog.shared.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func clearActionLogClicked() {
        ActionLog.shared.clear()
        loadData()
    }

    @objc private func clearAllClicked() {
        ConfigManager.shared.clearAllSavedData()
        StoredDecisions.shared.removeAll()
        Self.frameKeys().forEach(UserDefaults.standard.removeObject(forKey:))
        ActionLog.shared.clear()
        loadData()
    }

    // MARK: - Export / import (SE-17)

    @objc private func exportClicked() {
        (view.window?.windowController as? SettingsWindowController)?.saveAll()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PangolinGit Settings.plist"
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: ConfigManager.shared.exportedSettings(),
                                                          format: .xml, options: 0)
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func importClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            ConfigManager.shared.importSettings(values)
            let alert = NSAlert()
            alert.messageText = "Settings imported"
            alert.informativeText = "The Settings window closes now; open it again to see the imported values."
            alert.runModal()
            // Closing would otherwise write the controls' old values back over the import.
            let settings = view.window?.windowController as? SettingsWindowController
            settings?.suppressSave = true
            settings?.close()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
