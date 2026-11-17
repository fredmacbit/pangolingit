import Foundation
import Cocoa
import PangolinGitCore

/// SSH key management, the macOS counterpart of TortoiseGit's PuTTYgen / Pageant integration:
/// keys in ~/.ssh with type, size and fingerprint; generation (Ed25519/ECDSA/RSA) with the passphrase
/// passed through `SSH_ASKPASS`, never on the command line; import and delete; adding a key to the
/// agent with the passphrase stored in the Keychain; pinning a key to a repository through
/// `core.sshCommand` (TortoiseGit's per-remote PuTTY key); ~/.ssh/config and known_hosts management.
public final class SSHKeyWindowController: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {

    public struct SSHKeyInfo {
        public let name: String
        public let privateKeyPath: String
        public let publicKeyPath: String
        public let keyType: String
        public let publicKeyContent: String
        public var bits: String = ""
        public var fingerprint: String = ""
        public var inAgent = false
    }

    private var keys: [SSHKeyInfo] = []
    private let tableView = NSTableView()
    private let pubKeyTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private var selectionButtons: [NSButton] = []

    private var sshDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SSH Keys"
        window.minSize = NSSize(width: 720, height: 420)
        super.init(window: window)
        setupUI()
        loadSSHKeys()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI

    private func setupUI() {
        guard let content = window?.contentView else { return }

        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        for (identifier, title, width) in [("Name", "Key", 150.0), ("Type", "Type", 90.0), ("Bits", "Bits", 50.0),
                                           ("Fingerprint", "Fingerprint", 330.0), ("Agent", "In agent", 70.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.delegate = self
        tableView.dataSource = self
        tableScroll.documentView = tableView

        let pubScroll = NSScrollView()
        pubScroll.hasVerticalScroller = true
        pubScroll.borderType = .bezelBorder
        pubKeyTextView.isEditable = false
        pubKeyTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pubKeyTextView.autoresizingMask = [.width]
        pubScroll.documentView = pubKeyTextView

        func button(_ title: String, _ action: Selector, _ tip: String, needsSelection: Bool = false) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.toolTip = tip
            if needsSelection { selectionButtons.append(button) }
            return button
        }
        let keyButtons = NSStackView(views: [
            button("Generate…", #selector(generateKeyClicked), "Create a new key pair in ~/.ssh."),
            button("Import…", #selector(importKeyClicked), "Copy an existing private key into ~/.ssh (permissions 600)."),
            button("Delete…", #selector(deleteKeyClicked), "Move the selected key pair to the Trash.", needsSelection: true),
            button("Copy Public Key", #selector(copyPublicKeyClicked), "Copy the public key, e.g. to paste into GitHub/GitLab.", needsSelection: true),
            button("Add to Agent", #selector(addToAgentClicked),
                   "Load the key into ssh-agent and store its passphrase in the Keychain (ssh-add --apple-use-keychain).", needsSelection: true),
            button("Use for Repository…", #selector(useForRepositoryClicked),
                   "Make git use this key for a repository or globally (core.sshCommand).", needsSelection: true)
        ])
        keyButtons.spacing = 6
        let otherButtons = NSStackView(views: [
            button("Edit ~/.ssh/config", #selector(editConfigClicked), "Open the SSH client configuration (host aliases, IdentityFile, UseKeychain)."),
            button("Known Hosts…", #selector(knownHostsClicked), "Review and remove entries of ~/.ssh/known_hosts."),
            button("Test Connection…", #selector(testConnectionClicked), "Try to log in to a git host with ssh -T."),
            NSView(),
            button("Close", #selector(closeClicked), "")
        ])
        otherButtons.spacing = 6
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        for view in [tableScroll, pubScroll, keyButtons, otherButtons, statusLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tableScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tableScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            tableScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),

            pubScroll.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: 10),
            pubScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            pubScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            pubScroll.heightAnchor.constraint(equalToConstant: 90),

            keyButtons.topAnchor.constraint(equalTo: pubScroll.bottomAnchor, constant: 10),
            keyButtons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            keyButtons.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            otherButtons.topAnchor.constraint(equalTo: keyButtons.bottomAnchor, constant: 8),
            otherButtons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            otherButtons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: otherButtons.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        updateButtons()
    }

    private func updateButtons() {
        let hasSelection = selectedKey != nil
        selectionButtons.forEach { $0.isEnabled = hasSelection }
    }

    private var selectedKey: SSHKeyInfo? {
        let row = tableView.selectedRow
        return row >= 0 && row < keys.count ? keys[row] : nil
    }

    // MARK: - Loading

    private func loadSSHKeys() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sshDirectory.path) else {
            keys = []
            tableView.reloadData()
            statusLabel.stringValue = "No ~/.ssh folder yet — generate a key to create it."
            return
        }
        var loaded: [SSHKeyInfo] = []
        for pub in files.filter({ $0.hasSuffix(".pub") }).sorted() {
            let baseName = String(pub.dropLast(".pub".count))
            let pubPath = sshDirectory.appendingPathComponent(pub).path
            guard let content = try? String(contentsOfFile: pubPath, encoding: .utf8) else { continue }
            loaded.append(SSHKeyInfo(name: baseName,
                                     privateKeyPath: sshDirectory.appendingPathComponent(baseName).path,
                                     publicKeyPath: pubPath,
                                     keyType: content.split(separator: " ").first.map(String.init) ?? "?",
                                     publicKeyContent: content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let previous = selectedKey?.name
        keys = loaded
        tableView.reloadData()
        if let index = keys.firstIndex(where: { $0.name == previous }) ?? (keys.isEmpty ? nil : 0) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        statusLabel.stringValue = "\(loaded.count) SSH key(s) in ~/.ssh"
        loadFingerprints()
    }

    /// `ssh-keygen -lf` for every key and `ssh-add -l` for the agent state, off the main thread.
    private func loadFingerprints() {
        let snapshot = keys
        Task.detached {
            let agent = Self.runTool("/usr/bin/ssh-add", ["-l"]).output
            var updated = snapshot
            for index in updated.indices {
                // "256 SHA256:abc… comment (ED25519)"
                let line = Self.runTool("/usr/bin/ssh-keygen", ["-lf", updated[index].publicKeyPath]).output
                let fields = line.split(separator: " ")
                if fields.count >= 2 {
                    updated[index].bits = String(fields[0])
                    updated[index].fingerprint = String(fields[1])
                    updated[index].inAgent = agent.contains(String(fields[1]))
                }
            }
            let result = updated
            await MainActor.run {
                guard self.keys.map(\.name) == result.map(\.name) else { return }
                let selection = self.tableView.selectedRowIndexes
                self.keys = result
                self.tableView.reloadData()
                self.tableView.selectRowIndexes(selection, byExtendingSelection: false)
            }
        }
    }

    /// Runs a tool with optional extra environment; returns exit code and combined output.
    nonisolated static func runTool(_ path: String, _ arguments: [String], environment: [String: String] = [:]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Runs ssh-keygen / ssh-add answering passphrase prompts through a one-shot askpass helper.
    private func runWithPassphrase(_ tool: String, _ arguments: [String], passphrase: String, answers: Int = 1) async -> (status: Int32, output: String) {
        await Task.detached {
            do {
                let (environment, cleanup) = try SSHSupport.askPassEnvironment(secret: passphrase, answers: answers)
                defer { try? FileManager.default.removeItem(at: cleanup) }
                return Self.runTool(tool, arguments, environment: environment)
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SSH Key Error"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Generate / import / delete

    @objc private func generateKeyClicked() {
        let alert = NSAlert()
        alert.messageText = "Generate SSH Key"
        alert.informativeText = "The passphrase protects the private key; add the key to the agent afterwards so you only type it once."

        let typePopup = NSPopUpButton()
        SSHSupport.KeyType.allCases.forEach { typePopup.addItem(withTitle: $0.title) }
        let preferred = SSHSupport.KeyType(rawValue: ConfigManager.shared.advancedString(.sshKeygenDefaultType)) ?? .ed25519
        typePopup.selectItem(at: SSHSupport.KeyType.allCases.firstIndex(of: preferred) ?? 0)
        let bitsPopup = NSPopUpButton()
        let refreshBits = {
            let type = SSHSupport.KeyType.allCases[max(0, typePopup.indexOfSelectedItem)]
            bitsPopup.removeAllItems()
            bitsPopup.addItems(withTitles: type.bitSizes.map(String.init))
            bitsPopup.isEnabled = !type.bitSizes.isEmpty
            if type.bitSizes.isEmpty { bitsPopup.addItem(withTitle: "fixed") }
        }
        refreshBits()
        let typeHandler = PopupHandler(refreshBits)
        typePopup.target = typeHandler
        typePopup.action = #selector(PopupHandler.fire)

        let commentField = NSTextField()
        commentField.placeholderString = "you@example.com"
        let passField = NSSecureTextField()
        passField.placeholderString = "Passphrase (recommended)"
        let confirmField = NSSecureTextField()
        confirmField.placeholderString = "Confirm passphrase"

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Type:"), typePopup],
            [NSTextField(labelWithString: "Bits:"), bitsPopup],
            [NSTextField(labelWithString: "Comment:"), commentField],
            [NSTextField(labelWithString: "Passphrase:"), passField],
            [NSTextField(labelWithString: "Confirm:"), confirmField]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.frame = NSRect(x: 0, y: 0, width: 340, height: 150)
        commentField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        alert.accessoryView = grid
        alert.addButton(withTitle: "Generate…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = typeHandler

        let type = SSHSupport.KeyType.allCases[max(0, typePopup.indexOfSelectedItem)]
        let bits = Int(bitsPopup.titleOfSelectedItem ?? "")
        let passphrase = passField.stringValue
        guard passphrase == confirmField.stringValue else {
            showError("The passphrases do not match.")
            return
        }

        try? FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let panel = NSSavePanel()
        panel.title = "Save Private Key"
        panel.directoryURL = sshDirectory
        panel.nameFieldStringValue = type.defaultFileName
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let keyURL = panel.url else { return }
        let keyPath = keyURL.path
        let pubPath = keyPath + ".pub"

        // The save panel already confirmed replacing the file; ssh-keygen would ask again on stdin.
        let fm = FileManager.default
        for path in [keyPath, pubPath] where fm.fileExists(atPath: path) {
            do { try fm.removeItem(atPath: path) } catch {
                showError("Could not remove the existing key: \(error.localizedDescription)")
                return
            }
        }

        let comment = commentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = SSHSupport.keygenArguments(type: type, bits: bits, comment: comment.isEmpty ? NSUserName() : comment, path: keyPath)
        statusLabel.stringValue = "Generating \(type.rawValue) key…"
        Task {
            let result = await runWithPassphrase("/usr/bin/ssh-keygen", arguments, passphrase: passphrase, answers: 2)
            loadSSHKeys()
            if result.status != 0 {
                statusLabel.stringValue = "Key generation failed."
                showError(result.output.isEmpty ? "ssh-keygen exited with status \(result.status)" : result.output)
            } else {
                statusLabel.stringValue = "Created \(keyURL.lastPathComponent). Copy the public key to your git host."
            }
        }
    }

    @objc private func importKeyClicked() {
        let panel = NSOpenPanel()
        panel.message = "Choose a private key to copy into ~/.ssh"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = sshDirectory.appendingPathComponent(source.lastPathComponent)
        do {
            if destination.standardizedFileURL != source.standardizedFileURL {
                guard !fm.fileExists(atPath: destination.path) else {
                    showError("~/.ssh/\(destination.lastPathComponent) already exists.")
                    return
                }
                try fm.copyItem(at: source, to: destination)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let pub = destination.path + ".pub"
            let sourcePub = source.path + ".pub"
            if !fm.fileExists(atPath: pub) {
                if fm.fileExists(atPath: sourcePub) {
                    try fm.copyItem(atPath: sourcePub, toPath: pub)
                } else {
                    // Derive the public key; prompts for the passphrase if the key has one.
                    let passphrase = askPassphrase(for: destination.lastPathComponent) ?? ""
                    Task {
                        let result = await runWithPassphrase("/usr/bin/ssh-keygen", ["-y", "-f", destination.path], passphrase: passphrase)
                        if result.status == 0 {
                            try? result.output.write(toFile: pub, atomically: true, encoding: .utf8)
                        } else {
                            showError("The public key could not be derived: \(result.output)")
                        }
                        loadSSHKeys()
                    }
                    return
                }
            }
            loadSSHKeys()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func deleteKeyClicked() {
        guard let key = selectedKey else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(key.name)”?"
        alert.informativeText = "The private and public key files are moved to the Trash. Hosts that only know this key will refuse you."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for path in [key.privateKeyPath, key.publicKeyPath] where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                showError(error.localizedDescription)
            }
        }
        loadSSHKeys()
    }

    // MARK: - Agent and repositories

    private func askPassphrase(for name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Passphrase for “\(name)”"
        alert.informativeText = "Leave empty if the key has no passphrase."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// `ssh-add --apple-use-keychain`: the agent gets the key and the Keychain the passphrase, so git
    /// never prompts again (TortoiseGit's "Autoload Putty Key" into Pageant).
    @objc private func addToAgentClicked() {
        guard let key = selectedKey, let passphrase = askPassphrase(for: key.name) else { return }
        statusLabel.stringValue = "Adding \(key.name) to the agent…"
        Task {
            let result = await runWithPassphrase("/usr/bin/ssh-add", ["--apple-use-keychain", key.privateKeyPath], passphrase: passphrase)
            statusLabel.stringValue = result.status == 0 ? "\(key.name) added to the agent; passphrase stored in the Keychain." : "ssh-add failed."
            if result.status != 0 { showError(result.output) }
            loadFingerprints()
        }
    }

    /// Pins the key with `core.sshCommand` for one repository (or globally); "Clear" removes the setting.
    @objc private func useForRepositoryClicked() {
        guard let key = selectedKey else { return }
        let alert = NSAlert()
        alert.messageText = "Use “\(key.name)” for…"
        alert.informativeText = "Git then connects with: \(SSHSupport.sshCommand(forKey: key.privateKeyPath))"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        popup.addItem(withTitle: "All repositories (global)")
        var repositories = ConfigManager.shared.recentRepositories.filter { FileManager.default.fileExists(atPath: $0) }
        if let current = WindowRegistry.shared.currentRepository?.rawPath {
            repositories.removeAll { $0 == current }
            repositories.insert(current, at: 0)
        }
        for path in repositories {
            popup.addItem(withTitle: (path as NSString).abbreviatingWithTildeInPath)
            popup.lastItem?.representedObject = path
        }
        if repositories.count > 0 { popup.selectItem(at: 1) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use Key")
        alert.addButton(withTitle: "Clear Setting")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let repository = (popup.selectedItem?.representedObject as? String).map(PangolinPath.init)
        let scope: GitConfigScope = repository == nil ? .global : .local
        let value = response == .alertFirstButtonReturn ? SSHSupport.sshCommand(forKey: key.privateKeyPath) : nil
        Task {
            do {
                try await GitConfigStore(repository: repository).set("core.sshCommand", to: value, in: scope)
                let place = repository?.filename ?? "all repositories"
                statusLabel.stringValue = value == nil ? "core.sshCommand cleared for \(place)." : "\(key.name) is used for \(place)."
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    @objc private func editConfigClicked() {
        let fm = FileManager.default
        try? fm.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = sshDirectory.appendingPathComponent("config")
        if !fm.fileExists(atPath: config.path) {
            let template = """
            # SSH client configuration (man ssh_config). Example:
            # Host github.com
            #     IdentityFile ~/.ssh/id_ed25519
            #     AddKeysToAgent yes
            #     UseKeychain yes

            """
            fm.createFile(atPath: config.path, contents: Data(template.utf8), attributes: [.posixPermissions: 0o600])
        }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([config], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func knownHostsClicked() {
        WindowRegistry.shared.present({ KnownHostsWindowController() }, key: "knownhosts")
    }

    @objc private func copyPublicKeyClicked() {
        guard let key = selectedKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKeyContent, forType: .string)
        statusLabel.stringValue = "Copied the public key of “\(key.name)”."
    }

    @objc private func testConnectionClicked() {
        let alert = NSAlert()
        alert.messageText = "Test SSH Connection"
        alert.informativeText = "Host to log in to (git hosts answer with a greeting and close the session):"
        let hostField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        hostField.stringValue = "git@github.com"
        alert.accessoryView = hostField
        alert.addButton(withTitle: "Test")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        if let key = selectedKey { arguments += ["-o", "IdentityFile=\(key.privateKeyPath)"] }
        arguments.append(host)
        statusLabel.stringValue = "Connecting to \(host)…"
        // BatchMode: no password or host-key prompts can hang; unknown host keys are reported.
        Task.detached {
            let result = Self.runTool("/usr/bin/ssh", arguments)
            await MainActor.run {
                self.statusLabel.stringValue = "Test finished."
                let resultAlert = NSAlert()
                resultAlert.messageText = "SSH connection test"
                resultAlert.informativeText = result.output.isEmpty ? "(No response from host)" : result.output
                resultAlert.runModal()
            }
        }
    }

    @objc private func closeClicked() {
        window?.close()
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int { keys.count }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        pubKeyTextView.string = selectedKey?.publicKeyContent ?? ""
        updateButtons()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < keys.count else { return nil }
        let key = keys[row]
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingMiddle
        switch tableColumn?.identifier.rawValue ?? "" {
        case "Name":
            cell.stringValue = key.name
            cell.font = .boldSystemFont(ofSize: 12)
            cell.toolTip = key.privateKeyPath
        case "Type":
            cell.stringValue = key.keyType.replacingOccurrences(of: "ssh-", with: "")
        case "Bits":
            cell.stringValue = key.bits
        case "Fingerprint":
            cell.stringValue = key.fingerprint
            cell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.textColor = .secondaryLabelColor
        case "Agent":
            cell.stringValue = key.inAgent ? "✓" : ""
        default:
            break
        }
        return cell
    }
}

/// Keeps a popup's closure alive while a modal alert is shown.
private final class PopupHandler: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// ~/.ssh/known_hosts review: lists entries and removes the selected hosts with `ssh-keygen -R`.
final class KnownHostsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private var entries: [SSHSupport.KnownHost] = []
    private let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Known Hosts"
        super.init(window: window)
        setupUI()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for (identifier, title, width) in [("host", "Host", 330.0), ("type", "Key type", 160.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView
        let hint = NSTextField(wrappingLabelWithString: "Remove a host after its key legitimately changed; ssh asks to confirm the new key on the next connection.")
        hint.textColor = .secondaryLabelColor
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeClicked))
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [hint, remove, close])
        buttons.spacing = 8
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [scroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    private func reload() {
        entries = SSHSupport.parseKnownHosts((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue == "host" {
            cell.stringValue = entry.isHashed ? "(hashed entry, line \(entry.lineNumber))" : entry.hosts
            cell.toolTip = entry.hosts
        } else {
            cell.stringValue = entry.keyType
        }
        return cell
    }

    @objc private func removeClicked() {
        let selected = tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
        let hosts = selected.compactMap(\.primaryHost)
        if hosts.count < selected.count {
            let alert = NSAlert()
            alert.messageText = "Hashed entries cannot be removed by name"
            alert.informativeText = "Use ssh-keygen -R <host> in Terminal with the host name you connect to."
            alert.runModal()
        }
        for host in hosts {
            _ = SSHKeyWindowController.runTool("/usr/bin/ssh-keygen", ["-R", host, "-f", file.path])
        }
        reload()
    }

    @objc private func closeClicked() {
        close()
    }
}
