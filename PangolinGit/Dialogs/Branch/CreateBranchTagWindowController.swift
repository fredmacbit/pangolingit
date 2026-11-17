import Cocoa
import PangolinGitCore

/// Create Branch or Tag dialog mirroring TortoiseGit's `CreateBranchTagDlg.cpp`: name with live
/// validation, *Base On* chooser, Track (tri-state) and branch description for branches, annotated /
/// signed tags with a message and *Push* right away, and *Switch to new branch* afterwards.
public final class CreateBranchTagWindowController: NSWindowController, NSTextFieldDelegate {

    private let repositoryPath: PangolinPath
    private var existingBranches: Set<String> = []
    private var existingTags: Set<String> = []

    private let modeSegment = NSSegmentedControl(labels: ["Branch", "Tag"], trackingMode: .selectOne, target: nil, action: nil)
    private let nameField = NSTextField()
    private var baseChooser: RevisionChooserView!
    private let trackCheckbox = NSButton(checkboxWithTitle: "Track", target: nil, action: nil)
    private let checkoutCheckbox = NSButton(checkboxWithTitle: "Switch to new branch", target: nil, action: nil)
    private let forceCheckbox = NSButton(checkboxWithTitle: "Force (overwrite if it exists)", target: nil, action: nil)
    private let signCheckbox = NSButton(checkboxWithTitle: "Sign (-s)", target: nil, action: nil)
    private let pushCheckbox = NSButton(checkboxWithTitle: "Push tag to", target: nil, action: nil)
    private let remotePopup = NSPopUpButton()
    private let messageLabel = NSTextField(labelWithString: "Description:")
    private let messageView = NSTextView()
    private var messageScroll: NSScrollView!
    private let statusLabel = NSTextField(wrappingLabelWithString: "Enter a branch name.")
    private let createButton = NSButton(title: "Create Branch", target: nil, action: nil)
    private var branchOnly: [NSView] = []
    private var tagOnly: [NSView] = []

    public init(repositoryPath: PangolinPath, initialBase: String = "HEAD", createTag: Bool = false) {
        self.repositoryPath = repositoryPath
        let window = NSWindow(
            contentRect: NSRect(x: 240, y: 240, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Create Branch / Tag - \(repositoryPath.filename)"
        window.minSize = NSSize(width: 520, height: 520)
        super.init(window: window)

        baseChooser = RevisionChooserView(repository: repositoryPath, initialRevision: initialBase)
        baseChooser.onChange = { [weak self] in self?.validate() }
        setupUI()
        modeSegment.selectedSegment = createTag ? 1 : 0
        onModeChanged()
        loadExisting()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        modeSegment.target = self
        modeSegment.action = #selector(onModeChanged)

        nameField.placeholderString = "e.g. feature/my-new-feature or v1.0.0"
        nameField.delegate = self

        trackCheckbox.allowsMixedState = true
        trackCheckbox.state = .mixed
        trackCheckbox.toolTip = "On: --track, off: --no-track, mixed: git's default (tracks only when based on a remote branch)"
        checkoutCheckbox.state = .on
        signCheckbox.target = self
        signCheckbox.action = #selector(onSignToggled)
        forceCheckbox.target = self
        forceCheckbox.action = #selector(onSignToggled)
        signCheckbox.toolTip = "GPG-sign the tag (needs user.signingkey); a signed tag needs a message"
        pushCheckbox.toolTip = "Push the new tag right away (git push <remote> refs/tags/<name>)"

        messageScroll = NSScrollView()
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        messageView.isRichText = false
        messageView.font = NSFont.systemFont(ofSize: 12)
        messageView.autoresizingMask = [.width]
        messageScroll.documentView = messageView

        statusLabel.textColor = .secondaryLabelColor

        createButton.target = self
        createButton.action = #selector(onCreateClicked)
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(onCancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let pushRow = NSStackView(views: [pushCheckbox, remotePopup])
        let branchRow = NSStackView(views: [trackCheckbox, checkoutCheckbox])
        branchRow.spacing = 16
        branchOnly = [branchRow]
        tagOnly = [signCheckbox, pushRow]

        let stack = NSStackView(views: [
            modeSegment, NSTextField(labelWithString: "Name:"), nameField, NSTextField(labelWithString: "Base On:"), baseChooser,
            branchRow, signCheckbox, pushRow, forceCheckbox, messageLabel, messageScroll, statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: modeSegment)
        stack.setCustomSpacing(12, after: nameField)
        stack.setCustomSpacing(12, after: baseChooser)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [cancelButton, createButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(buttons)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            modeSegment.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
            nameField.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            messageScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
            statusLabel.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func loadExisting() {
        let root = repositoryPath
        Task { @MainActor in
            let heads = (try? await GitCLIRunner.runAsync(arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads"], workingDirectory: root)) ?? ""
            let tags = (try? await GitCLIRunner.runAsync(arguments: ["for-each-ref", "--format=%(refname:short)", "refs/tags"], workingDirectory: root)) ?? ""
            let remotes = (try? await GitCLIRunner.runAsync(arguments: ["remote"], workingDirectory: root)) ?? ""
            self.existingBranches = Set(heads.split(separator: "\n").map(String.init))
            self.existingTags = Set(tags.split(separator: "\n").map(String.init))
            let remoteNames = remotes.split(separator: "\n").map(String.init)
            self.remotePopup.removeAllItems()
            self.remotePopup.addItems(withTitles: remoteNames)
            if remoteNames.contains("origin") { self.remotePopup.selectItem(withTitle: "origin") }
            self.pushCheckbox.isEnabled = !remoteNames.isEmpty
            self.remotePopup.isEnabled = !remoteNames.isEmpty
            self.validate()
        }
    }

    private var isBranch: Bool { modeSegment.selectedSegment == 0 }
    private var name: String { nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var message: String { messageView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    @objc private func onModeChanged() {
        createButton.title = isBranch ? "Create Branch" : "Create Tag"
        branchOnly.forEach { $0.isHidden = !isBranch }
        tagOnly.forEach { $0.isHidden = isBranch }
        messageLabel.stringValue = isBranch ? "Description (optional, shown in Browse References):" : "Message (makes an annotated tag):"
        validate()
    }

    @objc private func onSignToggled() {
        validate()
    }

    public func controlTextDidChange(_ obj: Notification) {
        validate()
    }

    /// Live name check (`git check-ref-format` rules), clash with an existing ref, and the signed-tag message rule.
    @discardableResult
    private func validate() -> Bool {
        var text = isBranch ? "Enter a branch name." : "Enter a tag name."
        var ok = false
        let name = self.name
        if !name.isEmpty {
            if let error = GitRefName.validationError(name) {
                text = error
            } else if isBranch && existingBranches.contains(name) && forceCheckbox.state == .off {
                text = "Branch “\(name)” already exists (tick Force to move it)."
            } else if !isBranch && existingTags.contains(name) && forceCheckbox.state == .off {
                text = "Tag “\(name)” already exists (tick Force to move it)."
            } else if !isBranch && signCheckbox.state == .on && message.isEmpty {
                text = "A signed tag needs a message."
            } else {
                ok = true
                let clash = isBranch ? existingTags.contains(name) : existingBranches.contains(name)
                text = clash ? "A \(isBranch ? "tag" : "branch") with this name exists too; the name will be ambiguous."
                    : "Based on \(baseChooser.revision.isEmpty ? "HEAD" : baseChooser.revision)."
            }
        }
        statusLabel.stringValue = text
        statusLabel.textColor = ok || name.isEmpty ? .secondaryLabelColor : .systemRed
        createButton.isEnabled = ok || name.isEmpty
        return ok
    }

    @objc private func onCreateClicked() {
        guard validate() else {
            if name.isEmpty { statusLabel.stringValue = "Name cannot be empty." }
            return
        }
        let name = self.name
        let base = baseChooser.revision.isEmpty ? "HEAD" : baseChooser.revision
        let force = forceCheckbox.state == .on
        var commands: [[String]] = []
        var title: String
        var switchAfter = false

        if isBranch {
            title = "Create Branch \(name)"
            var args = ["branch"]
            if trackCheckbox.state != .mixed { args.append(trackCheckbox.state == .on ? "--track" : "--no-track") }
            if force { args.append("--force") }
            commands.append(args + [name, base])
            if !message.isEmpty {
                commands.append(["config", "branch.\(name).description", message])
            }
            if checkoutCheckbox.state == .on {
                switchAfter = true
            }
        } else {
            title = "Create Tag \(name)"
            var args = ["tag"]
            if force { args.append("--force") }
            if signCheckbox.state == .on {
                args += ["--sign", "-m", message]
            } else if !message.isEmpty {
                args += ["--annotate", "-m", message]
            }
            commands.append(args + [name, base])
            if pushCheckbox.state == .on, let remote = remotePopup.titleOfSelectedItem {
                commands.append(["push", "--progress", remote, "refs/tags/\(name)"])
                title += " and Push"
            }
        }

        let root = repositoryPath
        if switchAfter {
            // Creation and switch run together, with the Switch dialog's stash offer.
            Task { @MainActor in
                let decision = await DirtyWorkingTree.prepare(root, operation: "switch", allowContinue: true, window: self.window)
                guard decision != .cancel else { return }
                self.close()
                Self.createAndSwitch(title: title, commands: commands, branch: name, root: root, stashed: decision == .stashed)
            }
        } else {
            close()
            ProgressWindowController.run(title: title, commands: commands, workingDirectory: root)
        }
    }

    private static func createAndSwitch(title: String, commands: [[String]], branch: String, root: PangolinPath, stashed: Bool) {
        let hasSubmodules = FileManager.default.fileExists(atPath: root.appending(".gitmodules").rawPath)
        ProgressWindowController.run(title: title, commands: commands + [["checkout", branch, "--"]], workingDirectory: root, postActions: { outcome in
            var actions: [ProgressWindowController.PostAction] = []
            guard outcome.succeeded else { return actions }
            if stashed { actions.append(DirtyWorkingTree.stashPopAction(root)) }
            if hasSubmodules {
                actions.append(.init("Update Submodules") {
                    ProgressWindowController.run(title: "Update Submodules", commands: [["submodule", "update", "--init", "--recursive", "--progress"]],
                                                 workingDirectory: root)
                })
            }
            return actions
        })
    }

    @objc private func onCancelClicked() {
        close()
    }
}
