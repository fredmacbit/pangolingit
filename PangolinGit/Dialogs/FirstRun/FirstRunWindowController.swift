import Foundation
import Cocoa
import FinderSync
import PangolinGitCore

/// First-start wizard (TortoiseGit's `CFirstStartWizard`): language, git executable with a version
/// check and extra PATH, identity (optionally not stored yet), authentication (credential helper and
/// SSH key), then Finder integration. Closing the window early keeps the defaults and does not show
/// the wizard again; it can be re-run from Settings ▸ General.
public final class FirstRunWindowController: NSWindowController, NSWindowDelegate {

    private enum Page: Int, CaseIterable {
        case welcome, git, identity, authentication, finder
    }

    private var page = Page.welcome
    private var finished = false

    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let containerView = NSView()
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)

    // Values kept across pages.
    private let languagePopup = NSPopUpButton()
    private let gitPathField = NSTextField()
    private let gitVersionLabel = NSTextField(labelWithString: "")
    private let extraPathField = NSTextField()
    private let userNameField = NSTextField()
    private let userEmailField = NSTextField()
    private let dontStoreIdentity = NSButton(checkboxWithTitle: "Don't store the identity now", target: nil, action: nil)
    private let credentialPopup = NSPopUpButton()
    private let sshStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let finderStatusLabel = NSTextField(wrappingLabelWithString: "")
    private var identityLoaded = false

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to PangolinGit"
        super.init(window: window)
        window.delegate = self
        setupUI()
        prepareControls()
        show(.welcome)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func setupUI() {
        guard let root = window?.contentView else { return }
        let icon = NSImageView(image: NSApp.applicationIconImage)
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        descriptionLabel.textColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(backClicked)
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        nextButton.keyEquivalent = "\r"
        for button in [backButton, nextButton] { button.bezelStyle = .rounded }
        let header = NSStackView(views: [titleLabel, descriptionLabel])
        header.orientation = .vertical
        header.alignment = .leading
        let buttons = NSStackView(views: [backButton, nextButton])

        for view in [icon, header, containerView, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            header.topAnchor.constraint(equalTo: icon.topAnchor),
            header.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            descriptionLabel.widthAnchor.constraint(equalTo: header.widthAnchor),
            containerView.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 24),
            containerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            containerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            containerView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
    }

    private func prepareControls() {
        let config = ConfigManager.shared
        languagePopup.addItem(withTitle: "System default")
        for code in Bundle.main.localizations.filter({ $0 != "Base" }).sorted() {
            languagePopup.addItem(withTitle: Locale.current.localizedString(forIdentifier: code) ?? code)
            languagePopup.lastItem?.representedObject = code
        }
        gitPathField.stringValue = config.gitExecutablePath
        gitPathField.placeholderString = GitCLIRunner.resolveGitExecutable()
        gitVersionLabel.textColor = .secondaryLabelColor
        gitPathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        userNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        extraPathField.stringValue = config.extraPath
        extraPathField.placeholderString = "Optional, e.g. /opt/tools/bin"
        userNameField.placeholderString = "Jane Doe"
        userEmailField.placeholderString = "jane@example.com"
        dontStoreIdentity.toolTip = "Leave user.name / user.email unset; git asks for them on the first commit."
        for (title, value) in [("macOS Keychain (osxkeychain) — recommended", "osxkeychain"),
                               ("Git Credential Manager (manager)", "manager"),
                               ("Remember in memory for 15 minutes (cache)", "cache"),
                               ("Plain-text file (store)", "store"),
                               ("Don't change", "")] {
            credentialPopup.addItem(withTitle: title)
            credentialPopup.lastItem?.representedObject = value
        }
        credentialPopup.toolTip = "Where git keeps HTTPS passwords and tokens (git config --global credential.helper)."
    }

    private func show(_ newPage: Page) {
        page = newPage
        containerView.subviews.forEach { $0.removeFromSuperview() }
        backButton.isEnabled = page != .welcome
        nextButton.title = page == .finder ? "Finish" : "Next"

        let content: NSView
        switch page {
        case .welcome:
            titleLabel.stringValue = "Welcome to PangolinGit"
            descriptionLabel.stringValue = "Git in the Finder: status badges, context menus and the TortoiseGit dialogs on macOS."
            let text = NSTextField(wrappingLabelWithString: "This wizard checks your git installation, sets your commit identity, "
                + "configures how git authenticates and enables the Finder extension. You can run it again from Settings ▸ General.")
            content = form([[text], [label("Language:"), languagePopup]])
        case .git:
            titleLabel.stringValue = "Git"
            descriptionLabel.stringValue = "PangolinGit uses the git command line. Leave the path empty to detect it automatically."
            let detect = button("Auto Detect", #selector(autoDetectGit))
            let check = button("Check Now", #selector(checkGit))
            let pathRow = NSStackView(views: [gitPathField, detect, check])
            let hint = NSTextField(wrappingLabelWithString: "No git yet? Install the Xcode Command Line Tools (xcode-select --install) or Homebrew git.")
            hint.textColor = .secondaryLabelColor
            content = form([[label("Git executable:"), pathRow], [NSGridCell.emptyContentView, gitVersionLabel],
                            [label("Extra PATH:"), extraPathField], [NSGridCell.emptyContentView, hint]])
            checkGit()
        case .identity:
            titleLabel.stringValue = "Your Identity"
            descriptionLabel.stringValue = "Name and e-mail recorded in your commits (git config --global user.name / user.email)."
            content = form([[label("Name:"), userNameField], [label("E-mail:"), userEmailField],
                            [NSGridCell.emptyContentView, dontStoreIdentity]])
            loadIdentity()
        case .authentication:
            titleLabel.stringValue = "Authentication"
            descriptionLabel.stringValue = "How git signs in to servers: a credential helper for HTTPS, SSH keys for ssh:// and git@ URLs."
            let sshButton = button("Manage SSH Keys…", #selector(openSSH))
            sshStatusLabel.textColor = .secondaryLabelColor
            content = form([[label("HTTPS credentials:"), credentialPopup],
                            [label("SSH:"), sshStatusLabel], [NSGridCell.emptyContentView, sshButton]])
            loadAuthentication()
        case .finder:
            titleLabel.stringValue = "Finder Integration"
            descriptionLabel.stringValue = "Badges and context menus come from a Finder extension that macOS asks you to enable once."
            let open = button("Open System Settings…", #selector(openExtensionsSettings))
            content = form([[finderStatusLabel], [open]])
            updateFinderStatus()
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: containerView.topAnchor),
            content.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor)
        ])
    }

    private func form(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        for (index, row) in rows.enumerated() where row.count == 1 {
            grid.row(at: index).mergeCells(in: NSRange(location: 0, length: grid.numberOfColumns))
            grid.cell(atColumnIndex: 0, rowIndex: index).xPlacement = .leading
        }
        return grid
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    // MARK: - Page logic (all git calls off the main thread)

    @objc private func autoDetectGit() {
        // Show what would be found without the configured path; nothing is saved until Next.
        let saved = ConfigManager.shared.gitExecutablePath
        ConfigManager.shared.gitExecutablePath = ""
        gitPathField.stringValue = GitCLIRunner.resolveGitExecutable()
        ConfigManager.shared.gitExecutablePath = saved
        checkGit()
    }

    @objc private func checkGit() {
        let typed = gitPathField.stringValue.trimmingCharacters(in: .whitespaces)
        let runner = GitCLIRunner(executablePath: typed.isEmpty ? nil : typed)
        gitVersionLabel.stringValue = "Checking…"
        gitVersionLabel.textColor = .secondaryLabelColor
        Task { @MainActor in
            if let result = try? await runner.run(arguments: ["--version"]), result.isSuccess {
                gitVersionLabel.stringValue = "✓ " + result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                gitVersionLabel.textColor = .systemGreen
            } else {
                gitVersionLabel.stringValue = "✗ No working git at \(runner.executablePath)"
                gitVersionLabel.textColor = .systemRed
            }
        }
    }

    private func loadIdentity() {
        guard !identityLoaded else { return }
        identityLoaded = true
        Task { @MainActor in
            let store = GitConfigStore(repository: nil)
            let values = await store.values(in: .global)
            if userNameField.stringValue.isEmpty { userNameField.stringValue = values["user.name"] ?? "" }
            if userEmailField.stringValue.isEmpty { userEmailField.stringValue = values["user.email"] ?? "" }
        }
    }

    private func loadAuthentication() {
        Task { @MainActor in
            let helper = await GitConfigStore(repository: nil).value("credential.helper", in: .global)
                ?? ConfigManager.shared.credentialHelper
            let index = credentialPopup.itemArray.firstIndex { ($0.representedObject as? String) == helper } ?? 0
            credentialPopup.selectItem(at: index)
        }
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        let keys = ((try? FileManager.default.contentsOfDirectory(atPath: ssh.path)) ?? []).filter { $0.hasSuffix(".pub") }
        sshStatusLabel.stringValue = keys.isEmpty
            ? "No SSH key found. Generate one if your server uses SSH."
            : "Found: " + keys.map { String($0.dropLast(4)) }.joined(separator: ", ")
    }

    private func updateFinderStatus() {
        finderStatusLabel.stringValue = ExtensionHelper.shared.isFinderExtensionEnabled
            ? "✓ The Finder extension is enabled."
            : "Enable “PangolinGit” under System Settings ▸ General ▸ Login Items & Extensions ▸ Finder extensions (or Privacy & Security ▸ Extensions ▸ Added Extensions on older macOS)."
    }

    @objc private func openSSH() {
        CommandRouter.shared.execute(command: .ssh, paths: [])
    }

    @objc private func openExtensionsSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    @objc private func backClicked() {
        if let previous = Page(rawValue: page.rawValue - 1) { show(previous) }
    }

    @objc private func nextClicked() {
        commit(page)
        if let next = Page(rawValue: page.rawValue + 1) {
            show(next)
        } else {
            finish()
            close()
        }
    }

    /// Applies the choices of a page when the user leaves it forward.
    private func commit(_ page: Page) {
        switch page {
        case .welcome:
            if let code = languagePopup.selectedItem?.representedObject as? String {
                UserDefaults.standard.set([code], forKey: "AppleLanguages")
            }
        case .git:
            ConfigManager.shared.gitExecutablePath = gitPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            ConfigManager.shared.extraPath = extraPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .identity:
            guard dontStoreIdentity.state == .off else { return }
            let name = userNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = userEmailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                let store = GitConfigStore(repository: nil)
                if !name.isEmpty { try? await store.set("user.name", to: name, in: .global) }
                if !email.isEmpty { try? await store.set("user.email", to: email, in: .global) }
            }
        case .authentication:
            guard let helper = credentialPopup.selectedItem?.representedObject as? String, !helper.isEmpty else { return }
            ConfigManager.shared.credentialHelper = helper
            Task { try? await GitConfigStore(repository: nil).set("credential.helper", to: helper, in: .global) }
        case .finder:
            break
        }
    }

    /// Marks the wizard done and registers the Finder extension and agent (also when closed early).
    private func finish() {
        guard !finished else { return }
        finished = true
        ConfigManager.shared.hasCompletedFirstRun = true
        ExtensionHelper.shared.registerServices()
    }

    public func windowWillClose(_ notification: Notification) {
        finish()
    }
}
