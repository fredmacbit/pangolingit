import Cocoa
import PangolinGitCore

/// Git Sync dialog mirroring TortoiseGit's `CSyncDlg` (`src/TortoiseProc/SyncDlg.cpp`): local and
/// remote branch pickers, remote with *Manage*, split buttons for the pull / push / submodule /
/// stash families that run inline with their output in the Log tab, and tabs for incoming and
/// outgoing commits and files, conflicts, the refs a fetch changed and a tag comparison.
public final class SyncWindowController: NSWindowController, NSWindowDelegate {

    private enum Tab: Int {
        case log, inCommits, inChanges, conflicts, outCommits, outChanges, refList, tags
    }

    private let repositoryPath: PangolinPath
    private var currentBranch: String?
    private var remotes: [GitRemoteConfig] = []

    private let localBranchCombo = NSComboBox()
    private let remotePopup = NSPopUpButton()
    private let remoteBranch: BranchComboField
    private let urlLabel = NSTextField(labelWithString: "")
    private let forceCheckbox = NSButton(checkboxWithTitle: "Force (with lease)", target: nil, action: nil)
    private let sshKeyCheckbox = NSButton(checkboxWithTitle: "Use the remote's SSH key", target: nil, action: nil)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var actionControls: [NSControl] = []

    private let tabView = NSTabView()
    private let output = GitOutputView()
    private let inCommits = StringTable(columns: SyncWindowController.commitColumns, emptyText: "No incoming commits")
    private let inChanges = StringTable(columns: SyncWindowController.fileColumns, emptyText: "No incoming changes")
    private let conflicts = StringTable(columns: [.init(id: "Path", title: "Conflicted file", width: 560)], emptyText: "No conflicts")
    private let outCommits = StringTable(columns: SyncWindowController.commitColumns, emptyText: "No outgoing commits")
    private let outChanges = StringTable(columns: SyncWindowController.fileColumns, emptyText: "No outgoing changes")
    private let refList = StringTable(columns: [
        .init(id: "Ref", title: "Ref", width: 220), .init(id: "Type", title: "Type", width: 100),
        .init(id: "Change", title: "Change", width: 150), .init(id: "Old", title: "Old", width: 80, monospaced: true),
        .init(id: "New", title: "New", width: 80, monospaced: true),
    ], emptyText: "Fetch or pull to see which refs changed")
    private let hideUnchangedCheckbox = NSButton(checkboxWithTitle: "Hide unchanged refs", target: nil, action: nil)
    private let tagTable = StringTable(columns: [
        .init(id: "Tag", title: "Tag", width: 220), .init(id: "State", title: "State", width: 110),
        .init(id: "Local", title: "Local", width: 90, monospaced: true), .init(id: "Remote", title: "Remote", width: 90, monospaced: true),
    ], emptyText: "Choose Pull ▸ Compare Tags")

    private var refChanges: [GitRefChange] = []
    private var visibleRefChanges: [GitRefChange] = []
    private var tagComparison: [GitTagComparison] = []
    private var incomingFiles: [(status: String, path: String)] = []
    private var outgoingFiles: [(status: String, path: String)] = []
    private var conflictPaths: [String] = []
    /// After a pull, In Commits shows what the pull brought in (`<old HEAD>..HEAD`).
    private var pulledRange: String?
    private var runTask: Task<Void, Never>?
    private var loadGeneration = 0

    private static let commitColumns: [StringTable.Column] = [
        .init(id: "Hash", title: "Commit", width: 80, monospaced: true), .init(id: "Subject", title: "Message", width: 400),
        .init(id: "Author", title: "Author", width: 140), .init(id: "Date", title: "Date", width: 130),
    ]
    private static let fileColumns: [StringTable.Column] = [
        .init(id: "Status", title: "Status", width: 70), .init(id: "Path", title: "Path", width: 560),
    ]

    public init(repositoryPath: PangolinPath) {
        self.repositoryPath = repositoryPath
        self.remoteBranch = BranchComboField(repository: repositoryPath, placeholder: "Remote branch")
        let window = NSWindow(
            contentRect: NSRect(x: 180, y: 180, width: 860, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Sync - \(repositoryPath.filename)"
        window.minSize = NSSize(width: 720, height: 460)
        super.init(window: window)
        window.delegate = self

        setupUI()
        loadInitialState()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in
            guard let self, self.runTask == nil else { return }
            self.reloadRemotes(keepingSelection: true)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        localBranchCombo.completes = true
        localBranchCombo.target = self
        localBranchCombo.action = #selector(branchesChanged)
        localBranchCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        remotePopup.target = self
        remotePopup.action = #selector(remoteChanged)
        remoteBranch.onChange = { [weak self] in self?.scheduleLoad() }
        let manage = NSButton(title: "Manage…", target: self, action: #selector(manageRemotes))
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sshKeyCheckbox.state = .on
        sshKeyCheckbox.isHidden = true

        let branchGrid = RemoteDialogSupport.grid([
            [RemoteDialogSupport.label("Local branch:"), localBranchCombo,
             RemoteDialogSupport.label("Remote branch:"), remoteBranch],
            [RemoteDialogSupport.label("Remote:"), RemoteDialogSupport.hStack([remotePopup, manage]),
             RemoteDialogSupport.label("URL:"), urlLabel],
            [nil, RemoteDialogSupport.hStack([forceCheckbox, sshKeyCheckbox], spacing: 16), nil, nil],
        ])
        branchGrid.column(at: 2).xPlacement = .trailing

        // SY-02: the TortoiseGit split buttons. Shift-click on Pull/Push opens the full dialog.
        let pull = SplitActionButton(actions: [
            .init(title: "Pull") { [weak self] in self?.pullClicked() },
            .init(title: "Fetch") { [weak self] in self?.fetch(rebaseAfterwards: false) },
            .init(title: "Fetch & Rebase") { [weak self] in self?.fetch(rebaseAfterwards: true) },
            .init(title: "Fetch All Remotes") { [weak self] in self?.fetchAll() },
            .init(title: "Remote Update") { [weak self] in self?.remoteUpdate() },
            .init(title: "Clean Up Stale Remote Branches") { [weak self] in self?.pruneRemote() },
            .init(title: "Compare Tags") { [weak self] in self?.compareTags() },
        ])
        let push = SplitActionButton(actions: [
            .init(title: "Push") { [weak self] in self?.pushClicked() },
            .init(title: "Push Tags") { [weak self] in self?.pushRefs(["--tags"], title: "Push tags") },
            .init(title: "Push Notes") { [weak self] in self?.pushRefs(["refs/notes/*:refs/notes/*"], title: "Push notes") },
        ])
        let submodule = SplitActionButton(actions: [
            .init(title: "Submodule Update") { [weak self] in self?.runSimple(["submodule", "update", "--init", "--recursive", "--progress"], title: "Submodule update") },
            .init(title: "Submodule Init") { [weak self] in self?.runSimple(["submodule", "init"], title: "Submodule init") },
            .init(title: "Submodule Sync") { [weak self] in self?.runSimple(["submodule", "sync", "--recursive"], title: "Submodule sync") },
        ])
        let stash = SplitActionButton(actions: [
            .init(title: "Stash Save") { [weak self] in self?.runSimple(["stash", "push", "--include-untracked"], title: "Stash save") },
            .init(title: "Stash Pop") { [weak self] in self?.runSimple(["stash", "pop"], title: "Stash pop") },
            .init(title: "Stash Apply") { [weak self] in self?.runSimple(["stash", "apply"], title: "Stash apply") },
        ])
        let root = repositoryPath
        // The Patches area's serial-apply and send-mail commands, once they exist.
        let applyPatch = ClosureButton(title: "Apply Patch…") {
            CommandRouter.shared.execute(command: PangolinCommand(rawValue: "applypatchserial") ?? .patch, targetPath: root.rawPath)
        }
        let emailPatch = PangolinCommand(rawValue: "sendmail").map { command in
            ClosureButton(title: "Email Patch…") { CommandRouter.shared.execute(command: command, targetPath: root.rawPath) }
        }
        let showLog = ClosureButton(title: "Show Log") { CommandRouter.shared.execute(command: .log, targetPath: root.rawPath) }
        let commit = ClosureButton(title: "Commit…") { CommandRouter.shared.execute(command: .commit, targetPath: root.rawPath) }
        let refresh = ClosureButton(title: "Refresh") { [weak self] in self?.pulledRange = nil; self?.scheduleLoad() }
        let patchButtons = [applyPatch] + (emailPatch.map { [$0] } ?? [])
        for button in patchButtons + [showLog, commit, refresh] { button.bezelStyle = .rounded }
        pull.toolTip = "Shift-click: open the Pull dialog"
        push.toolTip = "Shift-click: open the Push dialog"
        actionControls = [pull, push, submodule, stash, commit] + patchButtons
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.isHidden = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let toolbar = RemoteDialogSupport.hStack([pull, push, submodule, stash] + patchButtons + [showLog, commit, refresh, spinner, stopButton])

        // Tabs (SY-01).
        hideUnchangedCheckbox.state = .on
        hideUnchangedCheckbox.target = self
        hideUnchangedCheckbox.action = #selector(refFilterChanged)
        let refPane = RemoteDialogSupport.vStack([refList.scrollView, hideUnchangedCheckbox])
        refList.scrollView.widthAnchor.constraint(equalTo: refPane.widthAnchor).isActive = true
        let resolveButton = ClosureButton(title: "Resolve…") { RemoteDialogSupport.resolveAction(root: root).handler() }
        let conflictPane = RemoteDialogSupport.vStack([conflicts.scrollView, resolveButton])
        conflicts.scrollView.widthAnchor.constraint(equalTo: conflictPane.widthAnchor).isActive = true
        let tabs: [(String, NSView)] = [
            ("Log", output), ("In Commits", inCommits.scrollView), ("In Changes", inChanges.scrollView),
            ("Conflicts", conflictPane), ("Out Commits", outCommits.scrollView), ("Out Changes", outChanges.scrollView),
            ("Ref List", refPane), ("Tags", tagTable.scrollView),
        ]
        for (title, view) in tabs {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            let container = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
            item.view = container
            tabView.addTabViewItem(item)
        }
        configureTables()

        summaryLabel.lineBreakMode = .byTruncatingTail
        for view in [branchGrid, toolbar, tabView, summaryLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            branchGrid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            branchGrid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            branchGrid.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            toolbar.topAnchor.constraint(equalTo: branchGrid.bottomAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            tabView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: summaryLabel.topAnchor, constant: -8),
            summaryLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            summaryLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    private func configureTables() {
        let root = repositoryPath
        inChanges.onDoubleClick = { [weak self] row in
            guard let self, row < self.incomingFiles.count, let remoteRef = self.remoteRef else { return }
            DiffWindowController.present(filePath: root.appending(self.incomingFiles[row].path),
                                         oldRevision: self.localRef, newRevision: remoteRef, repository: root)
        }
        outChanges.onDoubleClick = { [weak self] row in
            guard let self, row < self.outgoingFiles.count, let remoteRef = self.remoteRef else { return }
            DiffWindowController.present(filePath: root.appending(self.outgoingFiles[row].path),
                                         oldRevision: remoteRef, newRevision: self.localRef, repository: root)
        }
        conflicts.onDoubleClick = { [weak self] row in
            guard let self, row < self.conflictPaths.count else { return }
            CommandRouter.shared.execute(command: .merge, targetPath: root.appending(self.conflictPaths[row]).rawPath)
        }
        tagTable.menuProvider = { [weak self] row in self?.tagMenu(row) ?? [] }
        refList.rowColor = { [weak self] row in
            guard let self, row < self.visibleRefChanges.count else { return nil }
            switch self.visibleRefChanges[row].kind {
            case .new: return .systemGreen
            case .deleted: return .systemRed
            case .rewind, .diverged: return .systemOrange
            default: return nil
            }
        }
    }

    // MARK: - State

    private var localBranch: String { localBranchCombo.stringValue.trimmingCharacters(in: .whitespaces) }
    private var remoteName: String? { remotePopup.titleOfSelectedItem }
    private var selectedRemote: GitRemoteConfig? { remotes.first { $0.name == remoteName } }
    private var localRef: String { localBranch.isEmpty ? "HEAD" : localBranch }
    /// The remote-tracking ref compared against (`origin/main`), nil without remote/branch.
    private var remoteRef: String? {
        guard let remoteName, !remoteBranch.stringValue.isEmpty else { return nil }
        return "\(remoteName)/\(remoteBranch.stringValue)"
    }
    private var environment: [String: String]? {
        guard !sshKeyCheckbox.isHidden, sshKeyCheckbox.state == .on, let key = selectedRemote?.sshKey, !key.isEmpty else { return nil }
        return GitRemotes.sshEnvironment(keyPath: key)
    }

    private func loadInitialState() {
        let root = repositoryPath
        Task { @MainActor in
            self.currentBranch = await GitRemotes.currentBranch(in: root)
            self.localBranchCombo.addItems(withObjectValues: await GitRemotes.localBranches(in: root))
            self.localBranchCombo.stringValue = self.currentBranch ?? ""
            self.reloadRemotes(keepingSelection: false)
        }
    }

    private func reloadRemotes(keepingSelection: Bool) {
        let root = repositoryPath
        Task { @MainActor in
            let previous = keepingSelection ? self.remoteName : nil
            self.remotes = await GitRemotes.loadRemotes(in: root)
            self.remotePopup.removeAllItems()
            self.remotePopup.addItems(withTitles: self.remotes.map(\.name))
            var preferred = previous
            if preferred == nil, !self.localBranch.isEmpty {
                preferred = await GitRemotes.upstream(of: self.localBranch, in: root)?.remote
            }
            if let preferred, self.remotePopup.itemTitles.contains(preferred) {
                self.remotePopup.selectItem(withTitle: preferred)
            }
            await self.remoteSelectionChanged(keepBranch: keepingSelection)
        }
    }

    private func remoteSelectionChanged(keepBranch: Bool) async {
        let remote = selectedRemote
        urlLabel.stringValue = remote.map { $0.pushURL.isEmpty ? $0.url : "\($0.url)  (push: \($0.pushURL))" } ?? "No remote configured — use Manage… to add one"
        urlLabel.toolTip = urlLabel.stringValue
        if let key = remote?.sshKey, !key.isEmpty {
            sshKeyCheckbox.title = "Use the remote's SSH key (\((key as NSString).lastPathComponent))"
            sshKeyCheckbox.isHidden = false
        } else {
            sshKeyCheckbox.isHidden = true
        }
        remoteBranch.remote = remote?.name
        let branches = remote == nil ? [] : await GitRemotes.remoteBranches(of: remote!.name, in: repositoryPath)
        remoteBranch.setItems(branches)
        if !keepBranch || remoteBranch.stringValue.isEmpty {
            remoteBranch.stringValue = await defaultRemoteBranch(remote: remote?.name, branches: branches)
        }
        scheduleLoad()
    }

    private func defaultRemoteBranch(remote: String?, branches: [String]) async -> String {
        let local = localBranch
        guard !local.isEmpty else { return "" }
        if let upstream = await GitRemotes.upstream(of: local, in: repositoryPath), upstream.remote == remote {
            return upstream.branch
        }
        return local
    }

    @objc private func branchesChanged() {
        pulledRange = nil
        Task { @MainActor in await self.remoteSelectionChanged(keepBranch: false) }
    }

    @objc private func remoteChanged() {
        Task { @MainActor in await self.remoteSelectionChanged(keepBranch: false) }
    }

    @objc private func manageRemotes() {
        RemoteDialogSupport.manageRemotes(repository: repositoryPath)
    }

    @objc private func refFilterChanged() {
        showRefChanges()
    }

    /// Reloads ahead/behind, the commit and file tabs and the conflicts.
    private func scheduleLoad() {
        loadGeneration += 1
        let generation = loadGeneration
        let root = repositoryPath
        let local = localRef
        let remoteRef = self.remoteRef
        let pulledRange = self.pulledRange
        Task { @MainActor in
            guard let repo = GitRepository.open(at: root) else { return }
            let remoteExists: Bool
            if let remoteRef {
                remoteExists = (try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "--verify", "--quiet", "refs/remotes/\(remoteRef)"],
                                                                 workingDirectory: root)) != nil
            } else {
                remoteExists = false
            }
            var summary: String
            var incoming: [GitRevision] = []
            var outgoing: [GitRevision] = []
            var inFiles: [(status: String, path: String)] = []
            var outFiles: [(status: String, path: String)] = []
            if let remoteRef, remoteExists {
                let counts = await GitRemotes.aheadBehind(local, remoteRef, in: root)
                let inRange = pulledRange ?? "\(local)..\(remoteRef)"
                incoming = (try? await repo.getLog(limit: 300, range: inRange)) ?? []
                outgoing = (try? await repo.getLog(limit: 300, range: "\(remoteRef)..\(local)")) ?? []
                let inDiff = pulledRange.map { [$0] } ?? ["\(local)...\(remoteRef)"]
                inFiles = GitRemotes.parseNameStatus((try? await GitCLIRunner.runAsync(arguments: ["diff", "--name-status"] + inDiff, workingDirectory: root)) ?? "")
                outFiles = GitRemotes.parseNameStatus((try? await GitCLIRunner.runAsync(arguments: ["diff", "--name-status", "\(remoteRef)...\(local)"], workingDirectory: root)) ?? "")
                summary = "\(local) is \(counts?.ahead ?? 0) commit(s) ahead and \(counts?.behind ?? 0) behind \(remoteRef)"
                if pulledRange != nil { summary += " — In Commits shows what the last pull brought in" }
            } else if let remoteRef {
                // TortoiseGit: "unknown branch on the remote" — everything not on the remote is outgoing.
                outgoing = (try? await repo.getLog(limit: 300, range: local)) ?? []
                if let remoteName = self.remoteName {
                    let output = (try? await GitCLIRunner.runAsync(arguments: ["log", "--format=%H", "--max-count=300", local, "--not", "--remotes=\(remoteName)"], workingDirectory: root)) ?? ""
                    let hashes = Set(output.split(separator: "\n").map(String.init))
                    outgoing = outgoing.filter { hashes.contains($0.hash.string) }
                }
                summary = "\(remoteRef) does not exist yet — pushing creates it."
            } else {
                summary = "Choose a remote and a remote branch."
            }
            let conflicted = await GitRemotes.conflictedPaths(in: root)
            guard generation == self.loadGeneration else { return }

            let format = DateFormatter()
            format.dateStyle = .short
            format.timeStyle = .short
            let rows = { (commits: [GitRevision]) in
                commits.map { [$0.hash.short, $0.subject, $0.author.name, format.string(from: $0.author.date)] }
            }
            self.inCommits.rows = rows(incoming)
            self.outCommits.rows = rows(outgoing)
            self.incomingFiles = inFiles
            self.outgoingFiles = outFiles
            self.inChanges.rows = inFiles.map { [$0.status, $0.path] }
            self.outChanges.rows = outFiles.map { [$0.status, $0.path] }
            self.conflictPaths = conflicted
            self.conflicts.rows = conflicted.map { [$0] }
            self.setTabCount(.inCommits, incoming.count)
            self.setTabCount(.outCommits, outgoing.count)
            self.setTabCount(.conflicts, conflicted.count)
            self.summaryLabel.stringValue = conflicted.isEmpty ? summary : "\(conflicted.count) conflicted file(s) — resolve them before continuing. " + summary
            self.summaryLabel.textColor = conflicted.isEmpty ? .labelColor : .systemRed
        }
    }

    private func setTabCount(_ tab: Tab, _ count: Int) {
        let item = tabView.tabViewItem(at: tab.rawValue)
        let base = (item.identifier as? String) ?? item.label
        item.label = count > 0 ? "\(base) (\(count))" : base
    }

    // MARK: - Running git inline

    /// Runs `commands` one after another with their output in the Log tab (TortoiseGit's Sync runs
    /// everything inside its own window). `snapshotRefs` records refs before and after for the Ref List.
    private func run(_ title: String, commands: [[String]], snapshotRefs: Bool = false,
                     completion: ((Bool, String) -> Void)? = nil) {
        guard runTask == nil else { NSSound.beep(); return }
        tabView.selectTabViewItem(at: Tab.log.rawValue)
        setRunning(true)
        output.appendHeader("— \(title) —")
        let root = repositoryPath
        let environment = self.environment
        runTask = Task { @MainActor in
            let before = snapshotRefs ? await GitRemotes.refSnapshot(in: root) : [:]
            var succeeded = true
            var transcript = ""
            let runner = GitCLIRunner()
            for arguments in commands {
                self.output.appendHeader(GitCLIRunner.commandLine(arguments))
                do {
                    let output = self.output
                    let result = try await runner.stream(arguments: arguments, workingDirectory: root, environment: environment) { text, isError in
                        DispatchQueue.main.async { MainActor.assumeIsolated { output.append(text, isError: isError) } }
                    }
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                    transcript += result.standardOutput + result.standardError
                    if !result.isSuccess || Task.isCancelled {
                        succeeded = false
                        self.output.appendHeader(Task.isCancelled ? "Stopped." : "Failed with exit code \(result.exitCode).")
                        break
                    }
                } catch {
                    self.output.append(error.localizedDescription + "\n", isError: true)
                    succeeded = false
                    break
                }
            }
            if succeeded { self.output.appendHeader("Success.") }
            if snapshotRefs {
                let after = await GitRemotes.refSnapshot(in: root)
                self.refChanges = await GitRemotes.classify(GitRemotes.compareSnapshots(old: before, new: after), in: root)
                self.showRefChanges()
            }
            self.runTask = nil
            self.setRunning(false)
            RepositoryEvents.post(root)
            // The completion may change what the tabs show (e.g. the pulled range): run it first.
            completion?(succeeded, transcript)
            self.scheduleLoad()
        }
    }

    private func setRunning(_ running: Bool) {
        actionControls.forEach { $0.isEnabled = !running }
        stopButton.isHidden = !running
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func stopClicked() {
        runTask?.cancel()
    }

    /// Confirm-kill on close (SY-04).
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard runTask != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "A git command is still running"
        alert.informativeText = "Stop it and close the window?"
        alert.addButton(withTitle: "Stop and Close")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        runTask?.cancel()
        return true
    }

    private func showRefChanges() {
        visibleRefChanges = hideUnchangedCheckbox.state == .on ? refChanges.filter { $0.kind != .same } : refChanges
        refList.rows = visibleRefChanges.map {
            [$0.shortName, $0.typeTitle, $0.kind.title, String($0.oldHash?.prefix(8) ?? ""), String($0.newHash?.prefix(8) ?? "")]
        }
        refList.setEmptyText(refChanges.isEmpty ? "Fetch or pull to see which refs changed" : "No refs changed")
        setTabCount(.refList, refChanges.filter { $0.kind != .same }.count)
    }

    // MARK: - Pull family

    private var shiftHeld: Bool { NSEvent.modifierFlags.contains(.shift) }

    private func requireRemote() -> String? {
        guard let remoteName else {
            NSSound.beep()
            summaryLabel.stringValue = "Add a remote first (Manage…)."
            return nil
        }
        return remoteName
    }

    private func pullClicked() {
        if shiftHeld {
            CommandRouter.shared.execute(command: .pull, targetPath: repositoryPath.rawPath)
            return
        }
        guard let remote = requireRemote() else { return }
        let branch = remoteBranch.stringValue
        let local = localBranch
        // SY-04: pulling always merges into the checked-out branch.
        if !local.isEmpty, let current = currentBranch, local != current {
            let alert = NSAlert()
            alert.messageText = "“\(local)” is not checked out"
            alert.informativeText = "A pull merges into the current branch “\(current)”. Switch to “\(local)” first?"
            alert.addButton(withTitle: "Switch to “\(local)”")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            run("Switch", commands: [["switch", local]]) { [weak self] ok, _ in
                guard ok, let self else { return }
                self.currentBranch = local
                self.pullClicked()
            }
            return
        }
        let root = repositoryPath
        Task { @MainActor in
            let before = (try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "HEAD"], workingDirectory: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var args = ["pull", "--progress"]
            if await GitRemotes.configValue("pull.rebase", in: root) == nil,
               await GitRemotes.configValue("branch.\(local).rebase", in: root) == nil {
                args.append("--no-rebase")
            }
            args.append(remote)
            if !branch.isEmpty { args.append(branch) }
            self.run("Pull", commands: [args], snapshotRefs: true) { ok, transcript in
                if let before, ok { self.pulledRange = "\(before)..HEAD" }
                if RemoteDialogSupport.reportsConflicts(transcript) {
                    self.tabView.selectTabViewItem(at: Tab.conflicts.rawValue)
                } else if ok {
                    self.tabView.selectTabViewItem(at: Tab.inCommits.rawValue)
                }
            }
        }
    }

    private func fetch(rebaseAfterwards: Bool) {
        guard let remote = requireRemote() else { return }
        let root = repositoryPath
        let target = remoteRef
        run(rebaseAfterwards ? "Fetch & Rebase" : "Fetch", commands: [["fetch", "--progress", remote]], snapshotRefs: true) { [weak self] ok, _ in
            guard ok else { return }
            if rebaseAfterwards, let target {
                Task { @MainActor in await PullFetchWindowController.offerRebase(onto: target, root: root) }
            } else {
                self?.tabView.selectTabViewItem(at: Tab.refList.rawValue)
            }
        }
    }

    private func fetchAll() {
        run("Fetch all remotes", commands: [["fetch", "--progress", "--all"]], snapshotRefs: true) { [weak self] ok, _ in
            if ok { self?.tabView.selectTabViewItem(at: Tab.refList.rawValue) }
        }
    }

    private func remoteUpdate() {
        run("Remote update", commands: [["remote", "update"]], snapshotRefs: true) { [weak self] ok, _ in
            if ok { self?.tabView.selectTabViewItem(at: Tab.refList.rawValue) }
        }
    }

    private func pruneRemote() {
        guard let remote = requireRemote() else { return }
        run("Clean up stale remote branches", commands: [["remote", "prune", remote]], snapshotRefs: true) { [weak self] ok, _ in
            if ok { self?.tabView.selectTabViewItem(at: Tab.refList.rawValue) }
        }
    }

    private func compareTags() {
        guard let remote = requireRemote() else { return }
        let root = repositoryPath
        run("Compare tags", commands: [["ls-remote", "--tags", remote]]) { [weak self] ok, transcript in
            guard let self, ok else { return }
            Task { @MainActor in
                let localOutput = (try? await GitCLIRunner.runAsync(arguments: ["show-ref", "--tags", "-d"], workingDirectory: root)) ?? ""
                self.tagComparison = GitRemotes.compareTags(local: GitRemotes.parseTagList(localOutput),
                                                            remote: GitRemotes.parseTagList(transcript))
                self.tagTable.rows = self.tagComparison.map {
                    [$0.name, $0.state.title, String($0.localHash?.prefix(8) ?? ""), String($0.remoteHash?.prefix(8) ?? "")]
                }
                self.tagTable.setEmptyText("No tags on either side")
                self.setTabCount(.tags, self.tagComparison.filter { $0.state != .same }.count)
                self.tabView.selectTabViewItem(at: Tab.tags.rawValue)
            }
        }
    }

    private func tagMenu(_ row: Int) -> [NSMenuItem] {
        guard row < tagComparison.count, let remote = remoteName else { return [] }
        let tag = tagComparison[row]
        var items: [NSMenuItem] = []
        if tag.localHash != nil {
            items.append(ClosureMenuItem(title: "Push Tag “\(tag.name)”", symbol: "arrow.up.circle") { [weak self] in
                self?.run("Push tag", commands: [["push", "--progress", remote, "refs/tags/\(tag.name)"]]) { [weak self] ok, _ in if ok { self?.compareTags() } }
            })
        }
        if tag.remoteHash != nil {
            items.append(ClosureMenuItem(title: "Fetch Tag “\(tag.name)”", symbol: "arrow.down.circle") { [weak self] in
                self?.run("Fetch tag", commands: [["fetch", "--progress", remote, "+refs/tags/\(tag.name):refs/tags/\(tag.name)"]]) { [weak self] ok, _ in if ok { self?.compareTags() } }
            })
        }
        if tag.localHash != nil {
            items.append(ClosureMenuItem(title: "Delete Local Tag", symbol: "trash") { [weak self] in
                self?.run("Delete tag", commands: [["tag", "-d", tag.name]]) { [weak self] ok, _ in if ok { self?.compareTags() } }
            })
        }
        return items
    }

    // MARK: - Push family

    private static let upstreamSuggestionKey = "SyncSuggestSetUpstream"

    private func pushClicked() {
        if shiftHeld {
            CommandRouter.shared.execute(command: .push, targetPath: repositoryPath.rawPath)
            return
        }
        guard let remote = requireRemote() else { return }
        let local = localBranch
        guard !local.isEmpty else { NSSound.beep(); return }
        let branch = remoteBranch.stringValue.isEmpty ? local : remoteBranch.stringValue
        let root = repositoryPath
        Task { @MainActor in
            var args = ["push", "--progress"]
            if self.forceCheckbox.state == .on { args.append("--force-with-lease") }
            // SY-04: suggest tracking the pushed branch when it has none ("don't ask again" remembered).
            if await GitRemotes.upstream(of: local, in: root) == nil,
               UserDefaults.standard.object(forKey: Self.upstreamSuggestionKey) as? Bool != false {
                let alert = NSAlert()
                alert.messageText = "Track “\(remote)/\(branch)”?"
                alert.informativeText = "“\(local)” has no upstream branch. Setting one lets Pull, Push and Sync preselect it."
                alert.addButton(withTitle: "Set Upstream")
                alert.addButton(withTitle: "Not Now")
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Don't ask again"
                let response = alert.runModal()
                if alert.suppressionButton?.state == .on {
                    UserDefaults.standard.set(false, forKey: Self.upstreamSuggestionKey)
                }
                if response == .alertFirstButtonReturn { args.append("-u") }
            }
            args += [remote, "refs/heads/\(local):refs/heads/\(branch)"]
            self.run("Push", commands: [args], snapshotRefs: true) { ok, transcript in
                if !ok, transcript.contains("rejected") || transcript.contains("fetch first") {
                    self.summaryLabel.stringValue = "The remote has commits you do not have yet — pull first, then push."
                    self.summaryLabel.textColor = .systemOrange
                }
            }
        }
    }

    private func pushRefs(_ refs: [String], title: String) {
        guard let remote = requireRemote() else { return }
        var args = ["push", "--progress"]
        if refs == ["--tags"] {
            args += ["--tags", remote]
        } else {
            args += [remote] + refs
        }
        run(title, commands: [args], snapshotRefs: true)
    }

    private func runSimple(_ arguments: [String], title: String) {
        run(title, commands: [arguments]) { [weak self] _, transcript in
            if RemoteDialogSupport.reportsConflicts(transcript) {
                self?.tabView.selectTabViewItem(at: Tab.conflicts.rawValue)
            }
        }
    }
}
