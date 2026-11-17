import Cocoa
import PangolinGitCore

/// TortoiseGit's *Delete remote tags on "X"…* (`DeleteRemoteTagDlg.cpp`): lists the tags on a remote
/// (`git ls-remote --tags`) and deletes the checked ones there (`git push <remote> --delete <tags>`).
public final class DeleteRemoteTagsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let repositoryPath: PangolinPath
    private let remote: String
    private var tags: [String] = []
    private var checked = Set<String>()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "Contacting the remote…")
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)

    public init(repositoryPath: PangolinPath, remote: String) {
        self.repositoryPath = repositoryPath
        self.remote = remote
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Delete Remote Tags on “\(remote)”"
        window.minSize = NSSize(width: 380, height: 320)
        super.init(window: window)
        setupUI()
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Tag names from `git ls-remote --tags` output, without the peeled `^{}` duplicates.
    static func parseRemoteTags(_ output: String) -> [String] {
        var names: [String] = []
        for line in output.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            var ref = String(line[line.index(after: tab)...])
            guard ref.hasPrefix("refs/tags/") else { continue }
            ref = String(ref.dropFirst("refs/tags/".count))
            if ref.hasSuffix("^{}") { continue }
            names.append(ref)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Tag"))
        column.title = "Tag"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView

        let all = NSButton(title: "Select All", target: self, action: #selector(checkAll))
        let none = NSButton(title: "Select None", target: self, action: #selector(checkNone))
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.isEnabled = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        statusLabel.textColor = .secondaryLabelColor
        let bottom = NSStackView(views: [all, none, NSView(), cancel, deleteButton])

        for view in [scroll, statusLabel, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottom.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func load() {
        let root = repositoryPath
        let remote = self.remote
        Task { @MainActor in
            do {
                let output = try await GitCLIRunner.runAsync(arguments: ["ls-remote", "--tags", remote], workingDirectory: root)
                self.tags = Self.parseRemoteTags(output)
                self.statusLabel.stringValue = "\(self.tags.count) tag(s) on \(remote)."
            } catch {
                self.statusLabel.stringValue = "Could not list the tags: \(error.localizedDescription)"
            }
            self.tableView.reloadData()
        }
    }

    private func updateButton() {
        deleteButton.isEnabled = !checked.isEmpty
        deleteButton.title = checked.isEmpty ? "Delete" : "Delete \(checked.count)"
    }

    @objc private func checkAll() {
        checked = Set(tags)
        tableView.reloadData()
        updateButton()
    }

    @objc private func checkNone() {
        checked.removeAll()
        tableView.reloadData()
        updateButton()
    }

    @objc private func toggled(_ sender: NSButton) {
        guard sender.tag < tags.count else { return }
        if sender.state == .on { checked.insert(tags[sender.tag]) } else { checked.remove(tags[sender.tag]) }
        updateButton()
    }

    @objc private func deleteClicked() {
        let names = tags.filter { checked.contains($0) }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \(names.count) tag(s) on “\(remote)”?"
        alert.informativeText = "The tags are removed on the server for everyone. Local tags are kept.\n\n" + names.prefix(20).joined(separator: ", ")
            + (names.count > 20 ? ", …" : "")
        alert.addButton(withTitle: "Delete on Remote")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        close()
        ProgressWindowController.run(title: "Delete Remote Tags", commands: [["push", "--progress", remote, "--delete"] + names.map { "refs/tags/\($0)" }],
                                     workingDirectory: repositoryPath)
    }

    @objc private func cancelClicked() {
        close()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        tags.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let box = NSButton(checkboxWithTitle: tags[row], target: self, action: #selector(toggled(_:)))
        box.state = checked.contains(tags[row]) ? .on : .off
        box.tag = row
        return box
    }
}
