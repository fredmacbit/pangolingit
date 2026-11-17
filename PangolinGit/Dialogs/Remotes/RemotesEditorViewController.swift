import Cocoa
import UniformTypeIdentifiers
import PangolinGitCore

/// Remote list + edit form, TortoiseGit's Settings ▸ Git ▸ Remote page (`SettingGitRemote.cpp`):
/// add, rename, URL, separate push URL, SSH key, tag option, prune, default push remote; plus fetch,
/// prune and *Delete remote tags* per remote. Used by the Remotes window and the Settings pane.
@MainActor
final class RemotesEditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    let repositoryPath: PangolinPath
    private var remotes: [GitRemoteConfig] = []
    private var pushDefault: String?
    /// Row being added and not yet saved to git.
    private var draft: GitRemoteConfig?

    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let pushURLField = NSTextField()
    private let sshKeyField = NSTextField()
    private let tagsPopup = NSPopUpButton()
    private let prunePopup = NSPopUpButton()
    private let pushDefaultCheckbox = NSButton(checkboxWithTitle: "Default remote for pushes (remote.pushDefault)", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var remoteActionButtons: [NSButton] = []
    private var formControls: [NSControl] = []

    init(repositoryPath: PangolinPath) {
        self.repositoryPath = repositoryPath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
        setupUI()
        reload()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.reload() }
    }

    // MARK: - UI

    private func setupUI() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        column.title = "Remote"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "Add", target: self, action: #selector(addClicked))
        let removeButton = NSButton(title: "Remove…", target: self, action: #selector(removeClicked))
        let listButtons = RemoteDialogSupport.hStack([addButton, removeButton])
        listButtons.translatesAutoresizingMaskIntoConstraints = false

        urlField.placeholderString = "https://host/repo.git or git@host:repo.git"
        pushURLField.placeholderString = "Same as URL"
        sshKeyField.placeholderString = "Private key for this remote (optional)"
        tagsPopup.addItems(withTitles: GitRemoteConfig.TagOption.allCases.map(\.title))
        prunePopup.addItems(withTitles: ["Default (fetch.prune)", "On", "Off"])
        for field in [nameField, urlField, pushURLField, sshKeyField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        let browseKey = NSButton(title: "Browse…", target: self, action: #selector(browseKey))
        let agentButton = NSButton(title: "Add to Agent", target: self, action: #selector(addKeyToAgent))
        agentButton.toolTip = "ssh-add --apple-use-keychain: unlock the key once and keep its passphrase in the Keychain"
        let sshConfigButton = NSButton(title: "Edit ~/.ssh/config…", target: self, action: #selector(editSSHConfig))
        sshConfigButton.toolTip = "Host aliases, users and keys per host (macOS counterpart of PuTTY sessions)"

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.keyEquivalent = "\r"
        let fetchButton = NSButton(title: "Fetch", target: self, action: #selector(fetchClicked))
        let pruneButton = NSButton(title: "Prune", target: self, action: #selector(pruneClicked))
        pruneButton.toolTip = "Remove remote-tracking branches that no longer exist on the remote"
        let deleteTagsButton = NSButton(title: "Delete Remote Tags…", target: self, action: #selector(deleteTagsClicked))
        remoteActionButtons = [fetchButton, pruneButton, deleteTagsButton, removeButton]

        let form = RemoteDialogSupport.grid([
            [RemoteDialogSupport.label("Name:"), nameField],
            [RemoteDialogSupport.label("URL:"), urlField],
            [RemoteDialogSupport.label("Push URL:"), pushURLField],
            [RemoteDialogSupport.label("SSH key:"), RemoteDialogSupport.hStack([sshKeyField, browseKey])],
            [nil, RemoteDialogSupport.hStack([agentButton, sshConfigButton])],
            [RemoteDialogSupport.label("Tags:"), tagsPopup],
            [RemoteDialogSupport.label("Prune:"), prunePopup],
            [nil, pushDefaultCheckbox],
            [nil, RemoteDialogSupport.hStack([saveButton, fetchButton, pruneButton, deleteTagsButton])],
        ])
        formControls = [nameField, urlField, pushURLField, sshKeyField, tagsPopup, prunePopup, pushDefaultCheckbox,
                        saveButton, browseKey, agentButton]

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        view.addSubview(listButtons)
        view.addSubview(form)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalToConstant: 170),
            scroll.bottomAnchor.constraint(equalTo: listButtons.topAnchor, constant: -8),
            listButtons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            listButtons.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            form.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            form.bottomAnchor.constraint(lessThanOrEqualTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        showForm(nil)
    }

    // MARK: - Data

    func reload() {
        let root = repositoryPath
        Task { @MainActor in
            let previous = self.selectedRemote?.name
            self.remotes = await GitRemotes.loadRemotes(in: root)
            self.pushDefault = await GitRemotes.configValue("remote.pushDefault", in: root)
            self.tableView.reloadData()
            if self.draft == nil {
                let index = self.remotes.firstIndex { $0.name == previous } ?? (self.remotes.isEmpty ? nil : 0)
                if let index {
                    self.tableView.selectRowIndexes([index], byExtendingSelection: false)
                }
                self.showForm(index.map { self.remotes[$0] })
            }
            self.statusLabel.stringValue = "\(self.remotes.count) remote(s) configured"
        }
    }

    private var rows: [GitRemoteConfig] { remotes + (draft.map { [$0] } ?? []) }

    private var selectedRemote: GitRemoteConfig? {
        let row = tableView.selectedRow
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    private var selectedSavedRemote: GitRemoteConfig? {
        let row = tableView.selectedRow
        return row >= 0 && row < remotes.count ? remotes[row] : nil
    }

    private func showForm(_ remote: GitRemoteConfig?) {
        nameField.stringValue = remote?.name ?? ""
        urlField.stringValue = remote?.url ?? ""
        pushURLField.stringValue = remote?.pushURL ?? ""
        sshKeyField.stringValue = remote?.sshKey ?? ""
        tagsPopup.selectItem(at: GitRemoteConfig.TagOption.allCases.firstIndex(of: remote?.tagOption ?? .reachable) ?? 0)
        switch remote?.prune {
        case true?: prunePopup.selectItem(at: 1)
        case false?: prunePopup.selectItem(at: 2)
        case nil: prunePopup.selectItem(at: 0)
        }
        pushDefaultCheckbox.state = (remote != nil && remote?.name == pushDefault) ? .on : .off
        let editing = remote != nil
        formControls.forEach { $0.isEnabled = editing }
        // Fetch / Prune / Delete tags / Remove need a remote that exists in git.
        remoteActionButtons.forEach { $0.isEnabled = draft == nil && selectedSavedRemote != nil }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let remote = rows[row]
        let isDraft = row >= remotes.count
        let label = NSTextField(labelWithString: isDraft ? "(new remote)" : remote.name)
        label.font = remote.name == pushDefault ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        label.textColor = isDraft ? .secondaryLabelColor : .labelColor
        label.toolTip = remote.url
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if draft != nil, tableView.selectedRow != remotes.count {
            // Leaving an unsaved new remote discards it.
            draft = nil
            tableView.reloadData()
        }
        showForm(selectedRemote)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < remotes.count else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        let remote = remotes[row]
        menu.addItem(ClosureMenuItem(title: "Fetch “\(remote.name)”", symbol: "arrow.down.circle") { [weak self] in self?.fetchClicked() })
        menu.addItem(ClosureMenuItem(title: "Prune Stale Branches", symbol: "scissors") { [weak self] in self?.pruneClicked() })
        menu.addItem(ClosureMenuItem(title: "Delete Remote Tags…", symbol: "tag.slash") { [weak self] in self?.deleteTagsClicked() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Copy URL", symbol: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(remote.url, forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Remove…", symbol: "trash") { [weak self] in self?.removeClicked() })
    }

    // MARK: - Actions

    @objc private func addClicked() {
        draft = GitRemoteConfig(name: remotes.isEmpty ? "origin" : "")
        tableView.reloadData()
        tableView.selectRowIndexes([remotes.count], byExtendingSelection: false)
        showForm(draft)
        remoteActionButtons.forEach { $0.isEnabled = false }
        // Paste a URL from the clipboard, as TortoiseGit does for new remotes.
        if let clip = NSPasteboard.general.string(forType: .string), GitURL.looksLikeRemoteURL(clip) {
            urlField.stringValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        view.window?.makeFirstResponder(nameField)
    }

    /// The edited values as a remote configuration.
    private var formValue: GitRemoteConfig {
        let prune: Bool? = [nil, true, false][max(0, prunePopup.indexOfSelectedItem)]
        let trimmed = { (field: NSTextField) in field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        return GitRemoteConfig(name: trimmed(nameField), url: trimmed(urlField), pushURL: trimmed(pushURLField),
                               tagOption: GitRemoteConfig.TagOption.allCases[max(0, tagsPopup.indexOfSelectedItem)],
                               prune: prune, sshKey: trimmed(sshKeyField))
    }

    @objc private func saveClicked() {
        let original = draft == nil ? selectedSavedRemote : nil
        let edited = formValue
        guard !edited.name.isEmpty, !edited.url.isEmpty else {
            statusLabel.stringValue = "A remote needs a name and a URL."
            NSSound.beep()
            return
        }
        guard edited.name.range(of: #"^[^\s~^:?*\[\\]+$"#, options: .regularExpression) != nil else {
            statusLabel.stringValue = "“\(edited.name)” is not a valid remote name."
            NSSound.beep()
            return
        }
        let commands = Self.saveCommands(original: original, edited: edited,
                                         makePushDefault: pushDefaultCheckbox.state == .on, currentPushDefault: pushDefault)
        let root = repositoryPath
        Task { @MainActor in
            do {
                for (arguments, mayFail) in commands {
                    let result = try await GitCLIRunner().run(arguments: arguments, workingDirectory: root)
                    if !result.isSuccess && !mayFail {
                        throw GitCLIError.commandFailed(exitCode: result.exitCode, stderr: result.standardError,
                                                        command: GitCLIRunner.commandLine(arguments))
                    }
                }
                self.draft = nil
                self.statusLabel.stringValue = "Saved remote “\(edited.name)”."
                self.reloadSelecting(edited.name)
            } catch {
                NSAlert(error: error).runModal()
                self.reload()
            }
        }
    }

    private func reloadSelecting(_ name: String) {
        let root = repositoryPath
        Task { @MainActor in
            self.remotes = await GitRemotes.loadRemotes(in: root)
            self.pushDefault = await GitRemotes.configValue("remote.pushDefault", in: root)
            self.tableView.reloadData()
            if let index = self.remotes.firstIndex(where: { $0.name == name }) {
                self.tableView.selectRowIndexes([index], byExtendingSelection: false)
                self.showForm(self.remotes[index])
            }
        }
    }

    /// The git commands that turn `original` (nil = new remote) into `edited`; the flag marks
    /// `--unset` calls, which fail harmlessly when the key is already absent.
    nonisolated static func saveCommands(original: GitRemoteConfig?, edited: GitRemoteConfig,
                             makePushDefault: Bool, currentPushDefault: String?) -> [([String], Bool)] {
        var commands: [([String], Bool)] = []
        let name = edited.name
        if let original {
            if original.name != name {
                commands.append((["remote", "rename", original.name, name], false))
            }
            if original.url != edited.url {
                commands.append((["remote", "set-url", name, edited.url], false))
            }
        } else {
            commands.append((["remote", "add", name, edited.url], false))
        }
        let section = "remote.\(name)"
        func set(_ key: String, _ value: String?, old: String?) {
            guard value != old || original == nil else { return }
            if let value, !value.isEmpty {
                commands.append((["config", "\(section).\(key)", value], false))
            } else if original != nil {
                commands.append((["config", "--unset-all", "\(section).\(key)"], true))
            }
        }
        set("pushurl", edited.pushURL, old: original?.pushURL)
        set("tagopt", edited.tagOption.rawValue, old: original?.tagOption.rawValue)
        set("prune", edited.prune.map { $0 ? "true" : "false" }, old: original?.prune.map { $0 ? "true" : "false" })
        set(GitRemotes.sshKeyVariable, edited.sshKey, old: original?.sshKey)
        if makePushDefault, currentPushDefault != name {
            commands.append((["config", "remote.pushDefault", name], false))
        } else if !makePushDefault, let currentPushDefault, currentPushDefault == (original?.name ?? name) {
            commands.append((["config", "--unset", "remote.pushDefault"], true))
        }
        return commands
    }

    @objc private func removeClicked() {
        guard let remote = selectedSavedRemote, let window = view.window else { return }
        let confirm = NSAlert()
        confirm.messageText = "Remove remote “\(remote.name)”?"
        confirm.informativeText = "Its remote-tracking branches and configuration are deleted. Nothing changes on the server."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        confirm.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                do {
                    try await GitCLIRunner.runAsync(arguments: ["remote", "remove", remote.name], workingDirectory: self.repositoryPath)
                    self.reload()
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @objc private func fetchClicked() {
        guard let remote = selectedSavedRemote else { return }
        let env = remote.sshKey.isEmpty ? nil : GitRemotes.sshEnvironment(keyPath: remote.sshKey)
        ProgressWindowController.run(title: "Fetch \(remote.name)", commands: [["fetch", "--progress", remote.name]],
                                     workingDirectory: repositoryPath, environment: env)
    }

    @objc private func pruneClicked() {
        guard let remote = selectedSavedRemote else { return }
        let env = remote.sshKey.isEmpty ? nil : GitRemotes.sshEnvironment(keyPath: remote.sshKey)
        ProgressWindowController.run(title: "Prune \(remote.name)", commands: [["remote", "prune", remote.name]],
                                     workingDirectory: repositoryPath, environment: env)
    }

    @objc private func deleteTagsClicked() {
        guard let remote = selectedSavedRemote else { return }
        let root = repositoryPath
        WindowRegistry.shared.present({ DeleteRemoteTagsWindowController(repositoryPath: root, remote: remote.name) },
                                      key: "deleteremotetags|\(root.rawPath)|\(remote.name)", repository: root)
    }

    @objc private func browseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose the private key (not the .pub file)"
        if panel.runModal() == .OK, let url = panel.url {
            sshKeyField.stringValue = url.path
        }
    }

    /// `ssh-add --apple-use-keychain <key>`: the macOS route for TortoiseGit's Pageant autoload (DA-02).
    @objc private func addKeyToAgent() {
        let key = (sshKeyField.stringValue as NSString).expandingTildeInPath
        guard !key.isEmpty, FileManager.default.fileExists(atPath: key) else {
            statusLabel.stringValue = "Choose an existing private key first."
            NSSound.beep()
            return
        }
        statusLabel.stringValue = "Adding \((key as NSString).lastPathComponent) to the SSH agent…"
        Task { @MainActor in
            let (status, output) = await Self.runSSHAdd(key: key)
            self.statusLabel.stringValue = status == 0
                ? "Key added to the agent; its passphrase is stored in the Keychain."
                : "ssh-add failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    private static func runSSHAdd(key: String) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
                process.arguments = ["--apple-use-keychain", key]
                var env = ProcessInfo.processInfo.environment
                if let askPass = AskPassHelper.helperExecutablePath {
                    env.merge(AskPassHelper.askPassEnvironment(helperPath: askPass, credentialPrompt: false)) { _, new in new }
                }
                process.environment = env
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                }
            }
        }
    }

    @objc private func editSSHConfig() {
        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let config = sshDir.appendingPathComponent("config")
        if !FileManager.default.fileExists(atPath: config.path) {
            try? FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let template = "# Host aliases for git, e.g.\n# Host work\n#     HostName github.com\n#     User git\n#     IdentityFile ~/.ssh/id_work\n#     UseKeychain yes\n#     AddKeysToAgent yes\n"
            FileManager.default.createFile(atPath: config.path, contents: Data(template.utf8), attributes: [.posixPermissions: 0o600])
        }
        TextFileOpener.open(config)
    }
}

/// Opens a plain-text file (git or ssh config) in the user's default text editor, falling back
/// to TextEdit: such files have no extension that maps to an editor.
@MainActor
enum TextFileOpener {
    static func open(_ url: URL) {
        let editor = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }
}
