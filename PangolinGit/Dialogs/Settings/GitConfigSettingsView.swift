import Cocoa
import PangolinGitCore

/// Chooser for the repository a per-repository settings pane edits (the Settings window is global,
/// TortoiseGit opens it from a working tree). Lists the recent repositories that still exist.
@MainActor
final class SettingsRepositoryPopup: NSPopUpButton {

    /// Called with the chosen repository, or nil for "Global".
    var onChange: ((PangolinPath?) -> Void)?
    private var paths: [String] = []
    private let includesGlobal: Bool

    init(includesGlobal: Bool) {
        self.includesGlobal = includesGlobal
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(changed)
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selectedRepository: PangolinPath? {
        let index = indexOfSelectedItem - (includesGlobal ? 1 : 0)
        return index >= 0 && index < paths.count ? PangolinPath(paths[index]) : nil
    }

    private func rebuild() {
        removeAllItems()
        if includesGlobal { addItem(withTitle: "Global (all repositories)") }
        paths = ConfigManager.shared.recentRepositories.filter {
            FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git"))
        }
        for path in paths {
            addItem(withTitle: "\((path as NSString).lastPathComponent) — \((path as NSString).deletingLastPathComponent)")
        }
        menu?.addItem(.separator())
        menu?.addItem(ClosureMenuItem(title: "Choose Repository…") { [weak self] in self?.chooseRepository() })
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a Git working tree"
        guard panel.runModal() == .OK, let url = panel.url,
              let root = GitAdminDir.findRepository(startingAt: PangolinPath(url.path))?.workingTreeRoot else {
            selectItem(at: 0)
            changed()
            return
        }
        ConfigManager.shared.addRecentRepository(root.rawPath)
        rebuild()
        if let index = paths.firstIndex(of: root.rawPath) { selectItem(at: index + (includesGlobal ? 1 : 0)) }
        changed()
    }

    @objc private func changed() {
        onChange?(selectedRepository)
    }
}

/// Settings ▸ Git, TortoiseGit's Git page (`SettingGitConfig.cpp`): identity, signing key, line
/// endings, quoting and prune at global or repository level, with an empty field / "Inherit" meaning
/// "not set here", and buttons to open each config file in an editor (SE-09).
public final class GitConfigSettingsViewController: NSViewController, NSTextFieldDelegate {

    private struct Choice {
        let key: String
        let values: [String]
    }

    private let scopePopup = SettingsRepositoryPopup(includesGlobal: true)
    private var repository: PangolinPath?
    private let nameField = NSTextField()
    private let emailField = NSTextField()
    private let signingKeyField = NSTextField()
    private lazy var textFields: [String: NSTextField] = [
        "user.name": nameField, "user.email": emailField, "user.signingkey": signingKeyField,
    ]
    private let choices: [Choice] = [
        Choice(key: "core.autocrlf", values: ["true", "input", "false"]),
        Choice(key: "core.safecrlf", values: ["true", "warn", "false"]),
        Choice(key: "core.quotepath", values: ["true", "false"]),
        Choice(key: "fetch.prune", values: ["true", "false"]),
    ]
    private var choicePopups: [String: NSPopUpButton] = [:]
    private let statusLabel = NSTextField(labelWithString: "")
    private var repositoryButtons: [NSButton] = []
    private let systemButton = NSButton(title: "System", target: nil, action: nil)

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 420))
        setupUI()
        repository = scopePopup.selectedRepository
        load()
    }

    private func setupUI() {
        scopePopup.onChange = { [weak self] repo in
            self?.repository = repo
            self?.load()
        }
        for field in textFields.values {
            field.delegate = self
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        var rows: [[NSView?]] = [
            [RemoteDialogSupport.label("Settings for:"), scopePopup],
            [RemoteDialogSupport.label("Name:"), nameField],
            [RemoteDialogSupport.label("Email:"), emailField],
            [RemoteDialogSupport.label("Signing key:"), signingKeyField],
        ]
        let titles = ["core.autocrlf": "AutoCrLf:", "core.safecrlf": "SafeCrLf:", "core.quotepath": "Quote paths:", "fetch.prune": "Prune on fetch:"]
        for choice in choices {
            let popup = NSPopUpButton()
            popup.addItem(withTitle: "Inherit")
            popup.addItems(withTitles: choice.values)
            popup.target = self
            popup.action = #selector(choiceChanged(_:))
            popup.identifier = NSUserInterfaceItemIdentifier(choice.key)
            choicePopups[choice.key] = popup
            rows.append([RemoteDialogSupport.label(titles[choice.key] ?? choice.key), popup])
        }

        let local = NSButton(title: "Repository (.git/config)", target: self, action: #selector(editLocal))
        let tgit = NSButton(title: "Project (.tgitconfig)", target: self, action: #selector(editProject))
        repositoryButtons = [local, tgit]
        let global = NSButton(title: "Global (~/.gitconfig)", target: self, action: #selector(editGlobal))
        let xdg = NSButton(title: "XDG (~/.config/git/config)", target: self, action: #selector(editXDG))
        systemButton.target = self
        systemButton.action = #selector(editSystem)
        let effective = NSButton(title: "View Effective Config…", target: self, action: #selector(viewEffective))
        rows.append([RemoteDialogSupport.label("Edit:"), RemoteDialogSupport.vStack([
            RemoteDialogSupport.hStack([local, tgit]),
            RemoteDialogSupport.hStack([global, xdg, systemButton]),
            effective,
        ])])
        let grid = RemoteDialogSupport.grid(rows)
        let hint = NSTextField(wrappingLabelWithString: "An empty field or “Inherit” leaves the value unset at this level; the placeholder shows the value that applies.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let content = RemoteDialogSupport.vStack([grid, hint, statusLabel], spacing: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    /// `--global` or `--local`, and the directory git runs in.
    private var scopeFlag: String { repository == nil ? "--global" : "--local" }

    private func value(_ key: String, flag: String?) async -> String? {
        var args = ["config"]
        if let flag { args.append(flag) }
        args += ["--get", key]
        let output = try? await GitCLIRunner.runAsync(arguments: args, workingDirectory: repository)
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func load() {
        repositoryButtons.forEach { $0.isEnabled = repository != nil }
        Task { @MainActor in
            for (key, field) in self.textFields {
                field.stringValue = await self.value(key, flag: self.scopeFlag) ?? ""
                let inherited = await self.inheritedValue(key)
                field.placeholderString = inherited.map { "Inherit: \($0)" } ?? "Not set"
            }
            for choice in self.choices {
                guard let popup = self.choicePopups[choice.key] else { continue }
                let current = await self.value(choice.key, flag: self.scopeFlag)
                let inherited = await self.inheritedValue(choice.key)
                popup.item(at: 0)?.title = "Inherit" + (inherited.map { " (\($0))" } ?? "")
                if let current, let index = choice.values.firstIndex(of: current.lowercased()) {
                    popup.selectItem(at: index + 1)
                } else {
                    popup.selectItem(at: 0)
                }
            }
            self.systemButton.isEnabled = await Self.systemConfigPath() != nil
            self.statusLabel.stringValue = self.repository.map { "Editing \($0.rawPath)/.git/config" } ?? "Editing ~/.gitconfig"
        }
    }

    /// The value that applies when this level leaves the key unset.
    private func inheritedValue(_ key: String) async -> String? {
        if repository != nil {
            if let global = await value(key, flag: "--global") { return global }
        }
        if let xdg = await value(key, flag: "--file=\(Self.xdgConfigPath)") { return xdg }
        return await value(key, flag: "--system")
    }

    private func write(_ key: String, _ newValue: String?) {
        let args = newValue.map { ["config", scopeFlag, key, $0] } ?? ["config", scopeFlag, "--unset", key]
        Task { @MainActor in
            let result = try? await GitCLIRunner().run(arguments: args, workingDirectory: self.repository)
            // --unset exits 5 when the key was not set: nothing to do.
            if let result, result.isSuccess || (newValue == nil && result.exitCode == 5) {
                self.statusLabel.stringValue = newValue.map { "Set \(key) = \($0)" } ?? "Unset \(key)"
            } else {
                self.statusLabel.stringValue = "Could not write \(key): \(result?.standardError.trimmingCharacters(in: .whitespacesAndNewlines) ?? "git failed")"
            }
            if let repository = self.repository { RepositoryEvents.post(repository) }
        }
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let key = textFields.first(where: { $0.value === field })?.key else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        write(key, text.isEmpty ? nil : text)
    }

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue else { return }
        write(key, sender.indexOfSelectedItem == 0 ? nil : sender.titleOfSelectedItem)
    }

    // MARK: - Config files

    static var xdgConfigPath: String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (base as NSString).appendingPathComponent("git/config")
    }

    /// The system-level gitconfig of the git in use (`git config --system --list --show-origin`).
    static func systemConfigPath() async -> String? {
        let output = (try? await GitCLIRunner.runAsync(arguments: ["config", "--system", "--list", "--show-origin"])) ?? ""
        guard let first = output.split(separator: "\n").first, first.hasPrefix("file:") else { return nil }
        return String(first.dropFirst(5).prefix { $0 != "\t" })
    }

    /// Opens `path`, creating it (and its folder) first so the editor has something to open.
    private func openConfig(_ path: String, template: String = "") {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data(template.utf8))
        }
        TextFileOpener.open(url)
    }

    @objc private func editLocal() {
        guard let repository else { return }
        Task { @MainActor in
            let gitPath = (try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "--git-path", "config"], workingDirectory: repository))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ".git/config"
            let full = gitPath.hasPrefix("/") ? gitPath : repository.appending(gitPath).rawPath
            self.openConfig(full)
        }
    }

    @objc private func editProject() {
        guard let repository else { return }
        openConfig(repository.appending(".tgitconfig").rawPath,
                   template: "# Project settings shared through the repository (TortoiseGit's .tgitconfig)\n")
    }

    @objc private func editGlobal() {
        openConfig((NSHomeDirectory() as NSString).appendingPathComponent(".gitconfig"))
    }

    @objc private func editXDG() {
        openConfig(Self.xdgConfigPath)
    }

    @objc private func editSystem() {
        Task { @MainActor in
            if let path = await Self.systemConfigPath() { TextFileOpener.open(URL(fileURLWithPath: path)) }
        }
    }

    @objc private func viewEffective() {
        let repository = self.repository
        Task { @MainActor in
            let output = (try? await GitCLIRunner.runAsync(arguments: ["config", "--list", "--show-scope", "--show-origin"],
                                                           workingDirectory: repository)) ?? "git config failed"
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.string = output
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            scroll.documentView = textView
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            let alert = NSAlert()
            alert.messageText = "Effective Git configuration"
            alert.informativeText = repository.map { "In \($0.rawPath)" } ?? "Outside any repository"
            alert.accessoryView = scroll
            if let window = self.view.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }
}

/// Settings ▸ Remote: the remote editor for a chosen repository (TortoiseGit's Settings ▸ Git ▸
/// Remote page, SE-10).
public final class RemoteSettingsViewController: NSViewController {

    private let repositoryPopup = SettingsRepositoryPopup(includesGlobal: false)
    private let container = NSView()
    private let emptyLabel = NSTextField(labelWithString: "Open a repository once (or choose one above) to edit its remotes.")
    private var editor: RemotesEditorViewController?

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 440))
        let header = RemoteDialogSupport.hStack([NSTextField(labelWithString: "Repository:"), repositoryPopup])
        header.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(container)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            container.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 700),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        repositoryPopup.onChange = { [weak self] repo in self?.show(repo) }
        show(repositoryPopup.selectedRepository)
    }

    private func show(_ repository: PangolinPath?) {
        editor?.view.removeFromSuperview()
        editor?.removeFromParent()
        editor = nil
        emptyLabel.isHidden = repository != nil
        guard let repository else { return }
        let editor = RemotesEditorViewController(repositoryPath: repository)
        addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editor.view)
        NSLayoutConstraint.activate([
            editor.view.topAnchor.constraint(equalTo: container.topAnchor),
            editor.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editor.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.editor = editor
    }
}
