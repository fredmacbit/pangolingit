import Cocoa
import PangolinGitCore

/// "Add" dialog mirroring TortoiseGit's `CAddDlg` (`src/TortoiseProc/AddDlg.cpp`): lists the
/// unversioned files inside the Finder selection, all checked, optionally with the ignored ones
/// (*Include ignored files*, force-added with `-f`), and adds the checked ones in the progress window,
/// which offers *Commit…* and *Add as Executable* afterwards.
public final class AddWindowController: NSWindowController {

    private let repositoryPath: PangolinPath
    /// Repository-relative paths of the selection; empty or "" means the whole working tree.
    private let selection: [String]

    private let statusListView = StatusListView()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Looking for unversioned files…")
    private let includeIgnoredCheckbox = NSButton(checkboxWithTitle: "Include ignored files", target: nil, action: nil)
    private lazy var listActions = StatusListActions(repositoryRoot: repositoryPath)

    public init(repositoryPath: PangolinPath, selection: [String]) {
        self.repositoryPath = repositoryPath
        self.selection = selection
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Add — \(repositoryPath.filename)"
        window.minSize = NSSize(width: 460, height: 340)
        super.init(window: window)
        setupUI()
        loadUnversioned()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.loadUnversioned() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let header = NSTextField(labelWithString: "Select the files to add to version control:")
        header.font = NSFont.boldSystemFont(ofSize: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        statusListView.translatesAutoresizingMaskIntoConstraints = false
        listActions.attach(to: statusListView, autosaveName: "Add")
        // TortoiseGit's hint: git tracks files, not folders.
        statusListView.emptyMessage = "There is nothing to add.\nEmpty folders cannot be added because git tracks files only; "
            + "put a placeholder file (for example .gitkeep) into a folder to add it."
        statusListView.contextMenuProvider = { [weak self] items in
            guard let self else { return nil }
            return self.listActions.menu(for: items, listed: self.statusListView.listedItems)
        }
        statusListView.onSelectionChanged = { [weak self] checked in self?.addButton.isEnabled = !checked.isEmpty }

        includeIgnoredCheckbox.target = self
        includeIgnoredCheckbox.action = #selector(includeIgnoredChanged)
        includeIgnoredCheckbox.translatesAutoresizingMaskIntoConstraints = false

        addButton.target = self
        addButton.action = #selector(onAddClicked)
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.isEnabled = false
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(onCancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        [header, statusListView, includeIgnoredCheckbox, statusLabel, addButton, cancelButton].forEach(contentView.addSubview)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            statusListView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            statusListView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusListView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusListView.bottomAnchor.constraint(equalTo: includeIgnoredCheckbox.topAnchor, constant: -8),

            includeIgnoredCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            includeIgnoredCheckbox.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            cancelButton.widthAnchor.constraint(equalToConstant: 80),

            addButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            addButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            addButton.widthAnchor.constraint(equalToConstant: 80)
        ])
    }

    @objc private func includeIgnoredChanged() {
        loadUnversioned()
    }

    private func loadUnversioned() {
        guard let repo = GitRepository.open(at: repositoryPath) else {
            statusLabel.stringValue = "Not a valid Git repository."
            return
        }
        let pathspec = selection.contains("") || selection.isEmpty ? ["."] : selection
        let includeIgnored = includeIgnoredCheckbox.state == .on
        Task { @MainActor in
            do {
                let items = try await repo.getStatus(untrackedFiles: "all", includeIgnored: includeIgnored, pathspec: pathspec)
                let candidates = items.filter { $0.status == .untracked || $0.status == .ignored }
                let previous = self.statusListView.allCheckedPaths
                let known = Set(self.statusListView.listedItems.map(\.path))
                // Ignored files are offered unchecked: adding them is the exception.
                self.statusListView.setItems(candidates) { item in
                    known.contains(item.path) ? previous.contains(item.path) : item.status == .untracked
                }
                self.addButton.isEnabled = !self.statusListView.checkedItems.isEmpty
                let ignoredCount = candidates.filter { $0.status == .ignored }.count
                self.statusLabel.stringValue = candidates.isEmpty
                    ? "There are no unversioned files in the selection."
                    : "\(candidates.count - ignoredCount) unversioned" + (includeIgnored ? ", \(ignoredCount) ignored" : "")
                        + " file(s). Right-click to ignore files instead."
            } catch {
                self.statusLabel.stringValue = "Error loading status: \(error.localizedDescription)"
            }
        }
    }

    @objc private func onAddClicked() {
        let checked = statusListView.checkedItems
        let paths = checked.map(\.path)
        guard !paths.isEmpty else { return }
        let root = repositoryPath
        // Ignored files need -f, like TortoiseGit's force-add of ignored items.
        let force = checked.contains { $0.status == .ignored }
        close()
        ProgressWindowController.run(title: "Add", commands: [["add", "-v"] + (force ? ["-f"] : []) + ["--"] + paths],
                                     workingDirectory: root, postActions: { outcome in
            guard outcome.succeeded else { return [] }
            let files = paths.filter { !$0.hasSuffix("/") }
            var actions = [WorkingTreeOperations.commitAction(root)]
            if !files.isEmpty {
                actions.append(ProgressWindowController.PostAction("Add as Executable") {
                    ProgressWindowController.run(title: "Add as Executable", commands: [["update-index", "--chmod=+x", "--"] + files],
                                                 workingDirectory: root)
                })
            }
            return actions
        })
    }

    @objc private func onCancelClicked() {
        close()
    }
}
