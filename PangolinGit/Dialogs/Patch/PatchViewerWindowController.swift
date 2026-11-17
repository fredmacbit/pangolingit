import Cocoa
import PangolinGitCore

/// Read-only viewer for `.patch` / `.diff` files opened from Finder (TortoiseGitUDiff): coloured
/// unified diff, Find bar, and hand-off to *Apply Patch* (`git apply`) or *Apply Patch Serial*
/// (`git am`, for format-patch mail files).
@MainActor
public final class PatchViewerWindowController: NSWindowController {

    public let fileURL: URL
    private let textView = NSTextView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private var content = ""

    public init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(window: ToolDialog.window(title: fileURL.lastPathComponent, repository: nil, width: 860, height: 640))
        window?.representedURL = fileURL
        setupUI()
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens (or brings forward) the viewer for `url`.
    static func present(_ url: URL) {
        WindowRegistry.shared.present({ PatchViewerWindowController(fileURL: url) }, key: "patchviewer|\(url.path)")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        let find = ClosureButton(title: "Find…") { [weak self] in
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            self?.window?.makeFirstResponder(self?.textView)
            self?.textView.performFindPanelAction(item)
        }
        let save = ClosureButton(title: "Save As…") { [weak self] in self?.saveAs() }
        let apply = ClosureButton(title: "Apply…") { [weak self] in self?.apply() }
        apply.keyEquivalent = "\r"
        let buttons = ToolDialog.buttonRow([find, save, apply])
        buttons.insertView(summaryLabel, at: 0, in: .leading)

        contentView.addSubview(scroll)
        contentView.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    private func load() {
        content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? (try? String(contentsOf: fileURL, encoding: .isoLatin1)) ?? ""
        textView.textStorage?.setAttributedString(Self.colourised(content))
        let files = GitPatch.parse(unifiedDiff: content)
        let added = files.flatMap(\.hunks).flatMap(\.lines).filter { $0.hasPrefix("+") }.count
        let removed = files.flatMap(\.hunks).flatMap(\.lines).filter { $0.hasPrefix("-") }.count
        var summary = "\(files.count) file(s), +\(added) −\(removed)"
        if GitPatchSeries.isMailboxPatch(content) {
            let header = GitPatchSeries.mailHeader(of: content)
            summary = "\(header.strippedSubject) — \(header.from) · " + summary
        }
        summaryLabel.stringValue = summary
    }

    /// Unified-diff colouring shared with the patch dialogs (TortoiseGitUDiff's lexer: headers,
    /// hunk markers, added and removed lines).
    static func colourised(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let result = NSMutableAttributedString()
        var inHeader = text.hasPrefix("From ")
        for rawLine in text.components(separatedBy: "\n") {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if rawLine.hasPrefix("diff --git") || rawLine.hasPrefix("Index: ") {
                inHeader = false
                attributes[.font] = bold
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor
            } else if inHeader {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                if rawLine.hasPrefix("Subject:") { attributes[.font] = bold; attributes[.foregroundColor] = NSColor.labelColor }
            } else if rawLine.hasPrefix("+++") || rawLine.hasPrefix("---") {
                attributes[.font] = bold
            } else if rawLine.hasPrefix("@@") {
                attributes[.foregroundColor] = DiffColors.modified
            } else if rawLine.hasPrefix("+") {
                attributes[.foregroundColor] = DiffColors.added
                attributes[.backgroundColor] = DiffColors.added.withAlphaComponent(0.08)
            } else if rawLine.hasPrefix("-") {
                attributes[.foregroundColor] = DiffColors.deleted
                attributes[.backgroundColor] = DiffColors.deleted.withAlphaComponent(0.08)
            } else if rawLine.hasPrefix("index ") || rawLine.hasPrefix("new file") || rawLine.hasPrefix("deleted file")
                        || rawLine.hasPrefix("similarity") || rawLine.hasPrefix("rename ") {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            result.append(NSAttributedString(string: rawLine + "\n", attributes: attributes))
        }
        return result
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ToolDialog.showError(error, in: window)
        }
    }

    /// Applies to the working tree that contains the patch, or one the user picks.
    private func apply() {
        var root = GitAdminDir.findRepository(startingAt: PangolinPath(url: fileURL.deletingLastPathComponent()))?.workingTreeRoot
        if root == nil {
            let panel = NSOpenPanel()
            panel.message = "Choose the working tree to apply “\(fileURL.lastPathComponent)” to"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            if let recent = ConfigManager.shared.recentRepositories.first {
                panel.directoryURL = URL(fileURLWithPath: recent)
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            root = GitAdminDir.findRepository(startingAt: PangolinPath(url: url))?.workingTreeRoot
        }
        guard let root else {
            ToolDialog.showMessage("Not a Git working tree", "Choose a folder inside a Git working tree.", in: window, style: .warning)
            return
        }
        if GitPatchSeries.isMailboxPatch(content) {
            WindowRegistry.shared.present({ ApplyPatchSeriesWindowController(repositoryPath: root, patches: [self.fileURL]) }, repository: root)
        } else {
            WindowRegistry.shared.present({ PatchWindowController(repositoryPath: root, initialMode: .apply, patchFile: self.fileURL) }, repository: root)
        }
    }
}
