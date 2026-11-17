import Foundation
import Cocoa
import PangolinGitCore

/// Controller for the Revert Changes dialog (`RevertDlg.cpp` in TortoiseGit).
/// Lists the changed files inside the Finder selection in the shared status list (with its colours,
/// filter and context menu) next to a diff preview, and reverts the checked ones in the progress
/// window, moving overwritten files to the Trash first when that setting is on.
public final class RevertWindowController: NSWindowController {

    public let repositoryPath: PangolinPath
    /// Repository-relative selection; empty means the whole working tree.
    private let selection: [String]

    private let statusListView = StatusListView()
    private lazy var listActions = StatusListActions(repositoryRoot: repositoryPath)
    private var diffView: SideBySideDiffView!
    private var statusLabel: NSTextField!
    private var noteLabel: NSTextField!
    private var submodulesCheckbox: NSButton!
    private var revertButton: NSButton!

    public init(repositoryPath: PangolinPath, selection: [String] = []) {
        self.repositoryPath = repositoryPath
        self.selection = selection.filter { !$0.isEmpty }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Revert Changes — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 720, height: 480)

        super.init(window: window)
        setupUI()
        loadModifiedFiles()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.loadModifiedFiles() }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let headerLabel = NSTextField(labelWithString: "Select the files to discard local changes and revert to the repository state:")
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        // Split view: file list on the left, side-by-side diff of the highlighted file on the right.
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        listActions.attach(to: statusListView, autosaveName: "Revert")
        statusListView.emptyMessage = "There are no local changes to revert in the selection."
        statusListView.contextMenuProvider = { [weak self] items in
            guard let self else { return nil }
            return self.listActions.menu(for: items, listed: self.statusListView.listedItems)
        }
        statusListView.onHighlightChanged = { [weak self] items in self?.updateDiffPreview(items.first) }
        statusListView.onDoubleClickItem = { [weak self] item in
            guard let self else { return }
            DiffWindowController.present(filePath: self.repositoryPath.appending(item.path), repository: self.repositoryPath)
        }
        statusListView.onSelectionChanged = { [weak self] checked in self?.revertButton?.isEnabled = !checked.isEmpty }
        splitView.addSubview(statusListView)

        diffView = SideBySideDiffView()
        splitView.addSubview(diffView)

        // TortoiseGit notes that unversioned files are not touched by Revert.
        noteLabel = NSTextField(wrappingLabelWithString: "Unversioned files are not listed; Revert does not delete them (use Clean Up for that).")
        noteLabel.font = NSFont.systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        submodulesCheckbox = NSButton(checkboxWithTitle: "Also check out reverted submodules (git submodule update)", target: nil, action: nil)
        submodulesCheckbox.translatesAutoresizingMaskIntoConstraints = false
        submodulesCheckbox.isHidden = true

        statusLabel = NSTextField(labelWithString: "Loading changes...")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false

        revertButton = NSButton(title: "Revert", target: self, action: #selector(revertClicked))
        revertButton.bezelStyle = .rounded
        revertButton.keyEquivalent = "\r"
        revertButton.translatesAutoresizingMaskIntoConstraints = false

        [headerLabel, splitView, noteLabel, submodulesCheckbox, statusLabel, cancelBtn, revertButton].forEach(contentView.addSubview)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            headerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            splitView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 10),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            splitView.bottomAnchor.constraint(equalTo: noteLabel.topAnchor, constant: -8),

            noteLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            noteLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            noteLabel.bottomAnchor.constraint(equalTo: submodulesCheckbox.topAnchor, constant: -6),

            submodulesCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            submodulesCheckbox.bottomAnchor.constraint(equalTo: revertButton.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: revertButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelBtn.leadingAnchor, constant: -12),

            cancelBtn.trailingAnchor.constraint(equalTo: revertButton.leadingAnchor, constant: -8),
            cancelBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            cancelBtn.widthAnchor.constraint(equalToConstant: 80),

            revertButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            revertButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            revertButton.widthAnchor.constraint(equalToConstant: 90)
        ])

        splitView.setPosition(420, ofDividerAt: 0)
    }

    private func loadModifiedFiles() {
        let pathspec = selection
        Task { @MainActor in
            do {
                let repo = try GitRepository(rootPath: repositoryPath)
                let items = try await repo.getStatus(pathspec: pathspec)
                    .filter { ![.untracked, .ignored, .clean].contains($0.status) }
                let previous = self.statusListView.listedItems.isEmpty ? nil : self.statusListView.allCheckedPaths
                let known = Set(self.statusListView.listedItems.map(\.path))
                // Conflicted files are left unchecked: reverting them drops both sides of the conflict.
                self.statusListView.setItems(items) { item in
                    if let previous, known.contains(item.path) { return previous.contains(item.path) }
                    return !item.isConflicted
                }
                let conflicted = items.filter(\.isConflicted).count
                self.submodulesCheckbox.isHidden = !items.contains(where: \.isSubmodule)
                var text = "\(items.count) file(s) can be reverted"
                if conflicted > 0 { text += "; \(conflicted) conflicted file(s) left unchecked" }
                self.statusLabel.stringValue = text
                self.revertButton.isEnabled = !self.statusListView.checkedItems.isEmpty
                if self.statusListView.selectedItems.isEmpty {
                    self.statusListView.highlightFirstItem()
                }
            } catch {
                self.statusLabel.stringValue = "Status error: \(error.localizedDescription)"
            }
        }
    }

    private func updateDiffPreview(_ item: StatusListItem?) {
        guard let item else {
            diffView.setDiff(rawUnifiedText: "Select a file to preview its modifications.")
            return
        }
        let paths = [item.info.originalPath, item.path].compactMap { $0 }
        Task { @MainActor in
            do {
                let diffOut = try await GitCLIRunner.runAsync(arguments: ["diff", "--no-color", "--no-ext-diff", "HEAD", "--"] + paths,
                                                              workingDirectory: repositoryPath)
                self.diffView.setDiff(rawUnifiedText: diffOut.isEmpty ? "(No diff content)" : diffOut)
            } catch {
                self.diffView.setDiff(rawUnifiedText: "Error fetching diff: \(error.localizedDescription)")
            }
        }
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func revertClicked() {
        let selectedItems = statusListView.checkedItems.map(\.info)
        guard !selectedItems.isEmpty else { return }
        WorkingTreeOperations.revert(selectedItems, root: repositoryPath, submodules: submodulesCheckbox.state == .on) { [weak self] succeeded in
            if succeeded { self?.close() }
        }
    }
}
