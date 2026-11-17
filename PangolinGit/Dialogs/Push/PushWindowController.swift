import Cocoa
import PangolinGitCore

/// Git Push dialog mirroring TortoiseGit's `CPushDlg` (`src/TortoiseProc/PushDlg.cpp`): local branch
/// combo, push all branches / tags / one tag / notes, remote or URL (or every remote), remote-branch
/// combo, force vs. force-with-lease, the push options and a preview of the outgoing commits.
public final class PushWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    /// What the push sends (TortoiseGit spreads these over the dialog and Sync's Push menu, PU-05).
    enum Scope: Int {
        case branch, allBranches, allTags, oneTag, notes
    }

    private let repositoryPath: PangolinPath
    private var currentBranch: String?

    private let localBranch: BranchComboField
    private let scopePopup = NSPopUpButton()
    private let tagCombo = NSComboBox()
    private let target: RemoteTargetView
    private let allRemotesCheckbox = NSButton(checkboxWithTitle: "Push to all remotes", target: nil, action: nil)
    private let remoteBranch: BranchComboField

    private let forcePopup = NSPopUpButton()
    private let forceIfIncludesCheckbox = NSButton(checkboxWithTitle: "--force-if-includes", target: nil, action: nil)
    private let setUpstreamCheckbox = NSButton(checkboxWithTitle: "Set upstream (-u)", target: nil, action: nil)
    private let pushRemoteCheckbox = NSButton(checkboxWithTitle: "Always push this branch to this remote", target: nil, action: nil)
    private let tagsCheckbox = NSButton(checkboxWithTitle: "Include all tags (--tags)", target: nil, action: nil)
    private let followTagsCheckbox = NSButton(checkboxWithTitle: "Follow tags (--follow-tags)", target: nil, action: nil)
    private let recursePopup = NSPopUpButton()
    private let pushOptionField = NSTextField()
    private let noVerifyCheckbox = NSButton(checkboxWithTitle: "Skip pre-push hook (--no-verify)", target: nil, action: nil)
    private let dryRunCheckbox = NSButton(checkboxWithTitle: "Dry run", target: nil, action: nil)
    private let sshKeyCheckbox = NSButton(checkboxWithTitle: "Use the remote's SSH key", target: nil, action: nil)

    private let outgoingLabel = NSTextField(labelWithString: "Outgoing commits")
    private let outgoingTable = NSTableView()
    private var outgoing: [(hash: String, subject: String, author: String)] = []
    private var previewTask: Task<Void, Never>?
    private let pushButton = NSButton(title: "Push", target: nil, action: nil)

    public init(repositoryPath: PangolinPath) {
        self.repositoryPath = repositoryPath
        self.localBranch = BranchComboField(repository: repositoryPath)
        self.target = RemoteTargetView(repository: repositoryPath)
        self.remoteBranch = BranchComboField(repository: repositoryPath, placeholder: "Same name as the local branch")
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 620, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Push - \(repositoryPath.filename)"
        super.init(window: window)

        setupUI()
        loadBranchInfo()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in
            guard let self else { return }
            Task { await self.target.reload() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var scope: Scope { Scope(rawValue: scopePopup.indexOfSelectedItem) ?? .branch }

    private func setupUI() {
        guard let window else { return }

        scopePopup.addItems(withTitles: ["Branch", "All branches (--all)", "All tags (--tags)", "One tag", "Notes (refs/notes/*)"])
        scopePopup.target = self
        scopePopup.action = #selector(optionsChanged)
        tagCombo.placeholderString = "Tag to push"
        tagCombo.completes = true
        tagCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        localBranch.onChange = { [weak self] in self?.localBranchChanged() }
        target.onChange = { [weak self] in self?.remoteChanged() }
        remoteBranch.onChange = { [weak self] in self?.schedulePreview() }
        allRemotesCheckbox.target = self
        allRemotesCheckbox.action = #selector(optionsChanged)

        forcePopup.addItems(withTitles: ["No force", "Force with lease (safe)", "Force (--force, may discard remote commits)"])
        forcePopup.target = self
        forcePopup.action = #selector(optionsChanged)
        forceIfIncludesCheckbox.toolTip = "With lease: also require that the remote tip was integrated locally"
        recursePopup.addItems(withTitles: ["Default", "None (--recurse-submodules=no)", "Check (--recurse-submodules=check)", "On-demand (--recurse-submodules=on-demand)"])
        pushOptionField.placeholderString = "e.g. ci.skip (sent with --push-option)"
        sshKeyCheckbox.state = .on
        sshKeyCheckbox.isHidden = true

        let grid = RemoteDialogSupport.grid([
            [RemoteDialogSupport.label("Push:"), RemoteDialogSupport.hStack([scopePopup, tagCombo])],
            [RemoteDialogSupport.label("Local branch:"), localBranch],
            [RemoteDialogSupport.label("To:"), RemoteDialogSupport.vStack([target, allRemotesCheckbox])],
            [RemoteDialogSupport.label("Remote branch:"), remoteBranch],
            [RemoteDialogSupport.label("Force:"), RemoteDialogSupport.hStack([forcePopup, forceIfIncludesCheckbox])],
            [RemoteDialogSupport.label("Options:"), RemoteDialogSupport.vStack([
                RemoteDialogSupport.hStack([setUpstreamCheckbox, pushRemoteCheckbox], spacing: 16),
                RemoteDialogSupport.hStack([tagsCheckbox, followTagsCheckbox], spacing: 16),
                RemoteDialogSupport.hStack([noVerifyCheckbox, dryRunCheckbox], spacing: 16),
                sshKeyCheckbox,
            ])],
            [RemoteDialogSupport.label("Submodules:"), recursePopup],
            [RemoteDialogSupport.label("Push option:"), pushOptionField],
        ])
        pushOptionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true

        // Outgoing-commit preview (PU-04).
        let column = { (id: String, title: String, width: CGFloat) -> NSTableColumn in
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            return col
        }
        outgoingTable.addTableColumn(column("Hash", "Commit", 80))
        outgoingTable.addTableColumn(column("Subject", "Message", 340))
        outgoingTable.addTableColumn(column("Author", "Author", 120))
        outgoingTable.dataSource = self
        outgoingTable.delegate = self
        outgoingTable.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = outgoingTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        outgoingLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)

        let content = RemoteDialogSupport.vStack([grid, outgoingLabel, scroll], spacing: 10)
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        pushButton.target = self
        pushButton.action = #selector(onPushClicked)
        pushButton.bezelStyle = .rounded
        pushButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(onCancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        RemoteDialogSupport.install(content, buttons: [cancelButton, pushButton], in: window)
        optionsChanged()
    }

    private func loadBranchInfo() {
        let root = repositoryPath
        Task { @MainActor in
            let branches = await GitRemotes.localBranches(in: root)
            self.localBranch.setItems(branches)
            self.tagCombo.addItems(withObjectValues: await GitRemotes.tags(in: root))
            self.currentBranch = await GitRemotes.currentBranch(in: root)
            self.localBranch.stringValue = self.currentBranch ?? branches.first ?? ""
            await self.target.reload(preferred: await self.preferredRemote(for: self.localBranch.stringValue))
            await self.applyBranchDefaults()
        }
    }

    /// `branch.<b>.pushRemote`, then `remote.pushDefault`, then the upstream's remote (git's own order).
    private func preferredRemote(for branch: String) async -> String? {
        let root = repositoryPath
        if let value = await GitRemotes.configValue("branch.\(branch).pushRemote", in: root) { return value }
        if let value = await GitRemotes.configValue("remote.pushDefault", in: root) { return value }
        return await GitRemotes.configValue("branch.\(branch).remote", in: root)
    }

    /// Remote branch = the upstream's name when pushing to the upstream remote, else the local name;
    /// `-u` is suggested only while the branch has no upstream (SY-04).
    private func applyBranchDefaults() async {
        let branch = localBranch.stringValue
        let upstream = branch.isEmpty ? nil : await GitRemotes.upstream(of: branch, in: repositoryPath)
        if let upstream, upstream.remote == target.remoteName {
            remoteBranch.stringValue = upstream.branch
        } else {
            remoteBranch.stringValue = branch
        }
        setUpstreamCheckbox.state = upstream == nil ? .on : .off
        let pushRemote = await GitRemotes.configValue("branch.\(branch).pushRemote", in: repositoryPath)
        pushRemoteCheckbox.state = (pushRemote != nil && pushRemote == target.remoteName) ? .on : .off
        schedulePreview()
    }

    private func localBranchChanged() {
        Task { @MainActor in await self.applyBranchDefaults() }
    }

    private func remoteChanged() {
        remoteBranch.remote = target.remoteName
        let root = repositoryPath
        let remote = target.selectedRemote
        if let key = remote?.sshKey, !key.isEmpty {
            sshKeyCheckbox.title = "Use the remote's SSH key (\((key as NSString).lastPathComponent))"
            sshKeyCheckbox.isHidden = false
        } else {
            sshKeyCheckbox.isHidden = true
        }
        Task { @MainActor in
            self.remoteBranch.setItems(remote == nil ? [] : await GitRemotes.remoteBranches(of: remote!.name, in: root))
            await self.applyBranchDefaults()
        }
        optionsChanged()
    }

    @objc private func optionsChanged() {
        let scope = self.scope
        tagCombo.isHidden = scope != .oneTag
        let branchScope = scope == .branch
        localBranch.isEnabled = branchScope
        remoteBranch.isEnabled = branchScope && allRemotesCheckbox.state != .on
        setUpstreamCheckbox.isEnabled = branchScope || scope == .allBranches
        pushRemoteCheckbox.isEnabled = branchScope && !target.usesURL && allRemotesCheckbox.state != .on
        tagsCheckbox.isEnabled = scope == .branch || scope == .allBranches
        followTagsCheckbox.isEnabled = tagsCheckbox.isEnabled
        forceIfIncludesCheckbox.isEnabled = forcePopup.indexOfSelectedItem == 1
        allRemotesCheckbox.isEnabled = !target.usesURL && target.remotes.count > 1
        if !allRemotesCheckbox.isEnabled { allRemotesCheckbox.state = .off }
        schedulePreview()
    }

    // MARK: - Outgoing preview

    private func schedulePreview() {
        previewTask?.cancel()
        let local = localBranch.stringValue
        let remote = target.remoteName
        let remoteBranchName = remoteBranch.stringValue.isEmpty ? local : remoteBranch.stringValue
        let root = repositoryPath
        let showPreview = scope == .branch && !local.isEmpty
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            var commits: [(String, String, String)] = []
            var title = "Outgoing commits"
            if showPreview {
                var range = [local]
                if let remote {
                    let remoteRef = "refs/remotes/\(remote)/\(remoteBranchName)"
                    let exists = (try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "--verify", "--quiet", remoteRef],
                                                                   workingDirectory: root)) != nil
                    // A new branch: everything the remote does not have yet.
                    range = exists ? ["\(remoteRef)..\(local)"] : [local, "--not", "--remotes=\(remote)"]
                    title = exists ? "Outgoing commits (not in \(remote)/\(remoteBranchName))" : "Outgoing commits (new branch on \(remote))"
                }
                let output = (try? await GitCLIRunner.runAsync(
                    arguments: ["log", "--max-count=200", "--format=%h%x09%an%x09%s"] + range, workingDirectory: root)) ?? ""
                commits = output.split(separator: "\n").compactMap { line in
                    let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    return parts.count == 3 ? (parts[0], parts[2], parts[1]) : nil
                }
                title += " — \(commits.count)\(commits.count == 200 ? "+" : "")"
            } else {
                title = "Outgoing commits — shown for a single branch"
            }
            guard !Task.isCancelled else { return }
            self.outgoing = commits.map { (hash: $0.0, subject: $0.1, author: $0.2) }
            self.outgoingLabel.stringValue = title
            self.outgoingTable.reloadData()
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        outgoing.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < outgoing.count else { return nil }
        let commit = outgoing[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "Hash": text = commit.hash
        case "Author": text = commit.author
        default: text = commit.subject
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue == "Hash" { label.font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
        return label
    }

    // MARK: - Push

    /// The git command lines for the current settings (one per remote with *Push to all remotes*).
    private func buildCommands() -> [[String]]? {
        let scope = self.scope
        let local = localBranch.stringValue
        var options = ["push", "--progress"]
        switch forcePopup.indexOfSelectedItem {
        case 1:
            options.append("--force-with-lease")
            if forceIfIncludesCheckbox.state == .on { options.append("--force-if-includes") }
        case 2:
            options.append("--force")
        default:
            break
        }
        if setUpstreamCheckbox.isEnabled, setUpstreamCheckbox.state == .on { options.append("-u") }
        if tagsCheckbox.isEnabled, tagsCheckbox.state == .on { options.append("--tags") }
        if followTagsCheckbox.isEnabled, followTagsCheckbox.state == .on { options.append("--follow-tags") }
        switch recursePopup.indexOfSelectedItem {
        case 1: options.append("--recurse-submodules=no")
        case 2: options.append("--recurse-submodules=check")
        case 3: options.append("--recurse-submodules=on-demand")
        default: break
        }
        let pushOption = pushOptionField.stringValue.trimmingCharacters(in: .whitespaces)
        if !pushOption.isEmpty { options.append("--push-option=\(pushOption)") }
        if noVerifyCheckbox.state == .on { options.append("--no-verify") }
        if dryRunCheckbox.state == .on { options.append("--dry-run") }

        var refspecs: [String] = []
        switch scope {
        case .branch:
            guard !local.isEmpty else { return nil }
            let remoteName = remoteBranch.stringValue.isEmpty ? local : remoteBranch.stringValue
            // Explicit refspec so a renamed remote branch still pushes the local branch shown above.
            refspecs = ["refs/heads/\(local):refs/heads/\(remoteName)"]
        case .allBranches:
            options.append("--all")
        case .allTags:
            options.append("--tags")
        case .oneTag:
            let tag = tagCombo.stringValue.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty else { return nil }
            refspecs = ["refs/tags/\(tag)"]
        case .notes:
            refspecs = ["refs/notes/*:refs/notes/*"]
        }

        let destinations: [String]
        if allRemotesCheckbox.state == .on {
            destinations = target.remotes.map(\.name)
        } else if let destination = target.repositoryArgument {
            destinations = [destination]
        } else {
            return nil
        }
        return destinations.map { options + [$0] + refspecs }
    }

    @objc private func onPushClicked() {
        guard let pushCommands = buildCommands() else {
            NSSound.beep()
            return
        }
        var commands = pushCommands
        let local = localBranch.stringValue
        if pushRemoteCheckbox.isEnabled, pushRemoteCheckbox.state == .on, let remote = target.remoteName, !local.isEmpty {
            // TortoiseGit's "Always push to this remote" (`branch.<b>.pushremote`).
            commands.insert(["config", "branch.\(local).pushRemote", remote], at: 0)
        }
        target.recordURLInHistory()
        let environment = (!sshKeyCheckbox.isHidden && sshKeyCheckbox.state == .on && allRemotesCheckbox.state != .on)
            ? target.selectedRemote.map { GitRemotes.sshEnvironment(keyPath: $0.sshKey) } : nil
        close()
        let root = repositoryPath
        ProgressWindowController.run(
            title: "Git Push", commands: commands, workingDirectory: root, environment: environment,
            postActions: { outcome in
                // A rejected push usually means the remote has new commits: offer to pull first.
                if !outcome.succeeded && (outcome.output.contains("rejected") || outcome.output.contains("fetch first")) {
                    return [.init("Pull…") { CommandRouter.shared.execute(command: .pull, targetPath: root.rawPath) }]
                }
                if outcome.succeeded {
                    return [.init("Request Pull…") { CommandRouter.shared.execute(command: .requestPull, targetPath: root.rawPath) }]
                }
                return []
            }
        )
    }

    @objc private func onCancelClicked() {
        close()
    }
}
