import Cocoa
import PangolinGitCore

/// Abort Merge dialog mirroring TortoiseGit's `CMergeAbortDlg` + `CAppUtils::MergeAbort`: leaves a
/// half-done merge with `git reset --merge` (keeps local changes that were not part of the merge),
/// `--mixed` or `--hard`. A stopped cherry-pick, revert, rebase or `git am` is offered its own
/// `--abort` first.
public final class AbortMergeWindowController: NSWindowController {

    private let repositoryPath: PangolinPath
    private let operation: GitOperationInProgress?

    private var radios: [NSButton] = []
    /// Arguments per radio button, in order.
    private var choices: [[String]] = []

    public init(repositoryPath: PangolinPath) {
        self.repositoryPath = repositoryPath
        self.operation = GitRepository.open(at: repositoryPath)?.operationInProgress
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Abort \(operation?.title ?? "Merge") — \(repositoryPath.filename)"
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let info: String
        switch operation {
        case .merge?: info = "A merge is in progress. Choose how to reset to the state before the merge:"
        case let op?: info = "A \(op.title.lowercased()) is in progress. Abort it, or reset the working tree:"
        case nil: info = "No merge is in progress. Resetting to HEAD still discards the changes the chosen type removes:"
        }
        let infoLabel = NSTextField(wrappingLabelWithString: info)

        var titles: [String] = []
        if let abort = operation?.abortArguments, let op = operation {
            titles.append("Abort the \(op.title.lowercased()) (git \(abort.joined(separator: " ")))")
            choices.append(abort)
        }
        titles += ["Merge — keep local changes that are not part of the merge (reset --merge)",
                   "Mixed — keep all changes in the working tree, unstaged (reset --mixed)",
                   "Hard — discard all changes in the working tree and index (reset --hard)"]
        choices += [["reset", "--merge", "HEAD"], ["reset", "--mixed", "HEAD"], ["reset", "--hard", "HEAD"]]
        radios = titles.map { NSButton(radioButtonWithTitle: $0, target: self, action: #selector(radioChanged(_:))) }
        radios.first?.state = .on

        let showModified = NSButton(title: "Show Modified Files", target: self, action: #selector(showModifiedClicked))
        showModified.bezelStyle = .rounded

        let stack = NSStackView(views: [infoLabel] + radios + [showModified])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: infoLabel)
        stack.setCustomSpacing(14, after: radios.last!)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Abort", target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, ok])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        [stack, buttons].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            infoLabel.widthAnchor.constraint(equalToConstant: 460),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -14)
        ])
    }

    @objc private func radioChanged(_ sender: NSButton) {
        radios.forEach { $0.state = $0 === sender ? .on : .off }
    }

    @objc private func showModifiedClicked() {
        CommandRouter.shared.execute(command: .changed, targetPath: repositoryPath.rawPath)
    }

    @objc private func cancelClicked() {
        close()
    }

    @objc private func okClicked() {
        guard let index = radios.firstIndex(where: { $0.state == .on }) else { return }
        let arguments = choices[index]
        if arguments.contains("--hard") {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Discard all local changes?"
            alert.informativeText = "A hard reset permanently removes every uncommitted change to tracked files."
            alert.addButton(withTitle: "Reset Hard")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let root = repositoryPath
        let hasSubmodules = FileManager.default.fileExists(atPath: root.appending(".gitmodules").rawPath)
        let title = "Abort " + (operation?.title ?? "Merge")
        close()
        ProgressWindowController.run(title: title,
                                     commands: [arguments], workingDirectory: root, postActions: { outcome in
            // TortoiseGit offers a submodule update after a hard reset.
            guard outcome.succeeded, hasSubmodules, arguments.contains("--hard") else { return [] }
            return [ProgressWindowController.PostAction("Update Submodules") {
                ProgressWindowController.run(title: "Submodule Update", commands: [["submodule", "update", "--init", "--recursive"]],
                                             workingDirectory: root)
            }]
        })
    }
}
