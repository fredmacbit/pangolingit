import Cocoa
import PangolinGitCore

/// *Create Patch Serial…* (TortoiseGit's `FormatPatchDlg.cpp` / `FormatPatchCommand.cpp`): one
/// `.patch` file per commit via `git format-patch`, so recipients can apply them with `git am`.
@MainActor
public final class FormatPatchWindowController: NSWindowController {

    public let repositoryPath: PangolinPath

    private let directoryField = NSTextField()
    private let sinceRadio = NSButton(radioButtonWithTitle: "Since:", target: nil, action: nil)
    private let countRadio = NSButton(radioButtonWithTitle: "Number of commits:", target: nil, action: nil)
    private let rangeRadio = NSButton(radioButtonWithTitle: "Range from:", target: nil, action: nil)
    private let sinceField = NSTextField()
    private let countField = NSTextField()
    private let countStepper = NSStepper()
    private let fromField = NSTextField()
    private let toField = NSTextField()
    private let noPrefixCheck = NSButton(checkboxWithTitle: "No a/ b/ prefixes (--no-prefix)", target: nil, action: nil)
    private let binaryCheck = NSButton(checkboxWithTitle: "Include binary changes (--binary)", target: nil, action: nil)
    private let sendMailCheck = NSButton(checkboxWithTitle: "Send mail after create", target: nil, action: nil)

    /// - Parameters:
    ///   - since: preselects *Since* (TortoiseGit `/startrev` without `/endrev`).
    ///   - from/to: preselect *Range* (`/startrev` + `/endrev`), e.g. from a Log multi-selection.
    public init(repositoryPath: PangolinPath, since: String? = nil, from: String? = nil, to: String? = nil) {
        self.repositoryPath = repositoryPath
        super.init(window: ToolDialog.window(title: "Create Patch Serial", repository: repositoryPath, width: 600, height: 400, resizable: false))
        setupUI()
        configureInitialValues(since: since, from: from, to: to)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        directoryField.placeholderString = "Folder for the .patch files"
        let directoryRow = ToolDialog.folderRow(field: directoryField, title: "Choose the Output Folder")

        for radio in [sinceRadio, countRadio, rangeRadio] {
            radio.target = self
            radio.action = #selector(rangeModeChanged(_:))
        }
        sinceField.placeholderString = "e.g. origin/main"
        let sinceRow = NSStackView(views: [sinceField, picker(for: sinceField)])
        sinceRow.spacing = 6

        countField.stringValue = "1"
        countField.formatter = NumberFormatter()
        countField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        countStepper.minValue = 1
        countStepper.maxValue = 9999
        countStepper.integerValue = 1
        countStepper.target = self
        countStepper.action = #selector(stepperChanged)
        let countRow = NSStackView(views: [countField, countStepper, ToolDialog.label("(from HEAD)")])
        countRow.spacing = 4

        fromField.placeholderString = "older revision"
        toField.stringValue = "HEAD"
        let rangeRow = NSStackView(views: [fromField, picker(for: fromField), ToolDialog.label("to:"), toField, picker(for: toField)])
        rangeRow.spacing = 6
        fromField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        toField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        let rangeGrid = NSGridView(views: [
            [sinceRadio, sinceRow],
            [countRadio, countRow],
            [rangeRadio, rangeRow]
        ])
        rangeGrid.rowSpacing = 8
        rangeGrid.columnSpacing = 8
        rangeGrid.rowAlignment = .firstBaseline
        let rangeBox = NSBox()
        rangeBox.title = "Version"
        rangeBox.contentView = NSView()
        rangeGrid.translatesAutoresizingMaskIntoConstraints = false
        rangeBox.contentView?.addSubview(rangeGrid)
        if let boxContent = rangeBox.contentView {
            NSLayoutConstraint.activate(LayoutHelper.pinEdges(rangeGrid, to: boxContent, insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)))
        }

        noPrefixCheck.state = .off
        binaryCheck.state = .on
        let options = NSStackView(views: [noPrefixCheck, binaryCheck, sendMailCheck])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 6

        let saveDiff = ClosureButton(title: "Save Unified Diff…") { [weak self] in self?.saveUnifiedDiff() }
        saveDiff.toolTip = "Save the chosen range as one unified diff (git diff) instead of a patch series"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Create Patches", target: self, action: #selector(createClicked))
        ok.keyEquivalent = "\r"
        let buttons = ToolDialog.buttonRow([cancel, ok])
        saveDiff.bezelStyle = .rounded
        buttons.insertView(saveDiff, at: 0, in: .leading)

        let stack = NSStackView(views: [ToolDialog.label("Save patches to:", bold: true), directoryRow, rangeBox, options, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate(LayoutHelper.pinEdges(stack, to: content) + [
            rangeBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            directoryRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func picker(for field: NSTextField) -> NSButton {
        RevisionPickerButton(repository: repositoryPath) { [weak field] revision in field?.stringValue = revision }
    }

    private func configureInitialValues(since: String?, from: String?, to: String?) {
        let remembered = ConfigManager.shared.formatPatchDirectory
        directoryField.stringValue = remembered.isEmpty ? repositoryPath.rawPath : remembered
        if let from {
            fromField.stringValue = from
            toField.stringValue = to ?? "HEAD"
            select(rangeRadio)
        } else if let since {
            sinceField.stringValue = since
            fromField.stringValue = "\(since)~1"
            toField.stringValue = since
            select(sinceRadio)
        } else {
            select(sinceRadio)
            // TortoiseGit preselects the upstream so "everything not pushed yet" is one click.
            Task { @MainActor in
                let upstream = (try? await GitCLIRunner.runAsync(
                    arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], workingDirectory: repositoryPath
                ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if self.sinceField.stringValue.isEmpty, !upstream.isEmpty {
                    self.sinceField.stringValue = upstream
                }
            }
        }
    }

    private func select(_ radio: NSButton) {
        for candidate in [sinceRadio, countRadio, rangeRadio] {
            candidate.state = candidate === radio ? .on : .off
        }
        sinceField.isEnabled = radio === sinceRadio
        countField.isEnabled = radio === countRadio
        countStepper.isEnabled = radio === countRadio
        fromField.isEnabled = radio === rangeRadio
        toField.isEnabled = radio === rangeRadio
    }

    @objc private func rangeModeChanged(_ sender: NSButton) {
        select(sender)
    }

    @objc private func stepperChanged() {
        countField.integerValue = countStepper.integerValue
    }

    /// The chosen range, or nil (with a message) when it is incomplete.
    private func chosenRange() -> GitPatchSeries.Range? {
        let trim: (NSTextField) -> String = { $0.stringValue.trimmingCharacters(in: .whitespaces) }
        if sinceRadio.state == .on {
            guard !trim(sinceField).isEmpty else { return complain("Enter the revision to start after.") }
            return .since(trim(sinceField))
        }
        if countRadio.state == .on {
            guard countField.integerValue > 0 else { return complain("Enter how many commits to export.") }
            return .last(countField.integerValue)
        }
        guard !trim(fromField).isEmpty, !trim(toField).isEmpty else { return complain("Enter both ends of the range.") }
        return .between(from: trim(fromField), to: trim(toField))
    }

    private func complain(_ message: String) -> GitPatchSeries.Range? {
        ToolDialog.showMessage("Incomplete range", message, in: window, style: .warning)
        return nil
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func createClicked() {
        let directory = directoryField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !directory.isEmpty else {
            ToolDialog.showMessage("No output folder", "Choose where the patch files are written.", in: window, style: .warning)
            return
        }
        guard let range = chosenRange() else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        ConfigManager.shared.formatPatchDirectory = directory

        let args = GitPatchSeries.formatPatchArguments(range: range, outputDirectory: directory,
                                                       noPrefix: noPrefixCheck.state == .on, binary: binaryCheck.state == .on)
        let sendMail = sendMailCheck.state == .on
        let root = repositoryPath
        window?.close()
        ProgressWindowController.run(
            title: "Create Patch Serial", commands: [args], workingDirectory: root,
            postActions: { outcome in
                guard outcome.succeeded else { return [] }
                let files = GitPatchSeries.writtenFiles(fromFormatPatchOutput: outcome.output).map { URL(fileURLWithPath: $0) }
                return [
                    .init("Show in Finder") {
                        if files.isEmpty {
                            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting(files)
                        }
                    },
                    .init("Send Mail…") { SendMailWindowController.present(repository: root, patches: files) }
                ]
            },
            onFinish: { outcome in
                guard outcome.succeeded, sendMail else { return }
                let files = GitPatchSeries.writtenFiles(fromFormatPatchOutput: outcome.output).map { URL(fileURLWithPath: $0) }
                SendMailWindowController.present(repository: root, patches: files)
            }
        )
    }

    /// Writes the chosen range as one `git diff` file (the dialog's *Save unified diff* button).
    private func saveUnifiedDiff() {
        guard let range = chosenRange() else { return }
        let diffRange: [String]
        switch range {
        case .since(let ref): diffRange = ["\(ref)..HEAD"]
        case .last(let count): diffRange = ["HEAD~\(count)..HEAD"]
        case .between(let from, let to): diffRange = ["\(from)..\(to)"]
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(repositoryPath.filename).diff"
        guard let window, panel.runModal() == .OK, let url = panel.url else { return }
        let root = repositoryPath
        Task { @MainActor in
            do {
                let data = try await GitCLIRunner.runDataAsync(arguments: ["diff", "--binary"] + diffRange, workingDirectory: root)
                try data.write(to: url, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                ToolDialog.showError(error, in: window)
            }
        }
    }
}
