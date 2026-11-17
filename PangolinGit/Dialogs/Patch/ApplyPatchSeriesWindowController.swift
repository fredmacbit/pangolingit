import Cocoa
import PangolinGitCore

/// *Apply Patch Serial…* (TortoiseGit's `ImportPatchDlg.cpp`): applies an ordered list of
/// format-patch files as commits with `git am`, with Abort / Skip / Resolved when a patch fails
/// and detection of an `am` session that is still in progress.
@MainActor
public final class ApplyPatchSeriesWindowController: NSWindowController {

    public let repositoryPath: PangolinPath

    private let fileList = PatchFileListView()
    private let previewView = NSTextView()
    private let threeWayCheck = NSButton(checkboxWithTitle: "3-way merge (--3way)", target: nil, action: nil)
    private let ignoreSpaceCheck = NSButton(checkboxWithTitle: "Ignore space changes (--ignore-space-change)", target: nil, action: nil)
    private let signOffCheck = NSButton(checkboxWithTitle: "Add Signed-off-by (--signoff)", target: nil, action: nil)
    private let keepCRCheck = NSButton(checkboxWithTitle: "Keep carriage returns (--keep-cr)", target: nil, action: nil)
    private let sessionBanner = NSStackView()
    private let sessionLabel = NSTextField(wrappingLabelWithString: "")
    private var applyButton: NSButton!

    public init(repositoryPath: PangolinPath, patches: [URL] = []) {
        self.repositoryPath = repositoryPath
        super.init(window: ToolDialog.window(title: "Apply Patch Serial", repository: repositoryPath, width: 760, height: 560))
        setupUI()
        fileList.add(patches)
        if let first = patches.first { showPreview(first) }
        checkSession()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.checkSession() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        sessionLabel.textColor = .systemOrange
        sessionBanner.orientation = .horizontal
        sessionBanner.spacing = 8
        sessionBanner.addArrangedSubview(sessionLabel)
        for (title, step) in [("Resolved", "--continue"), ("Skip", "--skip"), ("Abort", "--abort")] {
            let button = ClosureButton(title: title) { [weak self] in self?.runSessionStep(step) }
            button.bezelStyle = .rounded
            sessionBanner.addArrangedSubview(button)
        }
        sessionBanner.isHidden = true

        fileList.onOpen = { [weak self] url in self?.showPreview(url) }
        fileList.onChange = { [weak self] in self?.updateButtons() }

        previewView.isEditable = false
        previewView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        previewView.isVerticallyResizable = true
        previewView.autoresizingMask = [.width]
        let previewScroll = NSScrollView()
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .bezelBorder
        previewScroll.documentView = previewView
        previewScroll.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(fileList)
        split.addArrangedSubview(previewScroll)

        threeWayCheck.state = .on
        let options = NSGridView(views: [[threeWayCheck, signOffCheck], [ignoreSpaceCheck, keepCRCheck]])
        options.rowSpacing = 4
        options.columnSpacing = 24

        let cancel = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        cancel.keyEquivalent = "\u{1b}"
        applyButton = NSButton(title: "Apply", target: self, action: #selector(applyClicked))
        applyButton.keyEquivalent = "\r"
        let buttons = ToolDialog.buttonRow([cancel, applyButton])

        let hint = ToolDialog.label("Patches are applied in list order. Drag files here, drag rows to reorder, double-click to preview.")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack = NSStackView(views: [sessionBanner, hint, split, options, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate(LayoutHelper.pinEdges(stack, to: content) + [
            split.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fileList.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        updateButtons()
    }

    private func updateButtons() {
        applyButton?.isEnabled = !fileList.files.isEmpty && sessionBanner.isHidden
    }

    private func showPreview(_ url: URL) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        previewView.textStorage?.setAttributedString(PatchViewerWindowController.colourised(text))
    }

    /// TortoiseGit refuses to start while `rebase-apply` exists and offers to finish that session.
    private func checkSession() {
        let root = repositoryPath
        Task { @MainActor in
            let path = (try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "--git-path", "rebase-apply"], workingDirectory: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let absolute = path.hasPrefix("/") ? path : root.appendingPathComponent(path).rawPath
            let fm = FileManager.default
            if !path.isEmpty, fm.fileExists(atPath: absolute) {
                let isAm = fm.fileExists(atPath: absolute + "/applying")
                self.sessionLabel.stringValue = isAm
                    ? "A previous “git am” did not finish. Resolve the conflicts and choose Resolved, skip the current patch, or abort."
                    : "A rebase is in progress; finish or abort it before applying patches."
                self.sessionBanner.arrangedSubviews.dropFirst().forEach { $0.isHidden = !isAm }
                self.sessionBanner.isHidden = false
            } else {
                self.sessionBanner.isHidden = true
            }
            self.updateButtons()
        }
    }

    private func runSessionStep(_ step: String) {
        Self.runAm(["am", step], repository: repositoryPath, title: "Apply Patch Serial (\(step.dropFirst(2)))")
    }

    @objc private func closeClicked() {
        window?.close()
    }

    @objc private func applyClicked() {
        let args = GitPatchSeries.amArguments(
            files: fileList.files.map(\.path),
            threeWay: threeWayCheck.state == .on,
            ignoreSpaceChange: ignoreSpaceCheck.state == .on,
            signOff: signOffCheck.state == .on,
            keepCR: keepCRCheck.state == .on
        )
        Self.runAm(args, repository: repositoryPath, title: "Apply Patch Serial")
    }

    /// Runs one `git am` step; on failure offers the same Resolved / Skip / Abort choices as
    /// TortoiseGit's dialog, so a conflicted series can be finished from the progress window.
    static func runAm(_ args: [String], repository: PangolinPath, title: String) {
        ProgressWindowController.run(title: title, commands: [args], workingDirectory: repository, postActions: { outcome in
            if outcome.succeeded {
                return [.init("Show Log") { CommandRouter.shared.execute(command: .log, targetPath: repository.rawPath) }]
            }
            return [
                .init("Check for Modifications…") { CommandRouter.shared.execute(command: .changed, targetPath: repository.rawPath) },
                .init("Resolved") { runAm(["am", "--continue"], repository: repository, title: "Apply Patch Serial (continue)") },
                .init("Skip") { runAm(["am", "--skip"], repository: repository, title: "Apply Patch Serial (skip)") },
                .init("Abort") { runAm(["am", "--abort"], repository: repository, title: "Apply Patch Serial (abort)") }
            ]
        })
    }
}
