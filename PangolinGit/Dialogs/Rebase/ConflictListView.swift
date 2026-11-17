import Cocoa
import PangolinGitCore

/// The *Conflict Files* list of TortoiseGit's rebase, cherry-pick and merge flows: every unmerged path
/// with Edit Conflicts (the 3-pane editor), Resolved (`git add`), and take-one-side actions.
@MainActor
final class ConflictListView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private let root: PangolinPath
    private let tableView = NSTableView()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var conflictedPaths: [String] = []
    /// Called after every reload with the number of files still in conflict.
    var onChange: ((Int) -> Void)?
    /// During a rebase git's "ours" is the branch being rebased onto and "theirs" the commit being
    /// replayed — the opposite of a merge. The labels follow so users pick the side they mean.
    var isRebase = false {
        didSet { updateHint() }
    }

    init(repositoryRoot: PangolinPath) {
        self.root = repositoryRoot
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        updateHint()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Path"))
        column.title = "Conflicted File"
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.target = self
        tableView.doubleAction = #selector(editSelected)
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        let edit = NSButton(title: "Edit Conflicts", target: self, action: #selector(editSelected))
        let resolved = NSButton(title: "Mark as Resolved", target: self, action: #selector(markResolved))
        let buttons = NSStackView(views: [edit, resolved])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.spacing = 8

        addSubview(scroll)
        addSubview(hintLabel)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            hintLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 6),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func updateHint() {
        hintLabel.stringValue = isRebase
            ? "Rebase: “ours” is the branch you are rebasing onto, “theirs” is your commit being replayed. Resolve every file, then Continue."
            : "Merge: “ours” is your current branch, “theirs” is what is being merged in. Resolve every file, then commit (or Continue)."
    }

    /// Re-reads the unmerged paths (`git diff --name-only --diff-filter=U`).
    func reload() {
        Task { @MainActor in
            let output = (try? await GitCLIRunner.runAsync(arguments: ["diff", "--name-only", "--diff-filter=U", "-z"],
                                                           workingDirectory: root)) ?? ""
            self.conflictedPaths = Array(Set(output.split(separator: "\0").map(String.init))).sorted()
            self.tableView.reloadData()
            self.onChange?(self.conflictedPaths.count)
        }
    }

    private var selectedPaths: [String] {
        let rows = tableView.selectedRowIndexes.isEmpty && tableView.clickedRow >= 0
            ? IndexSet(integer: tableView.clickedRow) : tableView.selectedRowIndexes
        return rows.compactMap { $0 < conflictedPaths.count ? conflictedPaths[$0] : nil }
    }

    @objc private func editSelected() {
        for path in selectedPaths.prefix(5) {
            CommandRouter.shared.execute(command: .merge, targetPath: root.appending(path).rawPath)
        }
    }

    @objc private func markResolved() {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        run([["add", "--"] + paths])
    }

    /// Takes one side for the selected files (`git checkout --ours/--theirs`) and marks them resolved.
    private func take(_ side: String) {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        run([["checkout", "--\(side)", "--"] + paths, ["add", "--"] + paths])
    }

    private func run(_ commands: [[String]]) {
        Task { @MainActor in
            for args in commands {
                do {
                    try await GitCLIRunner.runAsync(arguments: args, workingDirectory: root)
                } catch {
                    NSAlert(error: error).runModal()
                    break
                }
            }
            self.reload()
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        conflictedPaths.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: conflictedPaths[row])
        label.textColor = .systemRed
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}

extension ConflictListView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        let ours = isRebase ? "Use Upstream Version (ours)" : "Use My Version (ours)"
        let theirs = isRebase ? "Use My Commit's Version (theirs)" : "Use Their Version (theirs)"
        menu.addItem(ClosureMenuItem(title: "Edit Conflicts", symbol: "square.split.2x1") { [weak self] in self?.editSelected() })
        menu.addItem(ClosureMenuItem(title: "Mark as Resolved", symbol: "checkmark.circle") { [weak self] in self?.markResolved() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: ours, symbol: "arrow.left.circle") { [weak self] in self?.take("ours") })
        menu.addItem(ClosureMenuItem(title: theirs, symbol: "arrow.right.circle") { [weak self] in self?.take("theirs") })
        menu.addItem(.separator())
        let root = self.root
        menu.addItem(ClosureMenuItem(title: "Show in Finder", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { root.appending($0).url })
        })
    }
}
