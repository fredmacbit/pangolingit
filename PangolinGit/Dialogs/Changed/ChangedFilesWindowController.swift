import Foundation
import Cocoa
import PangolinGitCore

/// Controller for the Check for Modifications dialog (`ChangedDlg.cpp` in TortoiseGit).
/// Lists the changed files of the Finder selection (or the whole project), optionally with
/// unversioned, ignored, flagged (assume-unchanged / skip-worktree) and unmodified files; shows
/// line counts and a summary, and offers diff, revert, stage, stash, save-as-patch and commit.
public final class ChangedFilesWindowController: NSWindowController {

    public let repositoryPath: PangolinPath
    /// Repository-relative selection from Finder; empty means the whole repository.
    private let selection: [String]
    private var allItems: [GitItemStatusInfo] = []
    private var lineCounts: [String: GitLineCount] = [:]

    private let statusListView = StatusListView()
    private lazy var listActions = StatusListActions(repositoryRoot: repositoryPath)
    private var filterSegment: NSSegmentedControl!
    private var unversionedCheckbox: NSButton!
    private var ignoredCheckbox: NSButton!
    private var flaggedCheckbox: NSButton!
    private var unmodifiedCheckbox: NSButton!
    private var wholeProjectCheckbox: NSButton!
    private var statusLabel: NSTextField!
    private var diffButton: NSButton!
    private var revertButton: NSButton!
    private var stageButton: NSButton!
    private var unstageButton: NSButton!
    private var commitButton: NSButton!

    /// Diffs opened at once before asking (TortoiseGit's `NumDiffWarning`).
    private static let diffWarningThreshold = 10

    public init(repositoryPath: PangolinPath, selection: [String] = []) {
        self.repositoryPath = repositoryPath
        self.selection = selection.filter { !$0.isEmpty }

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Changed Files — \(repositoryPath.filename)"
        window.minSize = NSSize(width: 760, height: 440)

        super.init(window: window)
        setupUI()
        loadChanges()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.loadChanges() }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var wholeProjectKey: String { "ChangedFiles.wholeProject.\(repositoryPath.rawPath)" }

    private func setupUI() {
        guard let window = self.window, let contentView = window.contentView else { return }

        // Top bar: category filter, show-toggles, refresh
        filterSegment = NSSegmentedControl(labels: ["All", "Modified", "Unversioned", "Staged", "Conflicted"], trackingMode: .selectOne,
                                           target: self, action: #selector(filterSegmentChanged))
        filterSegment.selectedSegment = 0

        func toggle(_ title: String, _ on: Bool) -> NSButton {
            let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(showOptionChanged))
            box.state = on ? .on : .off
            return box
        }
        unversionedCheckbox = toggle("Unversioned", true)
        ignoredCheckbox = toggle("Ignored", false)
        flaggedCheckbox = toggle("Flagged", false)
        flaggedCheckbox.toolTip = "Files marked assume-unchanged or skip-worktree"
        unmodifiedCheckbox = toggle("Unmodified", false)
        wholeProjectCheckbox = toggle("Whole project", UserDefaults.standard.bool(forKey: wholeProjectKey))
        wholeProjectCheckbox.isHidden = selection.isEmpty
        if !selection.isEmpty {
            wholeProjectCheckbox.toolTip = "Selection: " + selection.prefix(5).joined(separator: ", ")
        }

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.keyEquivalent = "r"
        refreshButton.keyEquivalentModifierMask = .command

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let topBar = NSStackView(views: [filterSegment, unversionedCheckbox, ignoredCheckbox, flaggedCheckbox, unmodifiedCheckbox,
                                         wholeProjectCheckbox, spacer, refreshButton])
        topBar.spacing = 10
        topBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topBar)

        // StatusListView
        statusListView.translatesAutoresizingMaskIntoConstraints = false
        listActions.attach(to: statusListView, autosaveName: "Changed")
        statusListView.emptyMessage = "No changes. The working tree matches HEAD."
        statusListView.contextMenuProvider = { [weak self] items in
            guard let self else { return nil }
            return self.listActions.menu(for: items, listed: self.statusListView.listedItems)
        }
        statusListView.onDoubleClickItem = { [weak self] item in
            guard let self = self else { return }
            let file = self.repositoryPath.appending(item.path)
            if item.status == .conflicted || item.info.isConflicted {
                WindowRegistry.shared.present({ MergeWindowController(targetFile: file) }, key: "merge|\(file.rawPath)", repository: self.repositoryPath)
            } else {
                DiffWindowController.present(filePath: file, repository: self.repositoryPath)
            }
        }
        statusListView.onSelectionChanged = { [weak self] selected in
            self?.updateButtonStates(selectedCount: selected.count)
        }
        contentView.addSubview(statusListView)

        // Summary line (TortoiseGit's line and file counts)
        statusLabel = NSTextField(labelWithString: "Loading repository status...")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        // Action Buttons
        diffButton = NSButton(title: "Diff", target: self, action: #selector(diffSelectedClicked))
        revertButton = NSButton(title: "Revert...", target: self, action: #selector(revertSelectedClicked))
        stageButton = NSButton(title: "Stage", target: self, action: #selector(stageSelectedClicked))
        unstageButton = NSButton(title: "Unstage", target: self, action: #selector(unstageSelectedClicked))
        let saveDiffButton = NSButton(title: "Save Diff…", target: self, action: #selector(saveDiffClicked))
        saveDiffButton.toolTip = "Save all uncommitted changes as a unified diff (patch)"
        commitButton = NSButton(title: "Commit...", target: self, action: #selector(commitClicked))
        commitButton.keyEquivalent = "\r"
        let stashButton = makeStashButton()

        let buttons: [NSView] = [stashButton, saveDiffButton, diffButton, revertButton, stageButton, unstageButton, commitButton]
        buttons.compactMap { $0 as? NSButton }.forEach { $0.bezelStyle = .rounded }
        let buttonStack = NSStackView(views: buttons)
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            statusListView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 10),
            statusListView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusListView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusListView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -10),

            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    /// TortoiseGit's stash split button: Stash changes / Pop / Apply / List.
    private func makeStashButton() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.addItem(withTitle: "Stash")
        let root = repositoryPath
        let entries: [(String, () -> Void)] = [
            ("Stash Changes…", { CommandRouter.shared.execute(command: .stash, targetPath: root.rawPath) }),
            ("Stash Pop", { ProgressWindowController.run(title: "Stash Pop", commands: [["stash", "pop"]], workingDirectory: root) }),
            ("Stash Apply", { ProgressWindowController.run(title: "Stash Apply", commands: [["stash", "apply"]], workingDirectory: root) }),
            ("Stash List…", { CommandRouter.shared.execute(command: .stash, targetPath: root.rawPath) })
        ]
        for (title, handler) in entries {
            popup.menu?.addItem(ClosureMenuItem(title: title, handler: handler))
        }
        return popup
    }

    private func updateButtonStates(selectedCount: Int) {
        let hasSelection = selectedCount > 0
        diffButton.isEnabled = hasSelection
        revertButton.isEnabled = hasSelection
        stageButton.isEnabled = hasSelection
        unstageButton.isEnabled = hasSelection
    }

    /// Pathspec for git: the Finder selection unless "Whole project" is ticked.
    private var pathspec: [String] {
        selection.isEmpty || wholeProjectCheckbox.state == .on ? [] : selection
    }

    private func loadChanges() {
        statusLabel.stringValue = "Loading repository status..."
        let pathspec = self.pathspec
        let showUnversioned = unversionedCheckbox.state == .on
        let showIgnored = ignoredCheckbox.state == .on
        let showFlagged = flaggedCheckbox.state == .on
        let showUnmodified = unmodifiedCheckbox.state == .on
        Task {
            do {
                let repo = try GitRepository(rootPath: repositoryPath)
                var items = try await repo.getStatus(untrackedFiles: showUnversioned ? "all" : "no", includeIgnored: showIgnored,
                                                     pathspec: pathspec)
                    .filter { $0.status != .clean }
                let changedPaths = Set(items.map(\.path))
                let flags = showFlagged || showUnmodified ? ((try? repo.localChangeFlags(pathspec: pathspec)) ?? [:]) : [:]
                if showUnmodified {
                    let tracked = (try? await GitCLIRunner.runAsync(arguments: ["ls-files", "-z", "--"] + pathspec, workingDirectory: repositoryPath)) ?? ""
                    items += tracked.split(separator: "\0").map(String.init)
                        .filter { !changedPaths.contains($0) && (showFlagged || flags[$0] == nil) }
                        .map { GitItemStatusInfo(path: $0, status: .clean) }
                } else if showFlagged {
                    items += flags.keys.sorted().filter { !changedPaths.contains($0) }.map { GitItemStatusInfo(path: $0, status: .clean) }
                }
                let counts = (try? repo.lineCounts(pathspec: pathspec)) ?? [:]
                // Only a complete list may drop changelist entries of files that are no longer changed.
                let complete = pathspec.isEmpty ? try? await repo.getStatus(untrackedFiles: "all", includeIgnored: true) : nil
                await MainActor.run {
                    if let complete {
                        self.listActions.changelists.prune(keeping: Set(complete.map(\.path)))
                    }
                    self.allItems = items
                    self.lineCounts = counts
                    self.applyCategoryFilter()
                    self.statusListView.setFlags(flags)
                }
            } catch {
                await MainActor.run {
                    self.statusLabel.stringValue = "Status error: \(error.localizedDescription)"
                }
            }
        }
    }

    @objc private func filterSegmentChanged() {
        applyCategoryFilter()
    }

    @objc private func showOptionChanged() {
        UserDefaults.standard.set(wholeProjectCheckbox.state == .on, forKey: wholeProjectKey)
        loadChanges()
    }

    private func applyCategoryFilter() {
        let filtered: [GitItemStatusInfo]
        switch filterSegment.selectedSegment {
        case 1:
            filtered = allItems.filter { [.modified, .stagedModified, .renamed, .copied, .missing, .deleted].contains($0.status) }
        case 2:
            filtered = allItems.filter { $0.status == .untracked || $0.status == .ignored }
        case 3:
            filtered = allItems.filter { $0.isStaged }
        case 4:
            filtered = allItems.filter { $0.isConflicted || $0.status == .conflicted }
        default:
            filtered = allItems
        }

        let previous = statusListView.listedItems.isEmpty ? nil : statusListView.allCheckedPaths
        let known = Set(statusListView.listedItems.map(\.path))
        statusListView.setItems(filtered) { item in
            if let previous, known.contains(item.path) { return previous.contains(item.path) }
            return ![.untracked, .ignored, .clean].contains(item.status)
        }
        statusListView.setLineCounts(lineCounts)
        statusLabel.stringValue = StatusSummary.text(for: filtered, lineCounts: lineCounts)
        updateButtonStates(selectedCount: statusListView.checkedItems.count)
    }

    @objc private func refreshClicked() {
        loadChanges()
    }

    /// Opens a diff for every checked file, asking first when there are many.
    @objc private func diffSelectedClicked() {
        let items = statusListView.checkedItems.filter { ![.untracked, .ignored, .clean].contains($0.status) }
        guard !items.isEmpty else { return }
        if items.count > Self.diffWarningThreshold {
            let alert = NSAlert()
            alert.messageText = "Open \(items.count) diff windows?"
            alert.addButton(withTitle: "Open All")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for item in items {
            DiffWindowController.present(filePath: repositoryPath.appending(item.path), repository: repositoryPath)
        }
    }

    @objc private func revertSelectedClicked() {
        // Untracked files have nothing to revert to; they are skipped rather than deleted.
        WorkingTreeOperations.revert(statusListView.checkedItems.map(\.info), root: repositoryPath)
    }

    /// "Save unified diff": all uncommitted changes of the listed scope as a patch file.
    @objc private func saveDiffClicked() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(repositoryPath.filename).patch"
        let binary = NSButton(checkboxWithTitle: "Include binary changes (--binary)", target: nil, action: nil)
        panel.accessoryView = binary
        let root = repositoryPath
        let pathspec = self.pathspec
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let hasHead = GitRepository.open(at: root)?.hasHead ?? true
            var args = ["diff", "--no-color", "--no-ext-diff"]
            if binary.state == .on { args.append("--binary") }
            args.append(hasHead ? "HEAD" : "--cached")
            if !pathspec.isEmpty { args += ["--"] + pathspec }
            Task { @MainActor in
                do {
                    let data = try await GitCLIRunner.runDataAsync(arguments: args, workingDirectory: root)
                    try data.write(to: url)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @objc private func stageSelectedClicked() {
        let paths = statusListView.checkedPaths
        guard !paths.isEmpty else { return }

        Task {
            do {
                let repo = try GitRepository(rootPath: repositoryPath)
                try await repo.stage(paths: paths)
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }

    @objc private func unstageSelectedClicked() {
        let paths = statusListView.checkedPaths
        guard !paths.isEmpty else { return }

        Task {
            do {
                let repo = try GitRepository(rootPath: repositoryPath)
                try await repo.unstage(paths: paths)
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }

    @objc private func commitClicked() {
        CommandRouter.shared.execute(command: .commit, targetPath: repositoryPath.rawPath)
    }
}
