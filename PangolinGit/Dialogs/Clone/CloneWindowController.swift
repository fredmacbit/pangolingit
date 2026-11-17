import Cocoa
import PangolinGitCore

/// Git Clone dialog mirroring TortoiseGit's `CCloneDlg` (`src/TortoiseProc/CloneDlg.cpp`): URL with
/// history and *Browse* for local repositories, destination = chosen folder + repository name,
/// branch, depth, recursive submodules, bare, no checkout, origin name, LFS and an SSH key.
public final class CloneWindowController: NSWindowController, NSComboBoxDelegate, NSTextFieldDelegate {

    private let urlField = NSComboBox()
    private let directoryField = NSTextField()
    private let branchField = NSTextField()
    private let depthField = NSTextField()
    private let originField = NSTextField()
    private let sshKeyField = NSTextField()
    private let recursiveSubmodulesCheckbox = NSButton(checkboxWithTitle: "Recursive (--recurse-submodules)", target: nil, action: nil)
    private let bareCheckbox = NSButton(checkboxWithTitle: "Bare repository (--bare)", target: nil, action: nil)
    private let noCheckoutCheckbox = NSButton(checkboxWithTitle: "No checkout (--no-checkout)", target: nil, action: nil)
    private let lfsCheckbox = NSButton(checkboxWithTitle: "Download LFS files (git-lfs)", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Enter repository URL and destination directory.")
    private let cloneButton = NSButton(title: "Clone", target: nil, action: nil)
    /// Folder the clone goes into; the repository name is appended to it (TortoiseGit's behaviour)
    /// until the user edits the destination by hand.
    private var parentDirectory: String
    private var destinationEdited = false

    /// - Parameter exactPath: clone into `initialDirectory` itself (TortoiseGit's `/exactpath`). An
    ///   existing empty folder is always used as is: that is what cloning "here" into it means.
    public init(initialDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path, exactPath: Bool = false) {
        self.parentDirectory = initialDirectory
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Clone"
        super.init(window: window)

        setupUI()
        urlField.addItems(withObjectValues: ConfigManager.shared.recentUrls)
        // Like TortoiseGit, pre-fill a URL found on the clipboard.
        if let clip = NSPasteboard.general.string(forType: .string), GitURL.looksLikeRemoteURL(clip) {
            urlField.stringValue = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let isEmptyFolder = (try? FileManager.default.contentsOfDirectory(atPath: initialDirectory))
            .map { $0.filter { $0 != ".DS_Store" }.isEmpty } ?? false
        if exactPath || isEmptyFolder {
            directoryField.stringValue = initialDirectory
            destinationEdited = true
        }
        updateDestination()
        checkLFSAvailable()
    }

    /// Destination = parent folder + repository name (+ `.git` for a bare clone), unless the user typed their own.
    private func updateDestination() {
        guard !destinationEdited else { return }
        var name = GitURL.repositoryName(from: urlField.stringValue) ?? ""
        if bareCheckbox.state == .on, !name.isEmpty { name += ".git" }
        directoryField.stringValue = (parentDirectory as NSString).appendingPathComponent(name)
    }

    public func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === directoryField {
            destinationEdited = true
        } else if (notification.object as? NSTextField) === urlField {
            updateDestination()
        }
    }

    public func comboBoxSelectionDidChange(_ notification: Notification) {
        // The selection is applied to the field after this notification.
        DispatchQueue.main.async { self.updateDestination() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window else { return }

        urlField.placeholderString = "https://github.com/user/repo.git, git@github.com:… or a local folder"
        urlField.delegate = self
        urlField.completes = true
        urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        let browseURL = NSButton(title: "Browse…", target: self, action: #selector(onBrowseURL))
        browseURL.toolTip = "Clone a repository from a local folder"

        directoryField.delegate = self
        let browseDir = NSButton(title: "Browse…", target: self, action: #selector(onBrowse))

        branchField.placeholderString = "Default branch"
        depthField.placeholderString = "Full history"
        depthField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        originField.placeholderString = "origin"
        originField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        sshKeyField.placeholderString = "Optional private key used for this remote"
        let browseKey = NSButton(title: "Browse…", target: self, action: #selector(onBrowseKey))

        recursiveSubmodulesCheckbox.state = .on
        bareCheckbox.target = self
        bareCheckbox.action = #selector(onBareChanged)

        let grid = RemoteDialogSupport.grid([
            [RemoteDialogSupport.label("URL:"), RemoteDialogSupport.hStack([urlField, browseURL])],
            [RemoteDialogSupport.label("Directory:"), RemoteDialogSupport.hStack([directoryField, browseDir])],
            [RemoteDialogSupport.label("Branch:"), RemoteDialogSupport.hStack([branchField, RemoteDialogSupport.label("Depth:"), depthField])],
            [RemoteDialogSupport.label("Remote name:"), originField],
            [RemoteDialogSupport.label("SSH key:"), RemoteDialogSupport.hStack([sshKeyField, browseKey])],
            [RemoteDialogSupport.label("Options:"), RemoteDialogSupport.vStack([
                RemoteDialogSupport.hStack([recursiveSubmodulesCheckbox, lfsCheckbox], spacing: 16),
                RemoteDialogSupport.hStack([bareCheckbox, noCheckoutCheckbox], spacing: 16),
            ])],
        ])
        directoryField.widthAnchor.constraint(equalTo: urlField.widthAnchor).isActive = true
        sshKeyField.widthAnchor.constraint(equalTo: urlField.widthAnchor).isActive = true
        statusLabel.textColor = .secondaryLabelColor
        let content = RemoteDialogSupport.vStack([grid, statusLabel], spacing: 12)

        cloneButton.target = self
        cloneButton.action = #selector(onCloneClicked)
        cloneButton.bezelStyle = .rounded
        cloneButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(onCancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        RemoteDialogSupport.install(content, buttons: [cancelButton, cloneButton], in: window)
    }

    /// LFS needs the git-lfs binary; say so instead of failing during checkout.
    private func checkLFSAvailable() {
        Task { @MainActor in
            let available = (try? await GitCLIRunner.runAsync(arguments: ["lfs", "version"])) != nil
            self.lfsCheckbox.isEnabled = available
            self.lfsCheckbox.state = available ? .on : .off
            if !available { self.lfsCheckbox.toolTip = "git-lfs is not installed (brew install git-lfs)" }
        }
    }

    @objc private func onBareChanged() {
        noCheckoutCheckbox.isEnabled = bareCheckbox.state != .on
        updateDestination()
    }

    @objc private func onBrowse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder to clone into. A subfolder named after the repository is created."
        if panel.runModal() == .OK, let url = panel.url {
            parentDirectory = url.path
            destinationEdited = false
            updateDestination()
        }
    }

    @objc private func onBrowseURL() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose a local repository folder or a bundle file to clone"
        if panel.runModal() == .OK, let url = panel.url {
            urlField.stringValue = url.path
            updateDestination()
        }
    }

    @objc private func onBrowseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose the private key (not the .pub file)"
        if panel.runModal() == .OK, let url = panel.url {
            sshKeyField.stringValue = url.path
        }
    }

    /// The `git clone` arguments for the current settings.
    nonisolated static func cloneArguments(url: String, directory: String, branch: String, depth: String, origin: String,
                               recursive: Bool, bare: Bool, noCheckout: Bool, lfs: Bool, sshKey: String) -> [String] {
        var args = ["clone", "--progress"]
        if !branch.isEmpty { args += ["--branch", branch] }
        if let depth = Int(depth), depth > 0 { args.append("--depth=\(depth)") }
        if recursive && !bare { args.append("--recurse-submodules") }
        if bare {
            args.append("--bare")
        } else if noCheckout {
            args.append("--no-checkout")
        }
        if !origin.isEmpty, origin != "origin" { args += ["--origin", origin] }
        if lfs {
            // What `git lfs install --local` writes; applied before the checkout downloads LFS files.
            args += ["--config", "filter.lfs.clean=git-lfs clean -- %f",
                     "--config", "filter.lfs.smudge=git-lfs smudge -- %f",
                     "--config", "filter.lfs.process=git-lfs filter-process",
                     "--config", "filter.lfs.required=true"]
        }
        if !sshKey.isEmpty {
            // Remember the key for later fetches/pushes (Pull/Push/Sync read remote.<name>.sshkey).
            args += ["--config", "remote.\(origin.isEmpty ? "origin" : origin).\(GitRemotes.sshKeyVariable)=\(sshKey)"]
        }
        return args + ["--", url, directory]
    }

    @objc private func onCloneClicked() {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = (directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !url.isEmpty, !dir.isEmpty else {
            statusLabel.stringValue = "URL and Destination cannot be empty."
            statusLabel.textColor = .systemRed
            return
        }
        let trimmed = { (field: NSTextField) in field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        let origin = trimmed(originField)
        if !origin.isEmpty, origin.range(of: #"^[^\s~^:?*\[\\]+$"#, options: .regularExpression) == nil {
            statusLabel.stringValue = "“\(origin)” is not a valid remote name."
            statusLabel.textColor = .systemRed
            return
        }
        let sshKey = (trimmed(sshKeyField) as NSString).expandingTildeInPath
        let args = Self.cloneArguments(url: url, directory: dir, branch: trimmed(branchField), depth: trimmed(depthField),
                                       origin: origin, recursive: recursiveSubmodulesCheckbox.state == .on,
                                       bare: bareCheckbox.state == .on, noCheckout: noCheckoutCheckbox.state == .on,
                                       lfs: lfsCheckbox.isEnabled && lfsCheckbox.state == .on, sshKey: sshKey)

        // git refuses to clone into an existing non-empty folder; say so before starting.
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: dir), !contents.filter({ $0 != ".DS_Store" }).isEmpty {
            statusLabel.stringValue = "The destination folder already exists and is not empty."
            statusLabel.textColor = .systemRed
            return
        }
        // Finder leaves .DS_Store in folders it showed; git would refuse the folder because of it.
        try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(".DS_Store"))
        let parent = (dir as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        ConfigManager.shared.addRecentUrl(url)
        close()
        let destination = PangolinPath(dir)
        let bare = bareCheckbox.state == .on
        let environment = sshKey.isEmpty ? nil : GitRemotes.sshEnvironment(keyPath: sshKey)
        ProgressWindowController.run(
            title: "Git Clone", commands: [args], workingDirectory: PangolinPath(parent), repository: nil,
            environment: environment,
            postActions: { outcome in
                guard outcome.succeeded else { return [] }
                var actions: [ProgressWindowController.PostAction] = [
                    .init("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination.url]) }
                ]
                if !bare {
                    actions.insert(.init("Show Log") { CommandRouter.shared.execute(command: .log, targetPath: destination.rawPath) }, at: 0)
                }
                return actions
            },
            onFinish: { outcome in
                if outcome.succeeded && !bare { ConfigManager.shared.addRecentRepository(destination.rawPath) }
            }
        )
    }

    @objc private func onCancelClicked() {
        close()
    }
}
