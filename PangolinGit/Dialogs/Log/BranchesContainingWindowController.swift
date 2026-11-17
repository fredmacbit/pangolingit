import Cocoa
import PangolinGitCore

/// "Show branches this commit is on" (TortoiseGit's `CommitIsOnRefsDlg`): local and remote
/// branches (and tags) containing a commit, with a filter. Double-click opens that branch's log.
final class BranchesContainingWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let repositoryPath: PangolinPath
    private let commit: GitRevision
    private var refs: [String] = []
    private var shown: [String] = []
    private let tableView = NSTableView()
    private let filterField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "Searching…")

    init(repositoryPath: PangolinPath, commit: GitRevision) {
        self.repositoryPath = repositoryPath
        self.commit = commit
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Refs Containing \(commit.hash.short)"
        window.minSize = NSSize(width: 360, height: 260)
        super.init(window: window)
        setupUI()
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        let subject = NSTextField(labelWithString: "\(commit.hash.short)  \(commit.subject)")
        subject.lineBreakMode = .byTruncatingTail
        filterField.placeholderString = "Filter"
        filterField.target = self
        filterField.action = #selector(applyFilter)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Ref"))
        column.title = "Ref"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openLog)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView

        statusLabel.textColor = .secondaryLabelColor
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyRefs))
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.keyEquivalent = "\u{1b}"
        let bottom = NSStackView(views: [statusLabel, NSView(), copyButton, closeButton])

        for view in [subject, filterField, scroll, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14).isActive = true
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14).isActive = true
        }
        NSLayoutConstraint.activate([
            subject.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            filterField.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -8),
            bottom.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    private func load() {
        let hash = commit.hash.string
        let root = repositoryPath
        Task { @MainActor in
            let runner = GitCLIRunner()
            let branches = (try? await runner.runChecked(arguments: ["branch", "-a", "--contains", hash, "--format=%(refname:short)"],
                                                         workingDirectory: root)) ?? ""
            let tags = (try? await runner.runChecked(arguments: ["tag", "--contains", hash], workingDirectory: root)) ?? ""
            self.refs = (branches + "\n" + tags).split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") && !$0.hasPrefix("(") }
            self.applyFilter()
        }
    }

    @objc private func applyFilter() {
        let text = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = text.isEmpty ? refs : refs.filter { $0.lowercased().contains(text) }
        tableView.reloadData()
        statusLabel.stringValue = "\(shown.count) of \(refs.count) refs"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = LogTextCellView.make(in: tableView, identifier: "RefCell", owner: self)
        cell.configure(shown[row], font: .systemFont(ofSize: 12))
        return cell
    }

    @objc private func openLog() {
        let row = tableView.clickedRow
        guard row >= 0, row < shown.count else { return }
        let root = repositoryPath
        let ref = shown[row]
        WindowRegistry.shared.present({ LogWindowController(repositoryPath: root, revisions: [ref]) }, repository: root)
    }

    @objc private func copyRefs() {
        let rows = tableView.selectedRowIndexes.isEmpty ? IndexSet(shown.indices) : tableView.selectedRowIndexes
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.map { shown[$0] }.joined(separator: "\n"), forType: .string)
    }

    @objc private func closeWindow() {
        close()
    }
}
