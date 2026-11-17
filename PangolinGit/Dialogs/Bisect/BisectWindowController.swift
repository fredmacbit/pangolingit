import Foundation
import Cocoa
import PangolinGitCore

/// Git Bisect window (`BisectStartDlg.cpp` and the bisect commands of TortoiseGit): start with a
/// good and a bad revision (pickers, optional path limit and custom terms), then mark each checked-out
/// commit good / bad / skip, run a test script automatically (`git bisect run`), and reset. Offers to
/// stash local changes first and can update submodules after every step.
public final class BisectWindowController: NSWindowController {

    public let repositoryPath: PangolinPath

    private var isBisecting = false
    /// Terms of the running bisect (`git bisect terms`): good/bad or custom ones like old/new.
    private var termGood = "good"
    private var termBad = "bad"

    private let infoLabel = NSTextField(wrappingLabelWithString: "Bisect not active. Specify good and bad commits to begin the binary search.")
    private let logTextView = NSTextView()
    private let goodButton = NSButton(title: "Mark Good", target: nil, action: nil)
    private let badButton = NSButton(title: "Mark Bad", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip Commit", target: nil, action: nil)
    private let runButton = NSButton(title: "Run Script…", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset / Finish", target: nil, action: nil)
    private let startButton = NSButton(title: "Start Bisect", target: nil, action: nil)

    private let badCommitField = NSTextField(string: "HEAD")
    private let goodCommitField = NSTextField()
    private let pathsField = NSTextField()
    private let termOldField = NSTextField()
    private let termNewField = NSTextField()
    private let submodulesCheckbox = NSButton(checkboxWithTitle: "Update submodules after each step", target: nil, action: nil)
    private var startControls: [NSControl] = []

    /// - Parameters:
    ///   - good / bad: preset range (Log ▸ *Bisect start* with two selected commits).
    public init(repositoryPath: PangolinPath, good: String? = nil, bad: String? = nil) {
        self.repositoryPath = repositoryPath

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Bisect — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 640, height: 480)

        super.init(window: window)
        if let good { goodCommitField.stringValue = good }
        if let bad { badCommitField.stringValue = bad }
        setupUI()
        checkBisectStatus()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.checkBisectStatus() }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        goodCommitField.placeholderString = "tag or commit, e.g. v1.0"
        pathsField.placeholderString = "optional: only commits touching these paths (space separated)"
        termOldField.placeholderString = "good"
        termNewField.placeholderString = "bad"
        let badPicker = RevisionPickerButton(repository: repositoryPath) { [weak self] in self?.badCommitField.stringValue = $0 }
        let goodPicker = RevisionPickerButton(repository: repositoryPath) { [weak self] in self?.goodCommitField.stringValue = $0 }
        submodulesCheckbox.state = FileManager.default.fileExists(atPath: repositoryPath.appending(".gitmodules").rawPath) ? .on : .off
        submodulesCheckbox.toolTip = "Run git submodule update after each checkout so submodules match the tested commit"
        startButton.target = self
        startButton.action = #selector(startBisectClicked)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Bad (broken) commit:"), NSStackView(views: [badCommitField, badPicker])],
            [NSTextField(labelWithString: "Good (working) commit:"), NSStackView(views: [goodCommitField, goodPicker])],
            [NSTextField(labelWithString: "Limit to paths:"), pathsField],
            [NSTextField(labelWithString: "Custom terms:"), NSStackView(views: [NSTextField(labelWithString: "old"), termOldField,
                                                                                 NSTextField(labelWithString: "new"), termNewField])],
        ])
        grid.rowSpacing = 6
        grid.rowAlignment = .firstBaseline
        badCommitField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        goodCommitField.widthAnchor.constraint(equalTo: badCommitField.widthAnchor).isActive = true
        termOldField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        termNewField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        termOldField.toolTip = "Use other words than good/bad, e.g. old/new when looking for the commit that changed a behaviour (--term-old)"
        termNewField.toolTip = "Term for the commits after the change (--term-new)"
        startControls = [badCommitField, goodCommitField, pathsField, termOldField, termNewField, badPicker, goodPicker, startButton]

        infoLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logTextView.isEditable = false
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.autoresizingMask = [.width]
        scroll.documentView = logTextView

        for (button, action) in [(goodButton, #selector(markGoodClicked)), (badButton, #selector(markBadClicked)),
                                 (skipButton, #selector(skipClicked)), (runButton, #selector(runScriptClicked)),
                                 (resetButton, #selector(resetBisectClicked))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        runButton.toolTip = "Let git test each commit with a script: exit 0 = good, 125 = skip, other = bad (git bisect run)"
        let stepRow = NSStackView(views: [goodButton, badButton, skipButton, runButton, NSView(), resetButton])

        let stack = NSStackView(views: [grid, NSStackView(views: [submodulesCheckbox, NSView(), startButton]), infoLabel, scroll, stepRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in stack.arrangedSubviews where view !== grid {
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        updateButtonStates()
    }

    private func updateButtonStates() {
        startControls.forEach { $0.isEnabled = !isBisecting }
        for button in [goodButton, badButton, skipButton, runButton, resetButton] {
            button.isEnabled = isBisecting
        }
        goodButton.title = "Mark \(termGood.capitalized)"
        badButton.title = "Mark \(termBad.capitalized)"
    }

    private func checkBisectStatus() {
        let root = repositoryPath
        Task { @MainActor in
            let gitDir = GitRepository.open(at: root)?.gitDirectory
            let bisecting = gitDir.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("BISECT_START").rawPath) } ?? false
            self.isBisecting = bisecting
            if bisecting {
                let terms = (try? await GitCLIRunner.runAsync(arguments: ["bisect", "terms", "--term-good"], workingDirectory: root))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let badTerm = (try? await GitCLIRunner.runAsync(arguments: ["bisect", "terms", "--term-bad"], workingDirectory: root))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.termGood = (terms?.isEmpty ?? true) ? "good" : terms!
                self.termBad = (badTerm?.isEmpty ?? true) ? "bad" : badTerm!
                let log = (try? await GitCLIRunner.runAsync(arguments: ["bisect", "log"], workingDirectory: root)) ?? ""
                let head = (try? await GitCLIRunner.runAsync(arguments: ["log", "-1", "--format=%h %s", "HEAD"], workingDirectory: root))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.logTextView.string = log
                self.infoLabel.stringValue = "Testing [\(head)]. Build and test it, then mark it \(self.termGood) or \(self.termBad):"
            } else {
                self.termGood = "good"
                self.termBad = "bad"
            }
            self.updateButtonStates()
        }
    }

    @objc private func startBisectClicked() {
        let good = goodCommitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = badCommitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !good.isEmpty && !bad.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Missing Commit Information"
            alert.informativeText = "Please specify both a known good commit and a broken bad commit to start bisecting."
            alert.runModal()
            return
        }
        var args = ["bisect", "start"]
        let termOld = termOldField.stringValue.trimmingCharacters(in: .whitespaces)
        let termNew = termNewField.stringValue.trimmingCharacters(in: .whitespaces)
        if !termOld.isEmpty { args += ["--term-old=\(termOld)"] }
        if !termNew.isEmpty { args += ["--term-new=\(termNew)"] }
        args += [bad, good]
        let paths = pathsField.stringValue.split(separator: " ").map(String.init)
        if !paths.isEmpty { args += ["--"] + paths }

        let root = repositoryPath
        Task { @MainActor in
            // TortoiseGit offers to stash first: every bisect step checks out another commit.
            let decision = await DirtyWorkingTree.prepare(root, operation: "bisect", allowContinue: true, window: self.window)
            guard decision != .cancel else { return }
            self.runStep(args, title: "Bisect Start")
        }
    }

    @objc private func markGoodClicked() {
        runStep(["bisect", termGood], title: "Bisect \(termGood.capitalized)")
    }

    @objc private func markBadClicked() {
        runStep(["bisect", termBad], title: "Bisect \(termBad.capitalized)")
    }

    @objc private func skipClicked() {
        runStep(["bisect", "skip"], title: "Bisect Skip")
    }

    /// Runs one bisect command and shows its output; with *Update submodules* the submodules follow the
    /// checked-out commit (TortoiseGit's post-step action). Announces the culprit when git found it.
    private func runStep(_ args: [String], title: String) {
        let root = repositoryPath
        let updateSubmodules = submodulesCheckbox.state == .on
        for button in [goodButton, badButton, skipButton, startButton] { button.isEnabled = false }
        infoLabel.stringValue = "\(title)…"
        Task { @MainActor in
            let result = try? await GitCLIRunner().run(arguments: args, workingDirectory: root)
            let output = ((result?.standardOutput ?? "") + (result?.standardError ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            if updateSubmodules && result?.isSuccess == true {
                _ = try? await GitCLIRunner().run(arguments: ["submodule", "update", "--init", "--recursive"], workingDirectory: root)
            }
            self.checkBisectStatus()
            self.logTextView.string = output
            if result?.isSuccess != true {
                let alert = NSAlert()
                alert.messageText = "\(title) failed"
                alert.informativeText = output.isEmpty ? "git could not be run." : output
                alert.runModal()
            } else if output.contains("is the first bad commit") || output.contains("is the first \(self.termBad) commit") {
                self.announceCulprit(output)
            }
        }
    }

    private func announceCulprit(_ output: String) {
        let alert = NSAlert()
        alert.messageText = "Culprit commit found"
        alert.informativeText = String(output.prefix(1500))
        alert.addButton(withTitle: "Reset Bisect")
        alert.addButton(withTitle: "Keep Bisect State")
        if alert.runModal() == .alertFirstButtonReturn {
            resetBisectClicked()
        }
    }

    /// `git bisect run <script>`: git tests every step itself; the output streams in the progress window.
    @objc private func runScriptClicked() {
        let panel = NSOpenPanel()
        panel.message = "Choose an executable test script: exit code 0 = \(termGood), 125 = skip, anything else = \(termBad)."
        panel.directoryURL = repositoryPath.url
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let script = panel.url?.path else { return }
        let root = repositoryPath
        ProgressWindowController.run(title: "Bisect Run", commands: [["bisect", "run", script]], workingDirectory: root, postActions: { [weak self] outcome in
            guard outcome.succeeded else { return [] }
            return [.init("Reset Bisect") { self?.resetBisectClicked() }]
        })
    }

    @objc private func resetBisectClicked() {
        let root = repositoryPath
        ProgressWindowController.run(title: "Bisect Reset", commands: [["bisect", "reset"]], workingDirectory: root, postActions: { outcome in
            outcome.succeeded && FileManager.default.fileExists(atPath: root.appending(".gitmodules").rawPath)
                ? [.init("Update Submodules") {
                    ProgressWindowController.run(title: "Update Submodules", commands: [["submodule", "update", "--init", "--recursive", "--progress"]],
                                                 workingDirectory: root)
                }]
                : []
        })
        infoLabel.stringValue = "Bisect reset. The repository returns to the branch you started from."
        logTextView.string = ""
    }
}
