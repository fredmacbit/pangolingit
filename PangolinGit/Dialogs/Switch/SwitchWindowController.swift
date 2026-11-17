import Cocoa
import PangolinGitCore

/// Git Switch / Checkout dialog mirroring TortoiseGit's `GitSwitchDlg.cpp`: switch to a branch, tag
/// or commit, optionally creating (or overriding) a branch with a chosen tracking mode, with force
/// and merge options, a dirty-tree stash offer and post-actions after the checkout.
public final class SwitchWindowController: NSWindowController, NSTextFieldDelegate {

    private let repositoryPath: PangolinPath
    private var localBranches: [String] = []
    private var tags: [String] = []
    private var remotes: [String] = []
    private var currentBranch = ""

    private let currentBranchLabel = NSTextField(labelWithString: "Current Branch: loading...")
    private var targetChooser: RevisionChooserView!
    private let createBranchCheckbox = NSButton(checkboxWithTitle: "Create New Branch", target: nil, action: nil)
    private let newBranchNameField = NSTextField()
    private let overrideCheckbox = NSButton(checkboxWithTitle: "Override branch if exists (-B)", target: nil, action: nil)
    private let trackCheckbox = NSButton(checkboxWithTitle: "Track", target: nil, action: nil)
    private let forceCheckoutCheckbox = NSButton(checkboxWithTitle: "Force (discard local changes)", target: nil, action: nil)
    private let mergeCheckbox = NSButton(checkboxWithTitle: "Merge local changes (--merge)", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "Choose a branch, tag or commit.")
    private let switchButton = NSButton(title: "Switch", target: nil, action: nil)

    /// - Parameter initialTarget: preselected branch / tag / commit (from Browse References or the Log).
    public init(repositoryPath: PangolinPath, initialTarget: String? = nil) {
        self.repositoryPath = repositoryPath
        let window = NSWindow(
            contentRect: NSRect(x: 260, y: 260, width: 540, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Switch / Checkout - \(repositoryPath.filename)"
        super.init(window: window)

        targetChooser = RevisionChooserView(repository: repositoryPath, kinds: [.branch, .tag, .commit], initialRevision: initialTarget)
        targetChooser.onChange = { [weak self] in self?.targetChanged() }
        setupUI()
        loadBranches()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.loadBranches() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        currentBranchLabel.font = NSFont.boldSystemFont(ofSize: 13)
        let labelTarget = NSTextField(labelWithString: "Switch To:")

        createBranchCheckbox.target = self
        createBranchCheckbox.action = #selector(onCreateToggled)
        newBranchNameField.placeholderString = "New branch name"
        newBranchNameField.delegate = self

        // TortoiseGit's tri-state Track box: mixed = git's default (branch.autoSetupMerge).
        trackCheckbox.allowsMixedState = true
        trackCheckbox.state = .mixed
        trackCheckbox.toolTip = "On: --track, off: --no-track, mixed: git's default (branch.autoSetupMerge)"
        overrideCheckbox.toolTip = "Reset the branch to the chosen start point if it already exists (git checkout -B)"
        forceCheckoutCheckbox.toolTip = "Throw away local changes to tracked files (git checkout --force)"
        forceCheckoutCheckbox.target = self
        forceCheckoutCheckbox.action = #selector(onOptionToggled)
        mergeCheckbox.toolTip = "Three-way merge local changes into the new branch (git checkout --merge)"
        mergeCheckbox.target = self
        mergeCheckbox.action = #selector(onOptionToggled)
        statusLabel.textColor = .secondaryLabelColor

        switchButton.target = self
        switchButton.action = #selector(onSwitchClicked)
        switchButton.bezelStyle = .rounded
        switchButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(onCancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let branchOptions = NSStackView(views: [overrideCheckbox, trackCheckbox])
        branchOptions.spacing = 16
        let buttons = NSStackView(views: [cancelButton, switchButton])

        let stack = NSStackView(views: [
            currentBranchLabel, labelTarget, targetChooser, createBranchCheckbox, newBranchNameField, branchOptions,
            forceCheckoutCheckbox, mergeCheckbox, statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: currentBranchLabel)
        stack.setCustomSpacing(14, after: targetChooser)
        stack.setCustomSpacing(14, after: branchOptions)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(buttons)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            newBranchNameField.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
        updateBranchControls()
    }

    private func loadBranches() {
        let root = repositoryPath
        Task { @MainActor in
            self.currentBranch = (try? await GitCLIRunner.runAsync(arguments: ["symbolic-ref", "--short", "-q", "HEAD"], workingDirectory: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.currentBranchLabel.stringValue = self.currentBranch.isEmpty
                ? "Current: detached HEAD" : "Current Branch: \(self.currentBranch)"
            let heads = (try? await GitCLIRunner.runAsync(arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"], workingDirectory: root)) ?? ""
            self.localBranches = heads.split(separator: "\n").map(String.init)
            let tagList = (try? await GitCLIRunner.runAsync(arguments: ["for-each-ref", "--format=%(refname:short)", "refs/tags"], workingDirectory: root)) ?? ""
            self.tags = tagList.split(separator: "\n").map(String.init)
            let remoteList = (try? await GitCLIRunner.runAsync(arguments: ["remote"], workingDirectory: root)) ?? ""
            self.remotes = remoteList.split(separator: "\n").map(String.init)
            self.targetChanged()
        }
    }

    /// The remote a chosen remote-tracking branch belongs to, or nil for anything else.
    private func remote(of target: String) -> String? {
        guard !localBranches.contains(target), targetChooser.branches.contains(target) else { return nil }
        return GitRefs.remote(ofRemoteBranch: target, remotes: remotes)
    }

    /// Choosing a remote branch proposes a local tracking branch of the same name (TortoiseGit does the same),
    /// instead of leaving the user on a detached HEAD.
    private func targetChanged() {
        let target = targetChooser.revision
        if let remote = remote(of: target) {
            let localName = String(target.dropFirst(remote.count + 1))
            if !localBranches.contains(localName) && createBranchCheckbox.state == .off {
                createBranchCheckbox.state = .on
                newBranchNameField.stringValue = localName
                trackCheckbox.state = .on
            }
        }
        updateBranchControls()
    }

    @objc private func onCreateToggled() {
        updateBranchControls()
        if createBranchCheckbox.state == .on {
            window?.makeFirstResponder(newBranchNameField)
        }
    }

    /// Force and merge exclude each other, like in TortoiseGit.
    @objc private func onOptionToggled(_ sender: NSButton) {
        if sender === forceCheckoutCheckbox, sender.state == .on { mergeCheckbox.state = .off }
        if sender === mergeCheckbox, sender.state == .on { forceCheckoutCheckbox.state = .off }
    }

    public func controlTextDidChange(_ obj: Notification) {
        updateBranchControls()
    }

    private var newBranchName: String {
        newBranchNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enables the branch options and validates the new name as the user types (`git check-ref-format`).
    private func updateBranchControls() {
        let creating = createBranchCheckbox.state == .on
        newBranchNameField.isEnabled = creating
        overrideCheckbox.isEnabled = creating
        trackCheckbox.isEnabled = creating
        var message = "Choose a branch, tag or commit."
        var isError = false
        if creating {
            let name = newBranchName
            if let error = GitRefName.validationError(name), !name.isEmpty {
                message = error
                isError = true
            } else if localBranches.contains(name) && overrideCheckbox.state == .off {
                message = "Branch “\(name)” already exists. Tick “Override branch if exists” to reset it."
                isError = true
            } else if tags.contains(name) {
                message = "A tag named “\(name)” exists too; the name would be ambiguous."
            } else if !name.isEmpty {
                message = "Creates branch “\(name)” at \(targetChooser.revision.isEmpty ? "HEAD" : targetChooser.revision)."
            }
        } else if !targetChooser.revision.isEmpty && !localBranches.contains(targetChooser.revision) {
            message = "“\(targetChooser.revision)” is not a local branch: you will be on a detached HEAD."
        }
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    @objc private func onSwitchClicked() {
        let target = targetChooser.revision
        var options = GitSwitchOptions(target: target.isEmpty ? "HEAD" : target)
        if createBranchCheckbox.state == .on {
            let name = newBranchName
            if let error = GitRefName.validationError(name) {
                statusLabel.stringValue = error
                statusLabel.textColor = .systemRed
                return
            }
            if localBranches.contains(name) && overrideCheckbox.state == .off {
                updateBranchControls()
                return
            }
            options.newBranch = name
            options.overrideExistingBranch = overrideCheckbox.state == .on
            options.track = trackCheckbox.state == .mixed ? nil : trackCheckbox.state == .on
        } else {
            guard !target.isEmpty else {
                statusLabel.stringValue = "Choose a branch, tag or commit."
                return
            }
            if !localBranches.contains(target) && !confirmDetachedHead(target) { return }
        }
        options.merge = mergeCheckbox.state == .on

        if forceCheckoutCheckbox.state == .on {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Discard local changes?"
            alert.informativeText = "A forced checkout overwrites uncommitted changes in tracked files. They cannot be recovered."
            alert.addButton(withTitle: "Force Checkout")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            options.force = true
        }

        let root = repositoryPath
        Task { @MainActor in
            var stashed = false
            if !options.force && !options.merge {
                switch await DirtyWorkingTree.prepare(root, operation: "switch", allowContinue: true, window: self.window) {
                case .cancel: return
                case .stashed: stashed = true
                case .proceed: break
                }
            }
            let resulting = options.newBranch ?? (self.localBranches.contains(options.target) ? options.target : nil)
            self.close()
            Self.runCheckout(options, root: root, resultingBranch: resulting, stashed: stashed)
        }
    }

    /// Warns before leaving the user on a detached HEAD (TortoiseGit asks the same when checking out a tag or commit).
    private func confirmDetachedHead(_ target: String) -> Bool {
        let key = "SwitchDetachedHeadWarningSuppressed"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let alert = NSAlert()
        alert.messageText = "Switch to a detached HEAD?"
        alert.informativeText = "“\(target)” is not a local branch. New commits made there belong to no branch and are easy to lose. Create a branch instead if you want to work on it."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: key) }
        return response == .alertFirstButtonReturn
    }

    /// Runs the checkout in the progress window with TortoiseGit's post-actions: on success Update
    /// Submodules / Pull / Merge / Show Log (and Stash Pop when we stashed); on failure Stash and Retry,
    /// Checkout with merge, Force.
    static func runCheckout(_ options: GitSwitchOptions, root: PangolinPath, resultingBranch: String?, stashed: Bool = false) {
        let hasSubmodules = FileManager.default.fileExists(atPath: root.appending(".gitmodules").rawPath)
        ProgressWindowController.run(title: "Switch to \(options.newBranch ?? options.target)", commands: [options.arguments],
                                     workingDirectory: root, postActions: { outcome in
            var actions: [ProgressWindowController.PostAction] = []
            if outcome.succeeded {
                if stashed { actions.append(DirtyWorkingTree.stashPopAction(root)) }
                if hasSubmodules {
                    actions.append(.init("Update Submodules") {
                        ProgressWindowController.run(title: "Update Submodules", commands: [["submodule", "update", "--init", "--recursive", "--progress"]],
                                                     workingDirectory: root)
                    })
                }
                if resultingBranch != nil {
                    actions.append(.init("Pull…") { CommandRouter.shared.execute(command: .pull, targetPath: root.rawPath) })
                    actions.append(.init("Merge…") {
                        WindowRegistry.shared.present({ MergeBranchWindowController(repositoryPath: root) }, repository: root)
                    })
                }
                actions.append(.init("Show Log") { CommandRouter.shared.execute(command: .log, targetPath: root.rawPath) })
            } else if !outcome.cancelled {
                let output = outcome.output
                if output.contains("would be overwritten") || output.contains("Please commit your changes or stash them") {
                    actions.append(.init("Stash and Retry") {
                        ProgressWindowController.run(title: "Switch to \(options.newBranch ?? options.target)",
                                                     commands: [["stash", "push", "-m", "PangolinGit: before switch"], options.arguments],
                                                     workingDirectory: root, postActions: { retry in
                            retry.succeeded ? [DirtyWorkingTree.stashPopAction(root)] : []
                        })
                    })
                    if !options.merge {
                        actions.append(.init("Checkout with Merge") {
                            var merged = options
                            merged.merge = true
                            merged.force = false
                            runCheckout(merged, root: root, resultingBranch: resultingBranch)
                        })
                    }
                }
                if output.contains("CONFLICT") || output.contains("needs merge") {
                    actions.append(.init("Resolve…") { CommandRouter.shared.execute(command: .changed, targetPath: root.rawPath) })
                }
            }
            return actions
        })
    }

    @objc private func onCancelClicked() {
        close()
    }
}
