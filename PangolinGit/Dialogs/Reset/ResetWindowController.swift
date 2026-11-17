import Foundation
import Cocoa
import PangolinGitCore

/// Controller for Git Reset (`ResetDlg.cpp` in TortoiseGit).
/// Supports Soft, Mixed, Hard, Merge and Keep reset modes for the branch, and resetting only the
/// selected paths in the index (`git reset <rev> -- <paths>`) when opened on files or folders.
public final class ResetWindowController: NSWindowController {

    public let repositoryPath: PangolinPath
    /// Repository-relative paths to reset in the index; empty resets the branch.
    private let paths: [String]

    private var chooser: RevisionChooserView!
    private var modeRadios: [NSButton] = []
    private var warningLabel: NSTextField!
    /// "Reset only the selected paths", shown when opened on files or folders.
    private var pathsCheckbox: NSButton?

    /// Modes in the order of the radio buttons.
    private static let modes: [(argument: String, title: String)] = [
        ("--soft", "Soft — keep the working tree and the index (changes stay staged)"),
        ("--mixed", "Mixed — keep the working tree, reset the index (changes become unstaged)"),
        ("--hard", "Hard — discard all changes in the working tree and the index"),
        ("--merge", "Merge — reset, but keep local changes that the reset does not touch"),
        ("--keep", "Keep — reset, but abort if a file with local changes would be overwritten")
    ]

    public init(repositoryPath: PangolinPath, initialCommit: String = "HEAD", paths: [String] = []) {
        self.repositoryPath = repositoryPath
        self.paths = paths.filter { !$0.isEmpty }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Reset — \(repositoryPath.url.lastPathComponent)"

        super.init(window: window)
        setupUI(initialCommit: initialCommit)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(initialCommit: String) {
        guard let contentView = window?.contentView else { return }

        let lblCommit = NSTextField(labelWithString: "Reset to:")
        lblCommit.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        chooser = RevisionChooserView(repository: repositoryPath, initialRevision: initialCommit)

        let modeLabel = NSTextField(labelWithString: "Reset type:")
        modeLabel.font = NSFont.boldSystemFont(ofSize: 12)
        modeRadios = Self.modes.map { NSButton(radioButtonWithTitle: $0.title, target: self, action: #selector(radioChanged(_:))) }
        modeRadios[1].state = .on

        var views: [NSView] = [lblCommit, chooser]
        if !paths.isEmpty {
            // Path resets only touch the index (git allows no other mode with paths).
            pathsCheckbox = NSButton(checkboxWithTitle: "Reset only the selected paths in the index: " + paths.prefix(4).joined(separator: ", ")
                + (paths.count > 4 ? " … (\(paths.count))" : ""), target: self, action: #selector(pathsToggled))
            pathsCheckbox?.toolTip = "git reset <revision> -- <paths>: the working tree is not changed."
            views.append(pathsCheckbox!)
        }
        views.append(modeLabel)
        views += modeRadios

        warningLabel = NSTextField(labelWithString: "⚠️ Hard reset permanently loses uncommitted changes to tracked files.")
        warningLabel.textColor = .systemRed
        warningLabel.isHidden = true
        views.append(warningLabel)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: chooser)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // TortoiseGit's "Show modified files" opens a HEAD ↔ working tree comparison.
        let showModified = NSButton(title: "Show Modified Files", target: self, action: #selector(showModifiedClicked))
        showModified.bezelStyle = .rounded
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        let resetBtn = NSButton(title: "Reset", target: self, action: #selector(resetClicked))
        resetBtn.bezelStyle = .rounded
        resetBtn.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [showModified, spacer, cancelBtn, resetBtn])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        [stack, buttons].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 25),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -25),
            buttons.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 25),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -25),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -14)
        ])
    }

    @objc private func pathsToggled() {
        let pathsOnly = pathsCheckbox?.state == .on
        modeRadios.forEach { $0.isEnabled = !pathsOnly }
        warningLabel.isHidden = pathsOnly || modeRadios[2].state != .on
    }

    @objc private func radioChanged(_ sender: NSButton) {
        modeRadios.forEach { $0.state = $0 === sender ? .on : .off }
        warningLabel.isHidden = (modeRadios[2].state != .on)
    }

    @objc private func showModifiedClicked() {
        CommandRouter.shared.execute(command: .changed, targetPath: repositoryPath.rawPath)
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func resetClicked() {
        let target = chooser.revision
        guard !target.isEmpty else { return }
        let root = repositoryPath

        if !paths.isEmpty && pathsCheckbox?.state == .on {
            window?.close()
            ProgressWindowController.run(title: "Git Reset", commands: [["reset", "-q", target, "--"] + paths], workingDirectory: root)
            return
        }

        let index = modeRadios.firstIndex { $0.state == .on } ?? 1
        let modeArg = Self.modes[index].argument
        if modeArg == "--hard" {
            guard confirmHardReset() else { return }
        }

        window?.close()
        let hasSubmodules = FileManager.default.fileExists(atPath: root.appending(".gitmodules").rawPath)
        let bisecting = FileManager.default.fileExists(atPath: (GitRepository.open(at: root)?.gitDirectory.appending("BISECT_LOG").rawPath) ?? "")
        ProgressWindowController.run(title: "Git Reset", commands: [["reset", modeArg, target]], workingDirectory: root,
                                     postActions: { outcome in
            guard outcome.succeeded else { return [] }
            // TortoiseGit's reset post-commands.
            var actions: [ProgressWindowController.PostAction] = []
            if hasSubmodules {
                actions.append(.init("Update Submodules") {
                    ProgressWindowController.run(title: "Submodule Update", commands: [["submodule", "update", "--init", "--recursive"]],
                                                 workingDirectory: root)
                })
            }
            if bisecting {
                for verdict in ["good", "bad", "skip", "reset"] {
                    actions.append(.init("Bisect \(verdict.capitalized)") {
                        ProgressWindowController.run(title: "Bisect \(verdict.capitalized)", commands: [["bisect", verdict]], workingDirectory: root)
                    })
                }
            }
            if modeArg == "--hard" {
                actions.append(.init("Clean Up…") {
                    WindowRegistry.shared.present({ CleanupWindowController(repositoryPath: root) }, key: "cleanup|\(root.rawPath)", repository: root)
                })
            }
            return actions
        })
    }

    /// Hard-reset confirmation showing what is lost (`git diff --stat HEAD`).
    private func confirmHardReset() -> Bool {
        let stat = (try? GitCLIRunner.run(arguments: ["diff", "--stat", "--no-color", "HEAD"], workingDirectory: repositoryPath)) ?? ""
        let confirm = NSAlert()
        confirm.messageText = "Confirm Hard Reset"
        confirm.informativeText = stat.isEmpty
            ? "There are no uncommitted changes to tracked files. Commits that are only reachable from the current position may become hard to find."
            : "These uncommitted changes will be lost permanently:"
        confirm.alertStyle = .critical
        if !stat.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = stat
            text.autoresizingMask = [.width]
            scroll.documentView = text
            confirm.accessoryView = scroll
        }
        confirm.addButton(withTitle: "Proceed with Hard Reset")
        confirm.addButton(withTitle: "Cancel")
        return confirm.runModal() == .alertFirstButtonReturn
    }
}
