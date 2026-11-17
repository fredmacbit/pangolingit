import Foundation
import Cocoa
import PangolinGitCore

/// Git LFS locks dialog (TortoiseGit's `CLFSLocksDlg`): lists locks from the server or the local
/// cache, filters them, unlocks several at once (optionally forced, with a force fallback when an
/// unlock is refused), locks further files, sets up lockable patterns and checks the LFS install.
public final class LFSLocksWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    public let repositoryPath: PangolinPath

    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading locks…")
    private let filterField = NSSearchField()
    private let sourcePopup = NSPopUpButton()
    private let selectAllCheckbox = NSButton(checkboxWithTitle: "Select all", target: nil, action: nil)
    private let forceCheckbox = NSButton(checkboxWithTitle: "Force", target: nil, action: nil)
    private let unlockButton = NSButton(title: "Unlock", target: nil, action: nil)
    private let lockButton = NSButton(title: "Lock Files…", target: nil, action: nil)
    private let lockableButton = NSButton(title: "Lockable Patterns…", target: nil, action: nil)
    private let installButton = NSButton(title: "Install LFS", target: nil, action: nil)
    private let lockableLabel = NSTextField(labelWithString: "")

    private var allLocks: [LFSLock] = []
    private var shownLocks: [LFSLock] = []
    private var loadTask: Task<Void, Never>?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    public init(repositoryPath: PangolinPath) {
        self.repositoryPath = repositoryPath
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git LFS Locks — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 600, height: 360)
        super.init(window: window)
        setupUI()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.loadLocks() }
        loadLocks()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI

    private func setupUI() {
        guard let content = window?.contentView else { return }

        sourcePopup.addItems(withTitles: ["Server", "Cached (local)"])
        sourcePopup.selectItem(at: ConfigManager.shared.advancedBool(.lfsLocksFromServer) ? 0 : 1)
        sourcePopup.target = self
        sourcePopup.action = #selector(refreshClicked)
        sourcePopup.toolTip = "Server asks the LFS server (git lfs locks); Cached shows the locks this clone knows about without network access (--local)."

        filterField.placeholderString = "Filter by path or owner"
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.target = self
        tableView.doubleAction = #selector(revealClicked)
        for (identifier, title, width) in [("path", "Path", 330.0), ("owner", "Owner", 150.0),
                                           ("date", "Locked", 130.0), ("id", "Lock ID", 80.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        scroll.documentView = tableView

        selectAllCheckbox.target = self
        selectAllCheckbox.action = #selector(selectAllClicked)
        forceCheckbox.toolTip = "Unlock even if the lock belongs to somebody else (git lfs unlock --force)."
        unlockButton.target = self
        unlockButton.action = #selector(unlockClicked)
        lockButton.target = self
        lockButton.action = #selector(lockClicked)
        lockButton.toolTip = "Choose files of this repository to lock."
        lockableButton.target = self
        lockableButton.action = #selector(lockableClicked)
        lockableButton.toolTip = "Mark file patterns as lockable (git lfs track --lockable): such files are read-only until locked."
        installButton.target = self
        installButton.action = #selector(installClicked)
        installButton.toolTip = "Install the Git LFS filters and hooks (git lfs install)."
        installButton.isHidden = true
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshButton.keyEquivalent = "r"
        refreshButton.keyEquivalentModifierMask = [.command]
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.keyEquivalent = "\u{1b}"

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        lockableLabel.textColor = .secondaryLabelColor
        lockableLabel.lineBreakMode = .byTruncatingTail

        let sourceLabel = NSTextField(labelWithString: "Locks from:")
        let topRow = NSStackView(views: [sourceLabel, sourcePopup, filterField])
        topRow.spacing = 8
        let actionRow = NSStackView(views: [selectAllCheckbox, forceCheckbox, unlockButton, NSView(), lockButton, lockableButton, installButton])
        actionRow.spacing = 8
        let bottomRow = NSStackView(views: [statusLabel, refreshButton, closeButton])
        bottomRow.spacing = 8
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [topRow, scroll, actionRow, lockableLabel, bottomRow] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for button in [unlockButton, lockButton, lockableButton, installButton, refreshButton, closeButton] {
            button.bezelStyle = .rounded
        }
        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            topRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            topRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            filterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            scroll.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -10),

            actionRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            actionRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            actionRow.bottomAnchor.constraint(equalTo: lockableLabel.topAnchor, constant: -8),

            lockableLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            lockableLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            lockableLabel.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -10),

            bottomRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bottomRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottomRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        updateButtonStates()
    }

    // MARK: - Loading

    public func loadLocks() {
        loadTask?.cancel()
        statusLabel.stringValue = "Querying git lfs locks…"
        statusLabel.textColor = .secondaryLabelColor
        let source: GitLFS.LockSource = sourcePopup.indexOfSelectedItem == 0 ? .remote : .local
        let repository = repositoryPath
        loadTask = Task { [weak self] in
            // The install state decides which message makes sense when listing fails.
            let installed = await GitLFS.isInstalled()
            let initialized = installed ? await GitLFS.isInitialized(in: repository) : false
            let attributes = (try? String(contentsOf: repository.url.appendingPathComponent(".gitattributes"), encoding: .utf8)) ?? ""
            let lockable = GitLFS.lockablePatterns(gitattributes: attributes)
            var locks: [LFSLock] = []
            var failure: String?
            if installed {
                do {
                    locks = try await GitLFS.locks(in: repository, source: source)
                } catch let GitCLIError.commandFailed(_, stderr, _) {
                    failure = stderr.isEmpty ? "git lfs locks failed." : stderr
                } catch {
                    failure = error.localizedDescription
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.allLocks = locks
                self.applyFilter()
                self.installButton.isHidden = !installed || initialized
                self.lockableLabel.stringValue = lockable.isEmpty
                    ? "No lockable patterns in .gitattributes."
                    : "Lockable: " + lockable.joined(separator: "  ")
                if !installed {
                    self.statusLabel.stringValue = "Git LFS is not installed. Install it (e.g. brew install git-lfs) and run Install LFS."
                    self.statusLabel.textColor = .systemRed
                } else if let failure {
                    self.statusLabel.stringValue = failure
                    self.statusLabel.textColor = .systemRed
                } else {
                    let place = source == .remote ? "on the server" : "cached locally"
                    self.statusLabel.stringValue = "\(locks.count) lock(s) \(place)" + (initialized ? "" : " — LFS is not installed for this repository.")
                }
            }
        }
    }

    private func applyFilter() {
        let query = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shownLocks = query.isEmpty ? allLocks : allLocks.filter {
            $0.path.lowercased().contains(query) || $0.owner.lowercased().contains(query)
        }
        if let descriptor = tableView.sortDescriptors.first {
            shownLocks.sort { a, b in
                let order: Bool
                switch descriptor.key {
                case "owner": order = a.owner.localizedStandardCompare(b.owner) == .orderedAscending
                case "date": order = (a.lockedAt ?? .distantPast) < (b.lockedAt ?? .distantPast)
                case "id": order = a.id.localizedStandardCompare(b.id) == .orderedAscending
                default: order = a.path.localizedStandardCompare(b.path) == .orderedAscending
                }
                return descriptor.ascending ? order : !order
            }
        }
        tableView.reloadData()
        updateButtonStates()
    }

    private func updateButtonStates() {
        let selected = tableView.selectedRowIndexes.count
        unlockButton.isEnabled = selected > 0
        unlockButton.title = selected > 1 ? "Unlock \(selected)" : "Unlock"
        selectAllCheckbox.isEnabled = !shownLocks.isEmpty
        selectAllCheckbox.allowsMixedState = true
        switch selected {
        case 0: selectAllCheckbox.state = .off
        case shownLocks.count: selectAllCheckbox.state = .on
        default: selectAllCheckbox.state = .mixed
        }
    }

    private var selectedLocks: [LFSLock] {
        tableView.selectedRowIndexes.compactMap { $0 < shownLocks.count ? shownLocks[$0] : nil }
    }

    // MARK: - Table

    public func numberOfRows(in tableView: NSTableView) -> Int {
        shownLocks.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shownLocks.count, let column = tableColumn else { return nil }
        let lock = shownLocks[row]
        let identifier = NSUserInterfaceItemIdentifier("LFSCell_\(column.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }()
        switch column.identifier.rawValue {
        case "path":
            cell.stringValue = lock.path
            cell.toolTip = repositoryPath.url.appendingPathComponent(lock.path).path
        case "owner": cell.stringValue = lock.owner
        case "date": cell.stringValue = lock.lockedAt.map { Self.dateFormatter.string(from: $0) } ?? ""
        default: cell.stringValue = lock.id
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyFilter()
    }

    public func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    // MARK: - Actions

    @objc private func filterChanged() { applyFilter() }

    @objc private func refreshClicked() { loadLocks() }

    @objc private func closeClicked() { window?.close() }

    @objc private func selectAllClicked() {
        if selectAllCheckbox.state == .off || selectAllCheckbox.state == .mixed && tableView.selectedRowIndexes.count == shownLocks.count {
            tableView.deselectAll(nil)
        } else {
            tableView.selectAll(nil)
        }
        updateButtonStates()
    }

    @objc private func revealClicked() {
        let urls = selectedLocks.map { repositoryPath.url.appendingPathComponent($0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Unlocks the selected locks by id (several at once), forced when the Force box is ticked.
    @objc private func unlockClicked() {
        let locks = selectedLocks
        guard !locks.isEmpty else { return }
        let force = forceCheckbox.state == .on
        if force && !IntegrationCommands.confirmForceUnlock(paths: locks.map(\.path)) { return }
        runUnlock(locks, force: force)
    }

    private func runUnlock(_ locks: [LFSLock], force: Bool) {
        let repository = repositoryPath
        ProgressWindowController.run(
            title: force ? "LFS Force Unlock" : "LFS Unlock",
            commands: GitLFS.unlockByIDCommands(ids: locks.map(\.id), force: force),
            workingDirectory: repository,
            postActions: { [weak self] outcome in
                // Auto-fallback: an unlock refused (someone else's lock, or a modified file) can be forced.
                guard !outcome.succeeded, !outcome.cancelled, !force else { return [] }
                return [.init("Force Unlock") {
                    guard IntegrationCommands.confirmForceUnlock(paths: locks.map(\.path)) else { return }
                    self?.runUnlock(locks, force: true)
                }]
            },
            onFinish: { [weak self] _ in self?.loadLocks() })
    }

    /// Locks files chosen in an open panel rooted at the repository.
    @objc private func lockClicked() {
        let panel = NSOpenPanel()
        panel.directoryURL = repositoryPath.url
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose the files to lock"
        panel.prompt = "Lock"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            let root = self.repositoryPath
            let paths = panel.urls.compactMap { PangolinPath($0.path).relative(to: root) }.filter { !$0.isEmpty }
            guard !paths.isEmpty else { return }
            ProgressWindowController.run(title: "LFS Lock", commands: GitLFS.setLockedCommands(paths: paths, lock: true, force: false),
                                         workingDirectory: root, onFinish: { [weak self] _ in self?.loadLocks() })
        }
    }

    /// `git lfs track --lockable <pattern>` (TortoiseGit documents this as the lockable setup step).
    @objc private func lockableClicked() {
        let alert = NSAlert()
        alert.messageText = "Make files lockable"
        alert.informativeText = "Files matching the pattern are tracked by LFS and marked lockable in .gitattributes; "
            + "Git LFS keeps them read-only until you lock them. Commit .gitattributes afterwards."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "*.psd"
        if let ext = selectedLocks.first.map({ ($0.path as NSString).pathExtension }), !ext.isEmpty {
            field.stringValue = "*.\(ext)"
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Make Lockable")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pattern = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        ProgressWindowController.run(title: "LFS Track", commands: [["lfs", "track", "--lockable", "--", pattern]],
                                     workingDirectory: repositoryPath, onFinish: { [weak self] _ in self?.loadLocks() })
    }

    @objc private func installClicked() {
        ProgressWindowController.run(title: "LFS Install", commands: [["lfs", "install"]], workingDirectory: repositoryPath,
                                     onFinish: { [weak self] _ in self?.loadLocks() })
    }
}
