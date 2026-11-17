import Foundation
import Cocoa
import PangolinGitCore

/// Create a patch (`git diff`) or apply one (`git apply`) — TortoiseGit's *Create Patch…* from the
/// Commit/Check-for-Modifications lists and *Apply Patch…* (`PatchViewDlg.cpp`, TortoiseMerge's
/// patch mode). For commit series use `FormatPatchWindowController` / `ApplyPatchSeriesWindowController`.
public final class PatchWindowController: NSWindowController {

    public enum PatchMode: Int {
        case create = 0
        case apply = 1
    }

    /// What the created patch contains.
    private enum Source: Int {
        case workingTree = 0, staged, revisions
    }

    public let repositoryPath: PangolinPath
    /// Repository-relative paths the patch is limited to (the Finder selection); empty = everything.
    private let paths: [String]

    private let modeSegment = NSSegmentedControl(labels: ["Create Patch", "Apply Patch"], trackingMode: .selectOne, target: nil, action: nil)
    private let createOptions = NSStackView()
    private let applyOptions = NSStackView()
    private let sourcePopup = NSPopUpButton()
    private let fromField = NSTextField()
    private let toField = NSTextField()
    private var rangeRow: NSStackView!
    private let binaryCheck = NSButton(checkboxWithTitle: "Include binary files (--binary)", target: nil, action: nil)
    private let patchFileField = NSTextField()
    private let threeWayCheck = NSButton(checkboxWithTitle: "3-way merge (--3way)", target: nil, action: nil)
    private let reverseCheck = NSButton(checkboxWithTitle: "Reverse (-R)", target: nil, action: nil)
    private let indexCheck = NSButton(checkboxWithTitle: "Also stage the changes (--index)", target: nil, action: nil)
    private let patchTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let checkButton = NSButton(title: "Check", target: nil, action: nil)
    private let actionButton = NSButton(title: "Save Patch…", target: nil, action: nil)

    /// - Parameters:
    ///   - paths: limit a created patch to these repository-relative paths.
    ///   - patchFile: start in apply mode with this file loaded.
    public init(repositoryPath: PangolinPath, initialMode: PatchMode = .create, paths: [String] = [], patchFile: URL? = nil) {
        self.repositoryPath = repositoryPath
        self.paths = paths.filter { !$0.isEmpty }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Patch — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 650, height: 450)
        super.init(window: window)
        setupUI()
        let mode: PatchMode = patchFile != nil ? .apply : initialMode
        modeSegment.selectedSegment = mode.rawValue
        updateMode(mode)
        if let patchFile {
            patchFileField.stringValue = patchFile.path
            loadPatchFile(url: patchFile)
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let container = window?.contentView else { return }

        modeSegment.target = self
        modeSegment.action = #selector(modeChanged)

        // Create options
        sourcePopup.addItems(withTitles: ["Uncommitted changes (HEAD → working tree)", "Staged changes only", "Between two revisions"])
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)
        fromField.placeholderString = "From"
        toField.placeholderString = "To"
        fromField.stringValue = "HEAD~1"
        toField.stringValue = "HEAD"
        for field in [fromField, toField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
            field.target = self
            field.action = #selector(refreshCreate)
        }
        rangeRow = NSStackView(views: [
            fromField, RevisionPickerButton(repository: repositoryPath) { [weak self] in self?.fromField.stringValue = $0; self?.refreshCreate() },
            NSTextField(labelWithString: "to"),
            toField, RevisionPickerButton(repository: repositoryPath) { [weak self] in self?.toField.stringValue = $0; self?.refreshCreate() }
        ])
        rangeRow.spacing = 6
        binaryCheck.state = .on
        binaryCheck.target = self
        binaryCheck.action = #selector(refreshCreate)
        let scope = NSTextField(labelWithString: paths.isEmpty ? "Whole working tree" : "Limited to: " + paths.joined(separator: ", "))
        scope.textColor = .secondaryLabelColor
        scope.lineBreakMode = .byTruncatingMiddle
        scope.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let firstRow = NSStackView(views: [sourcePopup, binaryCheck])
        firstRow.spacing = 12
        createOptions.orientation = .vertical
        createOptions.alignment = .leading
        createOptions.spacing = 6
        [firstRow, rangeRow, scope].forEach(createOptions.addArrangedSubview)

        // Apply options
        patchFileField.placeholderString = "Patch file to apply"
        patchFileField.target = self
        patchFileField.action = #selector(patchFileEntered)
        let browse = NSButton(title: "Browse…", target: self, action: #selector(browseFileClicked))
        browse.bezelStyle = .rounded
        let fileRow = NSStackView(views: [patchFileField, browse])
        fileRow.spacing = 6
        patchFileField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        threeWayCheck.state = .on
        let checks = NSStackView(views: [threeWayCheck, reverseCheck, indexCheck])
        checks.spacing = 16
        applyOptions.orientation = .vertical
        applyOptions.alignment = .leading
        applyOptions.spacing = 6
        [fileRow, checks].forEach(applyOptions.addArrangedSubview)

        // Patch text
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        patchTextView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        patchTextView.autoresizingMask = [.width]
        patchTextView.isVerticallyResizable = true
        patchTextView.isRichText = false
        patchTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        patchTextView.usesFindBar = true
        scroll.documentView = patchTextView

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Close", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        checkButton.target = self
        checkButton.action = #selector(checkClicked)
        checkButton.toolTip = "Test whether the patch applies, without changing anything (git apply --check)"
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        actionButton.keyEquivalent = "\r"
        let buttons = ToolDialog.buttonRow([cancel, checkButton, actionButton])
        buttons.insertView(statusLabel, at: 0, in: .leading)

        let stack = NSStackView(views: [modeSegment, createOptions, applyOptions, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate(LayoutHelper.pinEdges(stack, to: container) + [
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func modeChanged() {
        guard let mode = PatchMode(rawValue: modeSegment.selectedSegment) else { return }
        updateMode(mode)
    }

    private func updateMode(_ mode: PatchMode) {
        createOptions.isHidden = mode != .create
        applyOptions.isHidden = mode != .apply
        checkButton.isHidden = mode != .apply
        patchTextView.isEditable = mode == .create
        switch mode {
        case .create:
            actionButton.title = "Save Patch…"
            sourceChanged()
        case .apply:
            actionButton.title = "Apply Patch"
            patchTextView.string = ""
            if !patchFileField.stringValue.isEmpty {
                loadPatchFile(url: URL(fileURLWithPath: patchFileField.stringValue))
            } else {
                statusLabel.stringValue = "Select a patch file to review."
            }
        }
    }

    @objc private func sourceChanged() {
        rangeRow.isHidden = Source(rawValue: sourcePopup.indexOfSelectedItem) != .revisions
        refreshCreate()
    }

    private var diffArguments: [String] {
        var args = ["diff"]
        if binaryCheck.state == .on { args.append("--binary") }
        switch Source(rawValue: sourcePopup.indexOfSelectedItem) ?? .workingTree {
        case .workingTree: args.append("HEAD")
        case .staged: args.append("--cached")
        case .revisions:
            args.append(fromField.stringValue.trimmingCharacters(in: .whitespaces))
            args.append(toField.stringValue.trimmingCharacters(in: .whitespaces))
        }
        return args + ["--"] + paths
    }

    @objc private func refreshCreate() {
        statusLabel.stringValue = "Generating diff…"
        let args = diffArguments
        Task { @MainActor in
            do {
                let diffOut = try await GitCLIRunner.runAsync(arguments: args, workingDirectory: repositoryPath)
                self.patchTextView.string = diffOut
                self.statusLabel.stringValue = diffOut.isEmpty
                    ? "No changes found for this selection."
                    : "\(GitPatch.parse(unifiedDiff: diffOut).count) file(s), \(diffOut.components(separatedBy: .newlines).count) lines"
            } catch {
                self.patchTextView.string = ""
                self.statusLabel.stringValue = "Diff error: \(error.localizedDescription)"
            }
        }
    }

    @objc private func browseFileClicked() {
        let panel = NSOpenPanel()
        panel.title = "Open Patch File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        patchFileField.stringValue = url.path
        loadPatchFile(url: url)
    }

    @objc private func patchFileEntered() {
        let path = patchFileField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        loadPatchFile(url: URL(fileURLWithPath: path))
    }

    private func loadPatchFile(url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            patchTextView.textStorage?.setAttributedString(PatchViewerWindowController.colourised(content))
            var status = "\(GitPatch.parse(unifiedDiff: content).count) file(s) in \(url.lastPathComponent)"
            if GitPatchSeries.isMailboxPatch(content) {
                status += " — this is a commit patch; Apply Patch Serial keeps its author and message."
            }
            statusLabel.stringValue = status
        } catch {
            statusLabel.stringValue = "Failed to read patch: \(error.localizedDescription)"
        }
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    private var applyArguments: [String] {
        var args = ["apply", "-v"]
        if threeWayCheck.state == .on { args.append("--3way") }
        if reverseCheck.state == .on { args.append("-R") }
        if indexCheck.state == .on, threeWayCheck.state != .on { args.append("--index") }
        return args
    }

    @objc private func checkClicked() {
        let file = patchFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !file.isEmpty else { return }
        // --check cannot be combined with --3way's fallback; test the plain apply.
        let args = applyArguments.filter { $0 != "--3way" } + ["--check", file]
        statusLabel.stringValue = "Checking…"
        Task { @MainActor in
            let result = try? await GitCLIRunner().run(arguments: args, workingDirectory: repositoryPath)
            if let result, result.isSuccess {
                self.statusLabel.stringValue = "The patch applies cleanly."
                self.statusLabel.textColor = .systemGreen
            } else {
                self.statusLabel.stringValue = "The patch does not apply cleanly" + (self.threeWayCheck.state == .on ? "; a 3-way merge may still succeed." : ".")
                self.statusLabel.textColor = .systemOrange
                if let error = result?.standardError, !error.isEmpty {
                    ToolDialog.showMessage("Patch check failed", error, in: self.window, style: .warning)
                }
            }
        }
    }

    @objc private func actionClicked() {
        statusLabel.textColor = .secondaryLabelColor
        if modeSegment.selectedSegment == PatchMode.create.rawValue {
            let panel = NSSavePanel()
            panel.title = "Save Patch File"
            panel.nameFieldStringValue = "\(repositoryPath.filename).patch"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try patchTextView.string.write(to: url, atomically: true, encoding: .utf8)
                statusLabel.stringValue = "Saved to \(url.path)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                ToolDialog.showError(error, in: window)
            }
        } else {
            let file = patchFileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !file.isEmpty else {
                browseFileClicked()
                return
            }
            let root = repositoryPath
            window?.close()
            ProgressWindowController.run(title: "Apply Patch", commands: [applyArguments + [file]], workingDirectory: root,
                                         postActions: { outcome in
                guard outcome.succeeded else { return [] }
                return [.init("Check for Modifications…") { CommandRouter.shared.execute(command: .changed, targetPath: root.rawPath) },
                        .init("Commit…") { CommandRouter.shared.execute(command: .commit, targetPath: root.rawPath) }]
            })
        }
    }
}
