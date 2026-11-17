import Cocoa
import PangolinGitCore

/// Settings pane for configuring Git credential helper (`credential.helper` configuration, Phase 9.6).
public final class GitCredentialViewController: NSViewController {
    
    private var helperPopUp: NSPopUpButton!
    private var customHelperField: NSTextField!
    private var cacheTimeoutField: NSTextField!
    private var statusLabel: NSTextField!
    private var applyToGitConfigButton: NSButton!
    
    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 380))
        setupUI()
        loadData()
    }
    
    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Git Credential Helper")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        
        let descLabel = NSTextField(labelWithString: "Configure how Git stores and retrieves authentication credentials for remote repositories:")
        descLabel.textColor = .secondaryLabelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(descLabel)
        
        let helperLabel = NSTextField(labelWithString: "Credential Storage Mechanism:")
        helperLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(helperLabel)
        
        helperPopUp = NSPopUpButton()
        helperPopUp.addItems(withTitles: [
            "macOS Keychain (osxkeychain — Recommended)",
            "Memory Cache (cache)",
            "Plaintext File (store)",
            "Custom Helper"
        ])
        helperPopUp.target = self
        helperPopUp.action = #selector(helperChanged)
        helperPopUp.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(helperPopUp)
        
        let customLabel = NSTextField(labelWithString: "Custom helper string:")
        customLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(customLabel)
        
        customHelperField = NSTextField()
        customHelperField.placeholderString = "e.g. manager-core or /path/to/helper"
        customHelperField.isEnabled = false
        customHelperField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(customHelperField)
        
        let timeoutLabel = NSTextField(labelWithString: "Cache timeout (seconds, for cache helper):")
        timeoutLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(timeoutLabel)
        
        cacheTimeoutField = NSTextField()
        cacheTimeoutField.stringValue = "900"
        cacheTimeoutField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cacheTimeoutField)
        
        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        
        applyToGitConfigButton = NSButton(title: "Write to Global Git Config (~/.gitconfig)", target: self, action: #selector(applyToGitConfigClicked))
        applyToGitConfigButton.bezelStyle = .rounded
        applyToGitConfigButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(applyToGitConfigButton)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            descLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            descLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            helperLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 18),
            helperLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            helperPopUp.topAnchor.constraint(equalTo: helperLabel.bottomAnchor, constant: 6),
            helperPopUp.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            helperPopUp.widthAnchor.constraint(equalToConstant: 340),
            
            customLabel.topAnchor.constraint(equalTo: helperPopUp.bottomAnchor, constant: 16),
            customLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            customHelperField.topAnchor.constraint(equalTo: customLabel.bottomAnchor, constant: 4),
            customHelperField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            customHelperField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            timeoutLabel.topAnchor.constraint(equalTo: customHelperField.bottomAnchor, constant: 14),
            timeoutLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            cacheTimeoutField.centerYAnchor.constraint(equalTo: timeoutLabel.centerYAnchor),
            cacheTimeoutField.leadingAnchor.constraint(equalTo: timeoutLabel.trailingAnchor, constant: 8),
            cacheTimeoutField.widthAnchor.constraint(equalToConstant: 70),
            
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.bottomAnchor.constraint(equalTo: applyToGitConfigButton.topAnchor, constant: -12),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            applyToGitConfigButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            applyToGitConfigButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        setupLoginPromptSection(below: timeoutLabel)
    }

    // MARK: - PangolinGit login dialog (DA-01)

    private let promptCheckbox = NSButton(checkboxWithTitle: "Ask for missing logins in one PangolinGit dialog (username + password)", target: nil, action: nil)
    private let savedLoginsLabel = NSTextField(labelWithString: "")

    /// The askpass tool also acts as the last credential helper: it asks only when the helper above
    /// had nothing, and can keep the login in the Keychain (removed again if the server rejects it).
    private func setupLoginPromptSection(below anchor: NSView) {
        promptCheckbox.target = self
        promptCheckbox.action = #selector(promptToggled)
        promptCheckbox.state = ConfigManager.shared.useCredentialPrompt ? .on : .off
        let forget = NSButton(title: "Forget Saved Logins", target: self, action: #selector(forgetLogins))
        forget.bezelStyle = .rounded
        savedLoginsLabel.textColor = .secondaryLabelColor
        let row = NSStackView(views: [savedLoginsLabel, forget])
        row.spacing = 8
        let stack = NSStackView(views: [promptCheckbox, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
        updateSavedLogins()
    }

    private func updateSavedLogins() {
        let count = GitCredentialStore.allLogins().count
        savedLoginsLabel.stringValue = "Logins saved by PangolinGit: \(count)"
    }

    @objc private func promptToggled() {
        ConfigManager.shared.useCredentialPrompt = promptCheckbox.state == .on
    }

    @objc private func forgetLogins() {
        let removed = GitCredentialStore.eraseAll()
        updateSavedLogins()
        statusLabel.stringValue = "Removed \(removed) saved login(s) from the Keychain."
    }
    
    public func loadData() {
        let config = ConfigManager.shared
        let helper = config.credentialHelper
        switch helper {
        case "osxkeychain":
            helperPopUp.selectItem(at: 0)
        case "cache":
            helperPopUp.selectItem(at: 1)
        case "store":
            helperPopUp.selectItem(at: 2)
        default:
            helperPopUp.selectItem(at: 3)
            customHelperField.stringValue = helper
        }
        updateCustomFieldState()
        
        // Read active git config in background
        Task {
            do {
                let current = try await GitCLIRunner.runAsync(arguments: ["config", "--global", "--get", "credential.helper"])
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.statusLabel.stringValue = "Active global credential.helper: \(trimmed.isEmpty ? "none" : trimmed)"
                }
            } catch {
                await MainActor.run {
                    self.statusLabel.stringValue = "Active global credential.helper: not set"
                }
            }
        }
    }
    
    public func save() {
        let config = ConfigManager.shared
        let selectedIdx = helperPopUp.indexOfSelectedItem
        switch selectedIdx {
        case 0:
            config.credentialHelper = "osxkeychain"
        case 1:
            config.credentialHelper = "cache"
        case 2:
            config.credentialHelper = "store"
        default:
            config.credentialHelper = customHelperField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    private func updateCustomFieldState() {
        customHelperField.isEnabled = (helperPopUp.indexOfSelectedItem == 3)
    }
    
    @objc private func helperChanged() {
        updateCustomFieldState()
        save()
    }
    
    @objc private func applyToGitConfigClicked() {
        save()
        let config = ConfigManager.shared
        var valueToSet = config.credentialHelper
        if valueToSet == "cache", let timeout = Int(cacheTimeoutField.stringValue) {
            valueToSet = "cache --timeout=\(timeout)"
        }
        
        statusLabel.stringValue = "Writing credential.helper to global Git config..."
        Task {
            do {
                _ = try await GitCLIRunner.runAsync(arguments: ["config", "--global", "credential.helper", valueToSet])
                await MainActor.run {
                    self.statusLabel.stringValue = "Successfully set global credential.helper = '\(valueToSet)'"
                }
            } catch {
                await MainActor.run {
                    self.statusLabel.stringValue = "Error writing git config: \(error.localizedDescription)"
                }
            }
        }
    }
}
