import Cocoa
import PangolinGitCore

/// TortoiseGit's *Merge…* dialog (`MergeDlg.cpp`): merge a branch, tag or commit into the current
/// branch with Squash / No Fast Forward / Fast Forward Only / No Commit / Messages (`--log`),
/// strategy and strategy option, a custom message, and post-actions after the merge.
/// (The existing `MergeWindowController` is the conflict editor, TortoiseGitMerge.)
public final class MergeBranchWindowController: NSWindowController {

    private let repositoryPath: PangolinPath
    private var sourceChooser: RevisionChooserView!
    private let intoLabel = NSTextField(labelWithString: "Merge into: …")
    private let squashCheckbox = NSButton(checkboxWithTitle: "Squash", target: nil, action: nil)
    private let noFFCheckbox = NSButton(checkboxWithTitle: "No Fast Forward", target: nil, action: nil)
    private let ffOnlyCheckbox = NSButton(checkboxWithTitle: "Fast Forward Only", target: nil, action: nil)
    private let noCommitCheckbox = NSButton(checkboxWithTitle: "No Commit", target: nil, action: nil)
    private let logCheckbox = NSButton(checkboxWithTitle: "Messages", target: nil, action: nil)
    private let logCountField = NSTextField(string: "20")
    private let unrelatedCheckbox = NSButton(checkboxWithTitle: "Allow unrelated histories", target: nil, action: nil)
    private let strategyPopup = NSPopUpButton()
    private let strategyOptionCombo = NSComboBox()
    private let messageView = NSTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let mergeButton = NSButton(title: "Merge", target: nil, action: nil)
    private let inProgressBox = NSBox()
    private var currentBranch = ""

    /// - Parameter initialRevision: preselected source (from Browse References / Log *Merge to "current"…*).
    public init(repositoryPath: PangolinPath, initialRevision: String? = nil) {
        self.repositoryPath = repositoryPath
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Merge - \(repositoryPath.filename)"
        window.minSize = NSSize(width: 540, height: 560)
        super.init(window: window)
        sourceChooser = RevisionChooserView(repository: repositoryPath, kinds: [.branch, .tag, .commit], initialRevision: initialRevision)
        sourceChooser.onChange = { [weak self] in self?.validate() }
        setupUI()
        refreshState()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.refreshState() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        intoLabel.font = NSFont.boldSystemFont(ofSize: 13)

        // BR-12: what a stopped merge means and how to get out of it.
        inProgressBox.title = "A merge is in progress"
        inProgressBox.isHidden = true
        let explanation = NSTextField(wrappingLabelWithString:
            "A previous merge stopped (conflicts or --no-commit). Resolve the conflicted files and commit to finish it, or abort to return to the state before the merge. A new merge cannot start until then.")
        explanation.font = NSFont.systemFont(ofSize: 11)
        let resolve = NSButton(title: "Resolve / Commit…", target: self, action: #selector(openCommit))
        let abort = NSButton(title: "Abort Merge…", target: self, action: #selector(abortMerge))
        let boxStack = NSStackView(views: [explanation, NSStackView(views: [resolve, abort])])
        boxStack.orientation = .vertical
        boxStack.alignment = .leading
        boxStack.translatesAutoresizingMaskIntoConstraints = false
        inProgressBox.contentView?.addSubview(boxStack)
        if let boxContent = inProgressBox.contentView {
            NSLayoutConstraint.activate([
                boxStack.topAnchor.constraint(equalTo: boxContent.topAnchor, constant: 6),
                boxStack.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor, constant: 8),
                boxStack.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor, constant: -8),
                boxStack.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor, constant: -6),
                explanation.widthAnchor.constraint(equalTo: boxStack.widthAnchor),
            ])
        }

        for box in [squashCheckbox, noFFCheckbox, ffOnlyCheckbox, noCommitCheckbox, logCheckbox, unrelatedCheckbox] {
            box.target = self
            box.action = #selector(optionToggled(_:))
        }
        squashCheckbox.toolTip = "Combine the changes into the working tree and index without a merge commit (--squash)"
        noFFCheckbox.toolTip = "Always create a merge commit, even when a fast-forward is possible (--no-ff)"
        ffOnlyCheckbox.toolTip = "Refuse to merge unless the current branch can be fast-forwarded (--ff-only)"
        noCommitCheckbox.toolTip = "Stop before creating the merge commit so you can inspect it (--no-commit)"
        logCheckbox.toolTip = "Add the one-line messages of up to this many merged commits to the merge message (--log)"
        logCountField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        logCountField.isEnabled = false

        strategyPopup.addItem(withTitle: "Default")
        strategyPopup.addItems(withTitles: GitMergeOptions.strategies)
        strategyOptionCombo.addItems(withObjectValues: [""] + GitMergeOptions.strategyOptions)
        strategyOptionCombo.placeholderString = "none, or e.g. theirs, rename-threshold=50"
        strategyOptionCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let optionsGrid = NSGridView(views: [
            [squashCheckbox, noFFCheckbox],
            [noCommitCheckbox, ffOnlyCheckbox],
            [NSStackView(views: [logCheckbox, logCountField]), unrelatedCheckbox],
        ])
        optionsGrid.columnSpacing = 24
        optionsGrid.rowSpacing = 6
        let strategyGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Strategy:"), strategyPopup],
            [NSTextField(labelWithString: "Strategy option:"), strategyOptionCombo],
        ])
        strategyGrid.rowSpacing = 6

        let messageScroll = NSScrollView()
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageView.isRichText = false
        messageView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        messageView.autoresizingMask = [.width]
        messageScroll.documentView = messageView

        statusLabel.textColor = .secondaryLabelColor
        mergeButton.target = self
        mergeButton.action = #selector(mergeClicked)
        mergeButton.keyEquivalent = "\r"
        mergeButton.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel, mergeButton])

        let stack = NSStackView(views: [
            intoLabel, inProgressBox, NSTextField(labelWithString: "From:"), sourceChooser, optionsGrid, strategyGrid,
            NSTextField(labelWithString: "Merge message (leave empty for git's default):"), messageScroll, statusLabel, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: sourceChooser)
        stack.setCustomSpacing(16, after: optionsGrid)
        stack.setCustomSpacing(16, after: strategyGrid)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            inProgressBox.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            messageScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
            statusLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    private func refreshState() {
        let root = repositoryPath
        Task { @MainActor in
            let branch = (try? await GitCLIRunner.runAsync(arguments: ["symbolic-ref", "--short", "-q", "HEAD"], workingDirectory: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.currentBranch = branch
            self.intoLabel.stringValue = branch.isEmpty ? "Merge into: detached HEAD" : "Merge into: \(branch)"
            let gitDir = GitRepository.open(at: root)?.gitDirectory
            let state = gitDir.map { GitOperationInProgress.detect(gitDirectory: $0) } ?? .none
            self.inProgressBox.isHidden = state != .merge
            self.validate()
        }
    }

    /// Builds the options from the controls (nil while invalid, with the reason in the status line).
    private func currentOptions() -> GitMergeOptions? {
        var options = GitMergeOptions(revision: sourceChooser.revision)
        options.squash = squashCheckbox.state == .on
        options.noFastForward = noFFCheckbox.state == .on
        options.fastForwardOnly = ffOnlyCheckbox.state == .on
        options.noCommit = noCommitCheckbox.state == .on
        options.allowUnrelatedHistories = unrelatedCheckbox.state == .on
        if logCheckbox.state == .on {
            options.logMessages = max(1, logCountField.integerValue)
        }
        options.strategy = strategyPopup.indexOfSelectedItem > 0 ? (strategyPopup.titleOfSelectedItem ?? "") : ""
        options.strategyOption = strategyOptionCombo.stringValue.trimmingCharacters(in: .whitespaces)
        options.message = messageView.string
        return options
    }

    @discardableResult
    private func validate() -> Bool {
        let error = currentOptions()?.validationError
        let busy = !inProgressBox.isHidden
        statusLabel.stringValue = busy ? "Finish or abort the merge in progress first." : (error ?? "")
        statusLabel.textColor = (error != nil || busy) ? .systemRed : .secondaryLabelColor
        mergeButton.isEnabled = !busy
        return error == nil && !busy
    }

    @objc private func optionToggled(_ sender: NSButton) {
        // Keep mutually exclusive choices consistent, like TortoiseGit's dialog does.
        if sender.state == .on {
            switch sender {
            case squashCheckbox: noFFCheckbox.state = .off; ffOnlyCheckbox.state = .off
            case noFFCheckbox: squashCheckbox.state = .off; ffOnlyCheckbox.state = .off
            case ffOnlyCheckbox: squashCheckbox.state = .off; noFFCheckbox.state = .off
            default: break
            }
        }
        logCountField.isEnabled = logCheckbox.state == .on
        validate()
    }

    @objc private func mergeClicked() {
        guard validate(), let options = currentOptions() else { return }
        let root = repositoryPath
        let source = sourceChooser.revision
        Task { @MainActor in
            let decision = await DirtyWorkingTree.prepare(root, operation: "merge", allowContinue: true, window: self.window)
            guard decision != .cancel else { return }
            // A local source branch can be removed afterwards (TortoiseGit's *Remove merged branch*).
            let isLocal = (try? await GitCLIRunner().run(arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(source)"],
                                                         workingDirectory: root))?.isSuccess ?? false
            self.close()
            Self.run(options, root: root, deletableBranch: isLocal && source != self.currentBranch ? source : nil,
                     stashed: decision == .stashed)
        }
    }

    /// Runs `git merge` in the progress window with TortoiseGit's post-actions.
    static func run(_ options: GitMergeOptions, root: PangolinPath, deletableBranch: String?, stashed: Bool) {
        ProgressWindowController.run(title: "Merge \(options.revision)", commands: [options.arguments], workingDirectory: root, postActions: { outcome in
            var actions: [ProgressWindowController.PostAction] = []
            let output = outcome.output
            if outcome.succeeded {
                if options.noCommit || options.squash {
                    actions.append(.init("Commit…") { CommandRouter.shared.execute(command: .commit, targetPath: root.rawPath) })
                }
                if stashed { actions.append(DirtyWorkingTree.stashPopAction(root)) }
                if let branch = deletableBranch, !options.squash {
                    actions.append(.init("Remove Branch \(branch)") {
                        ProgressWindowController.run(title: "Delete Branch \(branch)", commands: [["branch", "-d", branch]], workingDirectory: root)
                    })
                }
                actions.append(.init("Show Log") { CommandRouter.shared.execute(command: .log, targetPath: root.rawPath) })
                actions.append(.init("Push…") { CommandRouter.shared.execute(command: .push, targetPath: root.rawPath) })
            } else if !outcome.cancelled {
                if output.contains("refusing to merge unrelated histories") {
                    actions.append(.init("Merge Unrelated Histories") {
                        var retry = options
                        retry.allowUnrelatedHistories = true
                        run(retry, root: root, deletableBranch: deletableBranch, stashed: stashed)
                    })
                }
                if output.contains("would be overwritten") || output.contains("commit your changes or stash them") {
                    actions.append(.init("Stash and Retry") {
                        ProgressWindowController.run(title: "Merge \(options.revision)",
                                                     commands: [["stash", "push", "-m", "PangolinGit: before merge"], options.arguments],
                                                     workingDirectory: root, postActions: { retry in
                            retry.succeeded ? [DirtyWorkingTree.stashPopAction(root)] : []
                        })
                    })
                }
                if output.contains("CONFLICT") || output.contains("Automatic merge failed") {
                    actions.append(.init("Resolve…") { CommandRouter.shared.execute(command: .changed, targetPath: root.rawPath) })
                    actions.append(.init("Commit…") { CommandRouter.shared.execute(command: .commit, targetPath: root.rawPath) })
                    actions.append(.init("Abort Merge") { confirmAndAbortMerge(root) })
                }
            }
            return actions
        })
    }

    @objc private func openCommit() {
        CommandRouter.shared.execute(command: .commit, targetPath: repositoryPath.rawPath)
    }

    @objc private func abortMerge() {
        Self.confirmAndAbortMerge(repositoryPath)
    }

    /// TortoiseGit's *Abort Merge*: `git merge --abort` after explaining that resolutions are lost.
    static func confirmAndAbortMerge(_ root: PangolinPath) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Abort the merge?"
        alert.informativeText = "The branch returns to its state before the merge. Conflict resolutions and other changes made since the merge started are lost; changes that were already uncommitted before it are kept where git can."
        alert.addButton(withTitle: "Abort Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ProgressWindowController.run(title: "Abort Merge", commands: [["merge", "--abort"]], workingDirectory: root)
    }

    @objc private func cancelClicked() {
        close()
    }
}
