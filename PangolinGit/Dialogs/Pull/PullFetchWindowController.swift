import Cocoa
import PangolinGitCore

/// Git Pull / Fetch dialog mirroring TortoiseGit's `CPullFetchDlg` (`src/TortoiseProc/PullFetchDlg.cpp`):
/// remote or arbitrary URL, remote-branch combo defaulting to the upstream, tags / prune tri-states
/// that show the effective default, depth / unshallow, the pull merge options and
/// *Launch Rebase After Fetch*.
public final class PullFetchWindowController: NSWindowController {

    public enum Mode {
        case pull, fetch
    }

    private let repositoryPath: PangolinPath
    private var currentBranch: String?
    private var upstream: (remote: String, branch: String)?

    private let modeSegment = NSSegmentedControl(labels: ["Pull", "Fetch"], trackingMode: .selectOne, target: nil, action: nil)
    private let target: RemoteTargetView
    private let remoteBranch: BranchComboField
    private let localBranchLabel = NSTextField(labelWithString: "")

    // Fetch options (PF-03)
    private let tagsPopup = NSPopUpButton()
    private let pruneCheckbox = NSButton(checkboxWithTitle: "Prune", target: nil, action: nil)
    private let depthCheckbox = NSButton(checkboxWithTitle: "Depth:", target: nil, action: nil)
    private let depthField = NSTextField()
    private let unshallowCheckbox = NSButton(checkboxWithTitle: "Unshallow (fetch the complete history)", target: nil, action: nil)

    // Pull options (PF-04)
    private let rebaseCheckbox = NSButton(checkboxWithTitle: "Rebase instead of merge (--rebase)", target: nil, action: nil)
    private let squashCheckbox = NSButton(checkboxWithTitle: "Squash (--squash)", target: nil, action: nil)
    private let noFFCheckbox = NSButton(checkboxWithTitle: "No fast-forward (--no-ff)", target: nil, action: nil)
    private let ffOnlyCheckbox = NSButton(checkboxWithTitle: "Fast-forward only (--ff-only)", target: nil, action: nil)
    private let noCommitCheckbox = NSButton(checkboxWithTitle: "No commit (--no-commit)", target: nil, action: nil)
    private let autostashCheckbox = NSButton(checkboxWithTitle: "Autostash local changes (--autostash)", target: nil, action: nil)
    private var formGrid: NSGridView!

    // Fetch follow-up (PF-05) and remote extras (PF-07, SY-04)
    private let launchRebaseCheckbox = NSButton(checkboxWithTitle: "Launch Rebase after fetch", target: nil, action: nil)
    private let sshKeyCheckbox = NSButton(checkboxWithTitle: "Use the remote's SSH key", target: nil, action: nil)
    private let setUpstreamCheckbox = NSButton(checkboxWithTitle: "Track this remote branch (set as upstream)", target: nil, action: nil)
    private let actionButton = NSButton(title: "Pull", target: nil, action: nil)

    public init(repositoryPath: PangolinPath, mode: Mode = .pull) {
        self.repositoryPath = repositoryPath
        self.target = RemoteTargetView(repository: repositoryPath)
        self.remoteBranch = BranchComboField(repository: repositoryPath, placeholder: "Branch on the remote (empty = configured default)")
        let window = NSWindow(
            contentRect: NSRect(x: 220, y: 220, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Pull / Fetch - \(repositoryPath.filename)"
        super.init(window: window)

        modeSegment.selectedSegment = mode == .pull ? 0 : 1
        setupUI()
        onModeChanged()
        loadBranchInfo()
        // Manage… edits remotes; reload them (and the branch list) when that happens.
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in
            guard let self else { return }
            Task { await self.target.reload() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var isPull: Bool { modeSegment.selectedSegment == 0 }

    private func setupUI() {
        guard let window else { return }
        modeSegment.target = self
        modeSegment.action = #selector(onModeChanged)

        target.onChange = { [weak self] in self?.remoteChanged() }

        tagsPopup.addItems(withTitles: ["Default", "All tags (--tags)", "No tags (--no-tags)"])
        pruneCheckbox.allowsMixedState = true
        pruneCheckbox.state = .mixed
        pruneCheckbox.toolTip = "Checked: --prune, unchecked: --no-prune, mixed: use the configured default"
        depthCheckbox.target = self
        depthCheckbox.action = #selector(updateEnabledStates)
        depthField.placeholderString = "1"
        depthField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        unshallowCheckbox.target = self
        unshallowCheckbox.action = #selector(updateEnabledStates)
        unshallowCheckbox.isHidden = true

        for checkbox in [rebaseCheckbox, squashCheckbox, noFFCheckbox, ffOnlyCheckbox, noCommitCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(pullOptionChanged(_:))
        }
        sshKeyCheckbox.state = .on
        sshKeyCheckbox.isHidden = true
        setUpstreamCheckbox.isHidden = true

        let fetchOptions = RemoteDialogSupport.vStack([
            RemoteDialogSupport.hStack([NSTextField(labelWithString: "Tags:"), tagsPopup, pruneCheckbox]),
            RemoteDialogSupport.hStack([depthCheckbox, depthField, unshallowCheckbox]),
        ])
        let pullOptions = RemoteDialogSupport.vStack([
            rebaseCheckbox,
            RemoteDialogSupport.hStack([squashCheckbox, noCommitCheckbox], spacing: 16),
            RemoteDialogSupport.hStack([noFFCheckbox, ffOnlyCheckbox], spacing: 16),
            autostashCheckbox,
        ])

        let grid = RemoteDialogSupport.grid([
            [RemoteDialogSupport.label("From:"), target],
            [RemoteDialogSupport.label("Remote branch:"), remoteBranch],
            [RemoteDialogSupport.label("Into:"), localBranchLabel],
            [RemoteDialogSupport.label("Fetch:"), fetchOptions],
            [RemoteDialogSupport.label("Pull:"), pullOptions],
            [nil, RemoteDialogSupport.vStack([launchRebaseCheckbox, sshKeyCheckbox, setUpstreamCheckbox])],
        ])
        grid.row(at: 2).yPlacement = .center
        formGrid = grid

        let content = RemoteDialogSupport.vStack([modeSegment, grid], spacing: 14)
        content.alignment = .centerX

        actionButton.target = self
        actionButton.action = #selector(onActionClicked)
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(onCancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        RemoteDialogSupport.install(content, buttons: [cancelButton, actionButton], in: window)
    }

    private func loadBranchInfo() {
        let root = repositoryPath
        Task { @MainActor in
            self.currentBranch = await GitRemotes.currentBranch(in: root)
            if let branch = self.currentBranch {
                self.upstream = await GitRemotes.upstream(of: branch, in: root)
                // A configured pull.rebase / branch.<b>.rebase preselects Rebase, as in TortoiseGit.
                var rebaseSetting = await GitRemotes.configValue("branch.\(branch).rebase", in: root)
                if rebaseSetting == nil { rebaseSetting = await GitRemotes.configValue("pull.rebase", in: root) }
                if let rebaseSetting, rebaseSetting != "false" { self.rebaseCheckbox.state = .on }
            }
            self.localBranchLabel.stringValue = self.currentBranch.map { "\($0) (current branch)" } ?? "Detached HEAD"
            self.unshallowCheckbox.isHidden = !(await GitRemotes.isShallow(root))
            await self.target.reload(preferred: self.upstream?.remote)
            self.remoteBranch.stringValue = self.defaultRemoteBranch()
            self.updateEnabledStates()
        }
    }

    /// `branch.<b>.merge` when pulling from the upstream remote; otherwise the local branch name
    /// if the remote has it (TortoiseGit's default).
    private func defaultRemoteBranch() -> String {
        if let upstream, target.remoteName == upstream.remote { return upstream.branch }
        if let branch = currentBranch, remoteBranch.combo.objectValues.contains(where: { ($0 as? String) == branch }) { return branch }
        return ""
    }

    private func remoteChanged() {
        remoteBranch.remote = target.remoteName
        let root = repositoryPath
        let remote = target.selectedRemote
        Task { @MainActor in
            if let name = remote?.name {
                self.remoteBranch.setItems(await GitRemotes.remoteBranches(of: name, in: root))
            } else {
                self.remoteBranch.setItems([])
            }
            self.remoteBranch.stringValue = self.defaultRemoteBranch()
            self.updateRemoteDefaults(remote)
            self.updateEnabledStates()
        }
    }

    /// Shows what "Default" means for tags and prune for the chosen remote.
    private func updateRemoteDefaults(_ remote: GitRemoteConfig?) {
        let tagDefault = remote?.tagOption.title ?? GitRemoteConfig.TagOption.reachable.title
        tagsPopup.item(at: 0)?.title = "Default (\(tagDefault))"
        let root = repositoryPath
        Task { @MainActor in
            var prune = remote?.prune
            if prune == nil, let global = await GitRemotes.configValue("fetch.prune", in: root) {
                prune = GitRemotes.parseBool(global)
            }
            self.pruneCheckbox.title = "Prune (default: \(prune == true ? "on" : "off"))"
        }
        if let key = remote?.sshKey, !key.isEmpty {
            sshKeyCheckbox.title = "Use the remote's SSH key (\((key as NSString).lastPathComponent))"
            sshKeyCheckbox.isHidden = false
        } else {
            sshKeyCheckbox.isHidden = true
        }
    }

    @objc private func onModeChanged() {
        actionButton.title = isPull ? "Pull" : "Fetch"
        target.offersAllRemotes = !isPull
        updateEnabledStates()
    }

    /// Keeps mutually exclusive options apart (git rejects `--ff-only` with `--no-ff`, and the merge
    /// options do not apply to a rebase).
    @objc private func pullOptionChanged(_ sender: NSButton) {
        if sender === noFFCheckbox, sender.state == .on { ffOnlyCheckbox.state = .off }
        if sender === ffOnlyCheckbox, sender.state == .on { noFFCheckbox.state = .off; squashCheckbox.state = .off }
        if sender === squashCheckbox, sender.state == .on { ffOnlyCheckbox.state = .off }
        updateEnabledStates()
    }

    @objc private func updateEnabledStates() {
        let allRemotes = target.allRemotesSelected
        remoteBranch.isEnabled = !allRemotes
        // Rows 2 ("Into") and 4 (merge options) only apply to a pull.
        let wasHidden = formGrid.row(at: 4).isHidden
        formGrid.row(at: 2).isHidden = !isPull
        formGrid.row(at: 4).isHidden = !isPull
        if wasHidden != !isPull, let window, let contentView = window.contentView {
            window.setContentSize(contentView.fittingSize)
        }
        let rebase = rebaseCheckbox.state == .on
        for checkbox in [squashCheckbox, noFFCheckbox, ffOnlyCheckbox, noCommitCheckbox] {
            checkbox.isEnabled = !rebase
        }
        launchRebaseCheckbox.isHidden = isPull
        depthField.isEnabled = depthCheckbox.state == .on
        depthCheckbox.isEnabled = unshallowCheckbox.state != .on
        // Offer tracking only when the branch has no upstream yet and a remote branch is named.
        setUpstreamCheckbox.isHidden = !(isPull && upstream == nil && currentBranch != nil && target.remoteName != nil)
        localBranchLabel.textColor = isPull ? .labelColor : .disabledControlTextColor
    }

    /// The fetch-side options shared by `git pull` and `git fetch`.
    private func fetchOptionArguments() -> [String] {
        var args: [String] = []
        switch tagsPopup.indexOfSelectedItem {
        case 1: args.append("--tags")
        case 2: args.append("--no-tags")
        default: break
        }
        switch pruneCheckbox.state {
        case .on: args.append("--prune")
        case .off: args.append("--no-prune")
        default: break
        }
        if unshallowCheckbox.state == .on && !unshallowCheckbox.isHidden {
            args.append("--unshallow")
        } else if depthCheckbox.state == .on, let depth = Int(depthField.stringValue), depth > 0 {
            args.append("--depth=\(depth)")
        }
        return args
    }

    @objc private func onActionClicked() {
        let branch = remoteBranch.stringValue
        let allRemotes = target.allRemotesSelected
        guard allRemotes || target.repositoryArgument != nil else {
            NSSound.beep()
            window?.makeFirstResponder(target.urlCombo)
            return
        }
        if isPull, target.usesURL, branch.isEmpty {
            // TortoiseGit: "Pulling from a URL requires a remote branch."
            let alert = NSAlert()
            alert.messageText = "Enter the remote branch to pull"
            alert.informativeText = "A URL has no configured default branch."
            alert.beginSheetModal(for: window!)
            return
        }

        var commands: [[String]] = []
        if isPull {
            var args = ["pull", "--progress"]
            if rebaseCheckbox.state == .on {
                args.append("--rebase")
            } else {
                // Always explicit: without pull.rebase configured, git refuses divergent pulls.
                args.append("--no-rebase")
                if squashCheckbox.state == .on { args.append("--squash") }
                if noFFCheckbox.state == .on { args.append("--no-ff") }
                if ffOnlyCheckbox.state == .on { args.append("--ff-only") }
                if noCommitCheckbox.state == .on { args.append("--no-commit") }
            }
            if autostashCheckbox.state == .on { args.append("--autostash") }
            args += fetchOptionArguments()
            args.append(target.repositoryArgument!)
            if !branch.isEmpty { args.append(branch) }
            commands.append(args)
            if !setUpstreamCheckbox.isHidden, setUpstreamCheckbox.state == .on,
               let remote = target.remoteName, let local = currentBranch, !branch.isEmpty {
                commands.append(["branch", "--set-upstream-to=\(remote)/\(branch)", local])
            }
        } else {
            var args = ["fetch", "--progress"] + fetchOptionArguments()
            if allRemotes {
                args.append("--all")
            } else {
                args.append(target.repositoryArgument!)
                if !branch.isEmpty { args.append(branch) }
            }
            commands.append(args)
        }

        target.recordURLInHistory()
        let environment = (!sshKeyCheckbox.isHidden && sshKeyCheckbox.state == .on)
            ? target.selectedRemote.map { GitRemotes.sshEnvironment(keyPath: $0.sshKey) } : nil
        let root = repositoryPath
        let pulling = isPull
        let rebasing = isPull && rebaseCheckbox.state == .on
        let launchRebase = !isPull && launchRebaseCheckbox.state == .on
        // What the fetched branch is called locally, for the rebase prompt.
        let fetchedRef: String = {
            if let remote = target.remoteName, !branch.isEmpty { return "\(remote)/\(branch)" }
            if allRemotes || target.remoteName == upstream?.remote, upstream != nil { return "@{upstream}" }
            return "FETCH_HEAD"
        }()
        close()

        ProgressWindowController.run(
            title: pulling ? "Git Pull" : "Git Fetch", commands: commands, workingDirectory: root,
            environment: environment,
            postActions: { outcome in
                var actions: [ProgressWindowController.PostAction] = []
                if RemoteDialogSupport.reportsConflicts(outcome.output) {
                    actions.append(RemoteDialogSupport.resolveAction(root: root))
                    if rebasing {
                        actions.append(.init("Abort Rebase") {
                            ProgressWindowController.run(title: "Abort Rebase", commands: [["rebase", "--abort"]], workingDirectory: root)
                        })
                    }
                }
                if outcome.succeeded {
                    actions.append(.init("Show Log") { CommandRouter.shared.execute(command: .log, targetPath: root.rawPath) })
                    if !pulling {
                        actions.append(.init("Rebase…") { CommandRouter.shared.execute(command: .rebase, targetPath: root.rawPath) })
                    }
                }
                return actions
            },
            onFinish: { outcome in
                guard launchRebase, outcome.succeeded else { return }
                Task { @MainActor in await Self.offerRebase(onto: fetchedRef, root: root) }
            }
        )
    }

    /// *Launch Rebase After Fetch* (PF-05): nothing new → nothing to do; a fast-forward is possible →
    /// ask Merge (fast-forward) / Rebase / Cancel; diverged → open the Rebase dialog.
    @MainActor
    static func offerRebase(onto ref: String, root: PangolinPath) async {
        guard let counts = await GitRemotes.aheadBehind("HEAD", ref, in: root), counts.behind > 0 else { return }
        if counts.ahead > 0 {
            CommandRouter.shared.execute(command: .rebase, targetPath: root.rawPath)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Fast-forward possible"
        alert.informativeText = "\(ref) is \(counts.behind) commit(s) ahead of your branch and contains all of its commits. A fast-forward merge brings your branch up to date without a rebase."
        alert.addButton(withTitle: "Fast-forward")
        alert.addButton(withTitle: "Rebase…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ProgressWindowController.run(title: "Git Merge", commands: [["merge", "--ff-only", ref]], workingDirectory: root)
        case .alertSecondButtonReturn:
            CommandRouter.shared.execute(command: .rebase, targetPath: root.rawPath)
        default:
            break
        }
    }

    @objc private func onCancelClicked() {
        close()
    }
}
