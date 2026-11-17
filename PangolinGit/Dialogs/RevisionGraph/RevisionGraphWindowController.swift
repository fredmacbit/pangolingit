import Cocoa
import UniformTypeIdentifiers
import PangolinGitCore

/// *Revision Graph* (TortoiseGit's `RevisionGraphDlg` / `RevisionGraphWnd`): the commits that carry
/// branches, tags and stashes — optionally with the branch and merge points between them — as a
/// zoomable graph with Find, a branch filter, ref actions and export to PNG/PDF.
@MainActor
public final class RevisionGraphWindowController: NSWindowController, NSSearchFieldDelegate {

    public let repositoryPath: PangolinPath

    private let canvas = RevisionGraphCanvasView()
    private let scrollView = NSScrollView()
    private let scopePopup = NSPopUpButton()
    private let branchPointsCheck = NSButton(checkboxWithTitle: "Branchings and merges", target: nil, action: nil)
    private let tagsCheck = NSButton(checkboxWithTitle: "Tags", target: nil, action: nil)
    private let upwardsCheck = NSButton(checkboxWithTitle: "Newest at bottom", target: nil, action: nil)
    private let zoomControl = NSSegmentedControl(labels: ["−", "100%", "Fit", "+"], trackingMode: .momentary, target: nil, action: nil)
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "Loading…")
    private var commits: [RevisionGraphCommit] = []
    private var findMatches: [String] = []
    private var findIndex = 0
    private var loadGeneration = 0

    public init(repositoryPath: PangolinPath) {
        self.repositoryPath = repositoryPath
        super.init(window: ToolDialog.window(title: "Revision Graph", repository: repositoryPath, width: 1000, height: 720))
        window?.minSize = NSSize(width: 640, height: 400)
        setupUI()
        reload()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        scopePopup.addItems(withTitles: ["All branches", "Local branches", "Current branch"])
        scopePopup.target = self
        scopePopup.action = #selector(reload)
        branchPointsCheck.state = .on
        tagsCheck.state = .on
        for check in [branchPointsCheck, tagsCheck] {
            check.target = self
            check.action = #selector(rebuild)
        }
        upwardsCheck.target = self
        upwardsCheck.action = #selector(directionChanged)
        zoomControl.target = self
        zoomControl.action = #selector(zoomClicked)
        searchField.placeholderString = "Find ref, hash or message"
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(findNext)
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let refresh = ClosureButton(title: "Refresh") { [weak self] in self?.reload() }
        refresh.bezelStyle = .rounded
        refresh.keyEquivalent = "r"
        refresh.keyEquivalentModifierMask = [.command]
        let save = ClosureButton(title: "Save Graph…") { [weak self] in self?.saveGraph() }
        save.bezelStyle = .rounded

        let toolbar = NSStackView(views: [scopePopup, branchPointsCheck, tagsCheck, upwardsCheck, zoomControl, searchField, refresh, save])
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.setHuggingPriority(.defaultLow, for: .horizontal)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 4
        scrollView.documentView = canvas
        canvas.onDoubleClick = { [weak self] node in self?.showLog(node) }
        canvas.menuProvider = { [weak self] nodes in self?.menu(for: nodes) }
        canvas.onSelectionChange = { [weak self] in self?.updateStatus() }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        [toolbar, scrollView, statusLabel].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])
    }

    // MARK: - Data

    @objc private func reload() {
        let scope = RevisionGraphBuilder.Scope(rawValue: scopePopup.indexOfSelectedItem) ?? .all
        let root = repositoryPath
        loadGeneration += 1
        let generation = loadGeneration
        statusLabel.stringValue = "Reading history…"
        Task { @MainActor in
            do {
                let output = try await GitCLIRunner.runAsync(arguments: RevisionGraphBuilder.logArguments(scope: scope), workingDirectory: root)
                let parsed = await Task.detached { RevisionGraphBuilder.parseLog(output) }.value
                guard generation == self.loadGeneration else { return }
                self.commits = parsed
                self.rebuild()
            } catch {
                self.statusLabel.stringValue = "Could not read the history: \(error.localizedDescription)"
            }
        }
    }

    @objc private func rebuild() {
        let branchPoints = branchPointsCheck.state == .on
        let tags = tagsCheck.state == .on
        let input = commits
        Task { @MainActor in
            let nodes = await Task.detached {
                RevisionGraphBuilder.layout(RevisionGraphBuilder.simplify(input, branchPoints: branchPoints, includeTags: tags))
            }.value
            self.canvas.setNodes(nodes)
            self.updateFind()
            self.updateStatus()
        }
    }

    @objc private func directionChanged() {
        canvas.newestAtBottom = upwardsCheck.state == .on
    }

    private func updateStatus() {
        let selected = canvas.selectedNodes
        var text = "\(canvas.placed.count) of \(commits.count) commits shown"
        if !selected.isEmpty {
            text += " · selected: " + selected.map { String($0.commit.hash.prefix(8)) }.joined(separator: ", ")
            if selected.count == 1 { text += " — Cmd-click a second node to compare" }
        }
        statusLabel.stringValue = text
    }

    // MARK: - Zoom and find

    @objc private func zoomClicked() {
        switch zoomControl.selectedSegment {
        case 0: scrollView.animator().magnification = max(scrollView.minMagnification, scrollView.magnification / 1.25)
        case 1: scrollView.animator().magnification = 1
        case 2: scrollView.magnify(toFit: canvas.bounds)
        default: scrollView.animator().magnification = min(scrollView.maxMagnification, scrollView.magnification * 1.25)
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        updateFind()
    }

    private func updateFind() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            findMatches = []
            canvas.highlighted = []
            return
        }
        findMatches = canvas.placed.map(\.node.commit).filter { commit in
            commit.hash.hasPrefix(query) || commit.subject.lowercased().contains(query)
                || commit.refs.contains { $0.fullName.lowercased().contains(query) }
        }.map(\.hash)
        findIndex = 0
        canvas.highlighted = Set(findMatches)
        if let first = findMatches.first { canvas.select(first) }
    }

    /// Enter in the Find field jumps to the next match (TortoiseGit's Find next).
    @objc private func findNext() {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + 1) % findMatches.count
        canvas.select(findMatches[findIndex])
    }

    // MARK: - Context menu

    private func menu(for nodes: [RevisionGraphNode]) -> NSMenu? {
        guard let first = nodes.first else { return nil }
        let menu = NSMenu()
        let root = repositoryPath
        let hash = first.commit.hash
        if nodes.count == 2 {
            let (a, b) = (nodes[0].commit.hash, nodes[1].commit.hash)
            menu.addItem(ClosureMenuItem(title: "Compare Revisions", symbol: "arrow.left.arrow.right") {
                WindowRegistry.shared.present({ FileDiffWindowController(repositoryPath: root, rev1: a, rev2: b) }, repository: root)
            })
            menu.addItem(ClosureMenuItem(title: "Show Changes as Unified Diff", symbol: "doc.plaintext") { [weak self] in
                self?.showUnifiedDiff(["diff", a, b], name: "\(a.prefix(8))-\(b.prefix(8))")
            })
            return menu
        }
        menu.addItem(ClosureMenuItem(title: "Show Log", symbol: "clock.arrow.circlepath") { [weak self] in self?.showLog(first) })
        menu.addItem(ClosureMenuItem(title: "Browse Repository", symbol: "folder") {
            WindowRegistry.shared.present({ RepoBrowserWindowController(repositoryPath: root, initialRevision: hash) }, repository: root)
        })
        menu.addItem(ClosureMenuItem(title: "Compare with HEAD", symbol: "arrow.left.arrow.right") {
            WindowRegistry.shared.present({ FileDiffWindowController(repositoryPath: root, rev1: hash, rev2: "HEAD") }, repository: root)
        })
        menu.addItem(ClosureMenuItem(title: "Compare with Working Tree (Unified Diff)", symbol: "doc.plaintext") { [weak self] in
            self?.showUnifiedDiff(["diff", hash], name: "\(hash.prefix(8))-working-tree")
        })
        menu.addItem(.separator())

        let localBranches = first.commit.refs.filter { $0.kind == .localBranch }
        for branch in localBranches where !branch.isCurrent {
            menu.addItem(ClosureMenuItem(title: "Switch to “\(branch.shortName)”", symbol: "arrow.triangle.branch") {
                ProgressWindowController.run(title: "Switch", commands: [["switch", branch.shortName]], workingDirectory: root)
            })
        }
        menu.addItem(ClosureMenuItem(title: "Switch/Checkout…", symbol: "arrow.triangle.branch") {
            WindowRegistry.shared.present({ SwitchWindowController(repositoryPath: root) }, repository: root)
        })
        menu.addItem(ClosureMenuItem(title: "Create Branch at This Version…", symbol: "plus") {
            WindowRegistry.shared.present({ CreateBranchTagWindowController(repositoryPath: root, initialBase: hash) }, repository: root)
        })
        menu.addItem(ClosureMenuItem(title: "Create Tag at This Version…", symbol: "tag") {
            WindowRegistry.shared.present({ CreateBranchTagWindowController(repositoryPath: root, initialBase: hash, createTag: true) }, repository: root)
        })
        menu.addItem(ClosureMenuItem(title: "Export This Version…", symbol: "square.and.arrow.up") {
            WindowRegistry.shared.present({ ExportWindowController(repositoryPath: root, revision: hash) }, repository: root)
        })
        menu.addItem(ClosureMenuItem(title: "Create Patch Serial Since This Version…", symbol: "doc.on.doc") {
            WindowRegistry.shared.present({ FormatPatchWindowController(repositoryPath: root, since: hash) }, repository: root)
        })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "Copy SHA-1", symbol: "doc.on.clipboard") { Self.copy(hash) })
        if !first.commit.refs.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Copy Ref Names", symbol: "doc.on.clipboard") {
                Self.copy(first.commit.refs.map(\.shortName).joined(separator: "\n"))
            })
            let deletable = first.commit.refs.filter { [.localBranch, .remoteBranch, .tag].contains($0.kind) && !$0.isCurrent }
            if !deletable.isEmpty {
                let delete = NSMenuItem(title: "Delete", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for ref in deletable {
                    submenu.addItem(ClosureMenuItem(title: ref.shortName) { [weak self] in self?.delete(ref) })
                }
                delete.submenu = submenu
                menu.addItem(delete)
            }
        }
        return menu
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func showLog(_ node: RevisionGraphNode) {
        CommandRouter.shared.execute(command: .log, targetPath: repositoryPath.rawPath)
    }

    /// Writes the diff to a temporary `.diff` file and opens it in the patch viewer.
    private func showUnifiedDiff(_ args: [String], name: String) {
        let root = repositoryPath
        Task { @MainActor in
            do {
                let data = try await GitCLIRunner.runDataAsync(arguments: args, workingDirectory: root)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinGit-Diff", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("\(name).diff")
                try data.write(to: url, options: .atomic)
                PatchViewerWindowController.present(url)
            } catch {
                ToolDialog.showError(error, in: self.window)
            }
        }
    }

    /// Branch / tag deletion as in TortoiseGit's graph menu; remote branches are deleted on the remote.
    private func delete(_ ref: RevisionGraphRef) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(ref.shortName)”?"
        let command: [String]
        switch ref.kind {
        case .tag:
            command = ["tag", "-d", ref.shortName]
            alert.informativeText = "The tag is deleted locally; a pushed tag stays on the remote."
        case .remoteBranch:
            let parts = ref.shortName.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            command = ["push", parts[0], "--delete", parts[1]]
            alert.informativeText = "The branch “\(parts[1])” is deleted on the remote “\(parts[0])”."
        default:
            command = ["branch", "-d", ref.shortName]
            alert.informativeText = "Git refuses if the branch is not merged; use Browse References to force it."
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ProgressWindowController.run(title: "Delete \(ref.shortName)", commands: [command], workingDirectory: repositoryPath)
    }

    // MARK: - Save

    /// *Save Graph As…*: PNG or PDF (TortoiseGit also offers SVG/GraphViz through OGDF).
    private func saveGraph() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .pdf]
        panel.nameFieldStringValue = "\(repositoryPath.filename)-revision-graph.png"
        let format = NSPopUpButton()
        format.addItems(withTitles: ["PNG", "PDF"])
        panel.accessoryView = format
        format.target = panel
        guard let window, panel.runModal() == .OK, var url = panel.url else { return }
        let pdf = format.indexOfSelectedItem == 1 || url.pathExtension.lowercased() == "pdf"
        url = url.deletingPathExtension().appendingPathExtension(pdf ? "pdf" : "png")
        do {
            let data = pdf ? canvas.pdfData() : canvas.pngData()
            guard let data else { throw GitCLIError.processCrash("Could not render the graph") }
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            ToolDialog.showError(error, in: window)
        }
    }
}
