import Cocoa
import PangolinGitCore

/// Resolve dialog mirroring TortoiseGit's `CResolveDlg` (`src/TortoiseProc/ResolveDlg.cpp`): lists
/// the conflicted files of the selection, all checked, and marks the checked ones resolved
/// (`git add`) — or resolves them with one side's version — in the progress window, which offers
/// *Commit…* once no conflict is left.
public final class ResolveWindowController: NSWindowController {

    private let repositoryPath: PangolinPath
    /// Repository-relative selection; empty means the whole working tree.
    private let selection: [String]

    private let statusListView = StatusListView()
    private lazy var listActions = StatusListActions(repositoryRoot: repositoryPath)
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let resolvedButton = NSButton(title: "Resolved", target: nil, action: nil)
    private let mineButton = NSButton(title: "Use Mine", target: nil, action: nil)
    private let theirsButton = NSButton(title: "Use Theirs", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit Conflicts…", target: nil, action: nil)

    public init(repositoryPath: PangolinPath, selection: [String] = []) {
        self.repositoryPath = repositoryPath
        self.selection = selection.filter { !$0.isEmpty }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Resolve — \(repositoryPath.filename)"
        window.minSize = NSSize(width: 560, height: 340)
        super.init(window: window)
        setupUI()
        loadConflicts()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.loadConflicts() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let header = NSTextField(labelWithString: "Select the conflicted files to mark as resolved:")
        header.font = NSFont.boldSystemFont(ofSize: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        listActions.attach(to: statusListView, autosaveName: "Resolve")
        statusListView.emptyMessage = "There are no conflicted files in the selection."
        statusListView.translatesAutoresizingMaskIntoConstraints = false
        statusListView.contextMenuProvider = { [weak self] items in
            guard let self else { return nil }
            return self.listActions.menu(for: items, listed: self.statusListView.listedItems)
        }
        statusListView.onDoubleClickItem = { [weak self] item in self?.edit([item.path]) }
        statusListView.onSelectionChanged = { [weak self] checked in self?.updateButtons(checked.count) }

        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.keyEquivalent = "\u{1b}"
        for (button, action) in [(editButton, #selector(editClicked)), (mineButton, #selector(mineClicked)),
                                 (theirsButton, #selector(theirsClicked)), (resolvedButton, #selector(resolvedClicked))] {
            button.target = self
            button.action = action
        }
        resolvedButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [editButton, mineButton, theirsButton, cancelButton, resolvedButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.arrangedSubviews.forEach { ($0 as? NSButton)?.bezelStyle = .rounded }

        [header, statusListView, hintLabel, buttons].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            statusListView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            statusListView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusListView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusListView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -10),

            hintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])
    }

    private func loadConflicts() {
        guard let repo = GitRepository.open(at: repositoryPath) else { return }
        let pathspec = selection
        Task { @MainActor in
            let items = (try? await repo.getStatus(pathspec: pathspec)) ?? []
            let conflicted = items.filter { $0.isConflicted || $0.status == .conflicted }
            self.statusListView.setItems(conflicted, defaultChecked: true)
            let names = repo.conflictSideNames()
            self.mineButton.title = "Use Mine (\(names.mine))"
            self.theirsButton.title = "Use Theirs (\(names.theirs))"
            let operation = repo.operationInProgress
            // TortoiseGit's "Commit your change after resolve" reminder.
            switch operation {
            case .merge?, nil:
                self.hintLabel.stringValue = "After resolving all conflicts, commit your changes to complete the merge."
            case .rebase?, .applyMailbox?:
                self.hintLabel.stringValue = "After resolving all conflicts, continue the \(operation!.title.lowercased()) (git rebase --continue / git am --continue)."
            case .some(let op):
                self.hintLabel.stringValue = "After resolving all conflicts, commit or continue the \(op.title.lowercased())."
            }
            self.updateButtons(self.statusListView.checkedItems.count)
        }
    }

    private func updateButtons(_ checked: Int) {
        [resolvedButton, mineButton, theirsButton].forEach { $0.isEnabled = checked > 0 }
        editButton.isEnabled = checked > 0 && checked <= 10
    }

    private func edit(_ paths: [String]) {
        for path in paths {
            let file = repositoryPath.appending(path)
            WindowRegistry.shared.present({ MergeWindowController(targetFile: file) }, key: "merge|\(file.rawPath)", repository: repositoryPath)
        }
    }

    private func resolve(_ side: GitConflictSide?) {
        let paths = statusListView.checkedPaths
        guard !paths.isEmpty else { return }
        WorkingTreeOperations.resolve(paths, side: side, root: repositoryPath)
    }

    @objc private func editClicked() { edit(statusListView.checkedPaths) }
    @objc private func mineClicked() { resolve(.mine) }
    @objc private func theirsClicked() { resolve(.theirs) }
    @objc private func resolvedClicked() { resolve(nil) }
    @objc private func cancelClicked() { close() }
}
