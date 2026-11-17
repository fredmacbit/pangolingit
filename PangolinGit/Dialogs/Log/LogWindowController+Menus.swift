import Cocoa
import PangolinGitCore

/// Context menus of the Log: the commit list (TortoiseGit's `CGitLogListBase::ShowContextMenu`
/// and `GitLogListAction.cpp`), the "Working tree changes" row and the changed-files pane
/// (`CGitStatusListCtrl` inside `CLogDlg`). Mutating commands run in the progress window.
extension LogWindowController {

    // MARK: - Helpers

    private var currentBranchTitle: String { refMap.currentBranch ?? "HEAD" }

    func runGit(_ title: String, _ commands: [[String]], postActions: ((ProgressWindowController.Outcome) -> [ProgressWindowController.PostAction])? = nil) {
        ProgressWindowController.run(title: title, commands: commands, workingDirectory: repositoryPath, postActions: postActions)
    }

    private func confirm(_ message: String, _ informative: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private func item(_ title: String, symbol: String? = nil, _ action: @escaping (LogWindowController) -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, symbol: symbol) { [weak self] in
            guard let self else { return }
            action(self)
        }
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    private var isMergeInProgress: Bool {
        guard let gitDir = repository?.gitDirectory else { return false }
        return FileManager.default.fileExists(atPath: gitDir.appending("MERGE_HEAD").rawPath)
    }

    private var isBisecting: Bool {
        guard let gitDir = repository?.gitDirectory else { return false }
        return FileManager.default.fileExists(atPath: gitDir.appending("BISECT_LOG").rawPath)
    }

    /// Opens git output in a read-only text window.
    func showOutput(title: String, arguments: [String]) {
        let root = repositoryPath
        Task { @MainActor in
            do {
                let output = try await GitCLIRunner().runChecked(arguments: arguments, workingDirectory: root)
                WindowRegistry.shared.present({ LogTextWindowController(title: title, text: output) }, repository: root)
            } catch {
                self.showError(error)
            }
        }
    }

    // MARK: - Diff actions

    /// Compare Revisions against the real parent (the empty tree for a root commit).
    func compareWithPrevious(_ revision: GitRevision, parentIndex: Int) {
        let root = repositoryPath
        let hash = revision.hash.string
        Task { @MainActor in
            let parent = await self.repository?.parent(of: hash, index: parentIndex) ?? GitRepository.emptyTreeHash
            WindowRegistry.shared.present({ FileDiffWindowController(repositoryPath: root, rev1: parent, rev2: hash) }, repository: root)
        }
    }

    func showUnifiedDiff(_ revision: GitRevision) {
        showOutput(title: "Commit \(revision.hash.short) — \(revision.subject)",
                   arguments: ["show", "--format=fuller", "--stat", "--patch", "-M", "--no-color", revision.hash.string])
    }

    func diffFile(_ file: GitChangedFile) {
        let filePath = repositoryPath.appending(file.path)
        if workingTreeRowSelected {
            if file.status == "?" { NSWorkspace.shared.activateFileViewerSelecting([filePath.url]); return }
            DiffWindowController.present(filePath: filePath, oldRevision: "HEAD", newRevision: nil, repository: repositoryPath)
            return
        }
        guard let revision = selectedEntries.first?.revision else { return }
        DiffWindowController.present(filePath: filePath, oldRevision: changedFilesParent ?? GitRepository.emptyTreeHash,
                                     newRevision: revision.hash.string, repository: repositoryPath)
    }

    // MARK: - Commit list menu

    func buildCommitMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = tableView.clickedRow
        if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) {
            tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        let selection = selectedEntries
        if pickerCompletion != nil {
            if !selection.isEmpty { menu.addItem(copyMenu(selection)) }
            return
        }
        if workingTreeRowSelected, selection.isEmpty {
            buildWorkingTreeMenu(menu)
        } else if selection.count == 1, let entry = selection.first {
            buildSingleCommitMenu(menu, entry)
        } else if selection.count > 1 {
            buildMultiCommitMenu(menu, selection)
        }
    }

    /// Menu of the "Working tree changes" row (LG-03).
    private func buildWorkingTreeMenu(_ menu: NSMenu) {
        let root = repositoryPath.rawPath
        menu.addItem(item("Commit…", symbol: "checkmark.circle") { _ in CommandRouter.shared.execute(command: .commit, targetPath: root) })
        menu.addItem(item("Check for Modifications…", symbol: "doc.text.magnifyingglass") { _ in
            CommandRouter.shared.execute(command: .changed, targetPath: root)
        })
        menu.addItem(item("Revert…", symbol: "arrow.uturn.backward") { _ in CommandRouter.shared.execute(command: .revert, targetPath: root) })
        menu.addItem(.separator())
        menu.addItem(item("Stash Changes", symbol: "tray.and.arrow.down") { controller in
            controller.runGit("Stash", [["stash", "push", "--include-untracked"]])
        })
        if isMergeInProgress {
            menu.addItem(item("Abort Merge…") { controller in
                guard controller.confirm("Abort the merge?", "Local changes made during the merge are lost.", button: "Abort Merge") else { return }
                controller.runGit("Abort Merge", [["merge", "--abort"]])
            })
        }
        menu.addItem(.separator())
        menu.addItem(item("Pull…", symbol: "arrow.down.circle") { _ in CommandRouter.shared.execute(command: .pull, targetPath: root) })
        menu.addItem(item("Fetch", symbol: "arrow.down.to.line") { controller in
            controller.runGit("Fetch", [["fetch", "--all", "--progress"]])
        })
        if FileManager.default.fileExists(atPath: repositoryPath.appending(".gitmodules").rawPath) {
            menu.addItem(item("Submodule Update") { controller in
                controller.runGit("Submodule Update", [["submodule", "update", "--init", "--recursive", "--progress"]])
            })
        }
    }

    private func buildSingleCommitMenu(_ menu: NSMenu, _ entry: GitLogEntry) {
        let revision = entry.revision
        let hash = revision.hash.string
        let labels = refMap.labels(for: hash)
        let root = repositoryPath

        // Compare / diff
        menu.addItem(item("Compare with Working Tree", symbol: "plusminus") { controller in
            controller.showOutput(title: "\(revision.hash.short) ↔ working tree", arguments: ["diff", "-M", "--stat", "--patch", "--no-color", hash])
        })
        if revision.parentHashes.count > 1 {
            menu.addItem(submenu("Compare with Previous Revision", revision.parentHashes.enumerated().map { index, parent in
                item("Parent \(index + 1): \(parent.short)") { $0.compareWithPrevious(revision, parentIndex: index) }
            }))
            menu.addItem(submenu("Show Changes as Unified Diff", [
                item("Combined Diff") { $0.showUnifiedDiff(revision) }
            ] + revision.parentHashes.enumerated().map { index, parent in
                item("Against Parent \(index + 1) (\(parent.short))") { controller in
                    controller.showOutput(title: "\(parent.short)..\(revision.hash.short)",
                                          arguments: ["diff", "-M", "--stat", "--patch", "--no-color", "\(hash)^\(index + 1)", hash])
                }
            }))
        } else {
            menu.addItem(item("Compare with Previous Revision") { $0.compareWithPrevious(revision, parentIndex: 0) })
            menu.addItem(item("Show Changes as Unified Diff") { $0.showUnifiedDiff(revision) })
        }
        menu.addItem(.separator())
        menu.addItem(item("Browse Repository", symbol: "folder") { _ in
            WindowRegistry.shared.present({ RepoBrowserWindowController(repositoryPath: root, initialRevision: hash) }, repository: root)
        })
        menu.addItem(item("Export This Version…", symbol: "square.and.arrow.up") { $0.exportVersion(revision) })
        menu.addItem(item("Show Log from Here") { _ in
            WindowRegistry.shared.present({ LogWindowController(repositoryPath: root, revisions: [hash]) }, repository: root)
        })
        menu.addItem(.separator())

        // Branching
        menu.addItem(item("Create Branch at This Version…", symbol: "arrow.triangle.branch") { _ in
            WindowRegistry.shared.present({ CreateBranchTagWindowController(repositoryPath: root, initialBase: hash) }, repository: root)
        })
        menu.addItem(item("Create Tag at This Version…", symbol: "tag") { _ in
            WindowRegistry.shared.present({ CreateBranchTagWindowController(repositoryPath: root, initialBase: hash, createTag: true) }, repository: root)
        })
        for label in labels where label.kind == .localBranch && !label.isCurrent {
            menu.addItem(item("Switch to “\(label.shortName)”") { $0.runGit("Switch", [["switch", label.shortName]]) })
        }
        menu.addItem(item("Checkout This Commit (Detached HEAD)…") { controller in
            guard controller.confirm("Check out \(revision.hash.short)?",
                                     "HEAD will be detached at this commit. Commits made there belong to no branch until you create one.",
                                     button: "Checkout") else { return }
            controller.runGit("Checkout", [["switch", "--detach", hash]])
        })
        let mergeSource = labels.first(where: { $0.isBranch && !$0.isCurrent })?.shortName ?? hash
        if hash != refMap.headHash {
            menu.addItem(item("Merge “\(mergeSource == hash ? revision.hash.short : mergeSource)” into “\(currentBranchTitle)”…") { controller in
                guard controller.confirm("Merge into \(controller.currentBranchTitle)?", "Runs git merge \(mergeSource).", button: "Merge") else { return }
                controller.runGit("Merge", [["merge", "--no-edit", mergeSource]])
            })
            menu.addItem(item("Rebase “\(currentBranchTitle)” onto This…") { controller in
                guard controller.confirm("Rebase \(controller.currentBranchTitle) onto \(revision.hash.short)?",
                                         "Commits of the current branch not in this commit are re-applied on top of it.", button: "Rebase") else { return }
                controller.runGit("Rebase", [["rebase", hash]])
            })
        }
        menu.addItem(item("Cherry-Pick This Commit", symbol: "arrow.right.doc.on.clipboard") { controller in
            guard controller.confirm("Cherry-pick \(revision.hash.short)?", "“\(revision.subject)” is applied on top of \(controller.currentBranchTitle).",
                                     button: "Cherry-Pick") else { return }
            controller.runGit("Cherry-Pick", [["cherry-pick"] + (revision.isMergeCommit ? ["-m", "1"] : []) + [hash]])
        })
        menu.addItem(item("Revert This Commit…", symbol: "arrow.uturn.backward") { controller in
            guard controller.confirm("Revert commit \(revision.hash.short)?",
                                     "A new commit undoing “\(revision.subject)” will be created on the current branch.", button: "Revert") else { return }
            controller.runGit("Revert", [["revert", "--no-edit"] + (revision.isMergeCommit ? ["-m", "1"] : []) + [hash]])
        })
        menu.addItem(item("Reset “\(currentBranchTitle)” to This…", symbol: "clock.arrow.circlepath") { _ in
            WindowRegistry.shared.present({ ResetWindowController(repositoryPath: root, initialCommit: hash) }, repository: root)
        })
        if isBisecting {
            menu.addItem(item("Bisect: Mark as Good") { $0.runGit("Bisect", [["bisect", "good", hash]]) })
            menu.addItem(item("Bisect: Mark as Bad") { $0.runGit("Bisect", [["bisect", "bad", hash]]) })
            menu.addItem(item("Bisect: Skip") { $0.runGit("Bisect", [["bisect", "skip", hash]]) })
        }

        // Ref labels (LG-18)
        let refLabels = labels.filter { $0.kind != .head }
        if !refLabels.isEmpty {
            menu.addItem(.separator())
            for label in refLabels {
                menu.addItem(submenu("“\(label.shortName)”", refLabelItems(label)))
            }
            let deletable = refLabels.filter { ($0.isBranch && !$0.isCurrent) || $0.isTag }
            if deletable.count > 1 {
                menu.addItem(item("Delete All \(deletable.count) Refs…") { $0.deleteRefs(deletable) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Format Patch…", symbol: "doc.badge.plus") { $0.formatPatches([revision]) })
        menu.addItem(item("Edit Notes…", symbol: "note.text") { $0.editNotes(entry) })
        menu.addItem(item("Show Branches Containing This Commit…") { _ in
            WindowRegistry.shared.present({ BranchesContainingWindowController(repositoryPath: root, commit: revision) }, repository: root)
        })
        menu.addItem(.separator())
        menu.addItem(copyMenu([entry]))
    }

    /// Commands for one ref label (TortoiseGit's label context menu).
    private func refLabelItems(_ label: GitRefLabel) -> [NSMenuItem] {
        let name = label.shortName
        let root = repositoryPath
        var items: [NSMenuItem] = []
        switch label.kind {
        case .localBranch:
            if !label.isCurrent {
                items.append(item("Switch to \(name)") { $0.runGit("Switch", [["switch", name]]) })
                items.append(item("Merge into “\(currentBranchTitle)”…") { controller in
                    guard controller.confirm("Merge \(name) into \(controller.currentBranchTitle)?", "", button: "Merge") else { return }
                    controller.runGit("Merge", [["merge", "--no-edit", name]])
                })
                items.append(item("Rebase “\(currentBranchTitle)” onto \(name)…") { controller in
                    guard controller.confirm("Rebase \(controller.currentBranchTitle) onto \(name)?", "", button: "Rebase") else { return }
                    controller.runGit("Rebase", [["rebase", name]])
                })
            }
            items.append(item("Push…") { _ in CommandRouter.shared.execute(command: .push, targetPath: root.rawPath) })
            items.append(item("Show Log of \(name)") { _ in
                WindowRegistry.shared.present({ LogWindowController(repositoryPath: root, revisions: [name]) }, repository: root)
            })
        case .remoteBranch:
            let local = name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? name
            items.append(item("Switch to New Tracking Branch “\(local)”") { $0.runGit("Switch", [["switch", "--track", name]]) })
            items.append(item("Merge into “\(currentBranchTitle)”…") { controller in
                guard controller.confirm("Merge \(name) into \(controller.currentBranchTitle)?", "", button: "Merge") else { return }
                controller.runGit("Merge", [["merge", "--no-edit", name]])
            })
            items.append(item("Rebase “\(currentBranchTitle)” onto \(name)…") { controller in
                guard controller.confirm("Rebase \(controller.currentBranchTitle) onto \(name)?", "", button: "Rebase") else { return }
                controller.runGit("Rebase", [["rebase", name]])
            })
            items.append(item("Create Branch from \(name)…") { _ in
                WindowRegistry.shared.present({ CreateBranchTagWindowController(repositoryPath: root, initialBase: name) }, repository: root)
            })
        case .tag, .annotatedTag:
            items.append(item("Push Tag to Remote") { controller in
                let remote = controller.refMap.remoteNames.sorted().first ?? "origin"
                controller.runGit("Push Tag", [["push", "--progress", remote, "refs/tags/\(name)"]])
            })
            if label.kind == .annotatedTag {
                items.append(item("Show Tag") { $0.showOutput(title: "Tag \(name)", arguments: ["show", "--no-patch", "--format=fuller", "refs/tags/\(name)"]) })
            }
        default:
            break
        }
        if (label.isBranch && !label.isCurrent) || label.isTag {
            items.append(.separator())
            items.append(item("Delete \(name)…", symbol: "trash") { $0.deleteRefs([label]) })
        }
        items.append(item("Copy Name") { $0.copyToClipboard(name) })
        return items
    }

    private func buildMultiCommitMenu(_ menu: NSMenu, _ selection: [GitLogEntry]) {
        let root = repositoryPath
        // Newest first as listed; `older` is the bottom-most selected row.
        let newer = selection.first!.revision
        let older = selection.last!.revision
        if selection.count == 2 {
            menu.addItem(item("Compare Revisions", symbol: "plusminus") { _ in
                WindowRegistry.shared.present({ FileDiffWindowController(repositoryPath: root, rev1: older.hash.string, rev2: newer.hash.string) },
                                              repository: root)
            })
            menu.addItem(item("Show Changes as Unified Diff") { controller in
                controller.showOutput(title: "\(older.hash.short)..\(newer.hash.short)",
                                      arguments: ["diff", "-M", "--stat", "--patch", "--no-color", older.hash.string, newer.hash.string])
            })
            let a = older.hash.string, b = newer.hash.string
            menu.addItem(submenu("Show Log of", [
                item("\(older.hash.short)..\(newer.hash.short) (in newer, not in older)") { _ in
                    WindowRegistry.shared.present({ LogWindowController(repositoryPath: root, revisions: ["\(a)..\(b)"]) }, repository: root)
                },
                item("\(newer.hash.short)..\(older.hash.short) (in older, not in newer)") { _ in
                    WindowRegistry.shared.present({ LogWindowController(repositoryPath: root, revisions: ["\(b)..\(a)"]) }, repository: root)
                },
                item("\(older.hash.short)...\(newer.hash.short) (in either, not both)") { _ in
                    WindowRegistry.shared.present({ LogWindowController(repositoryPath: root, revisions: ["\(a)...\(b)"]) }, repository: root)
                }
            ]))
            menu.addItem(item("Bisect Start (Older Good, Newer Bad)") { controller in
                controller.runGit("Bisect Start", [["bisect", "start", b, a]]) { outcome in
                    outcome.succeeded ? [ProgressWindowController.PostAction("Bisect…") {
                        WindowRegistry.shared.present({ BisectWindowController(repositoryPath: root) }, repository: root)
                    }] : []
                }
            })
            menu.addItem(.separator())
        }
        let merges = selection.filter { $0.revision.isMergeCommit }
        menu.addItem(item("Revert \(selection.count) Commits…", symbol: "arrow.uturn.backward") { controller in
            guard merges.isEmpty else {
                controller.statusLabel.stringValue = "Merge commits cannot be reverted together with others; revert them one by one."
                NSSound.beep()
                return
            }
            guard controller.confirm("Revert \(selection.count) commits?", "One revert commit per selected commit, newest first.", button: "Revert") else { return }
            controller.runGit("Revert", [["revert", "--no-edit"] + selection.map(\.revision.hash.string)])
        })
        menu.addItem(item("Cherry-Pick \(selection.count) Commits") { controller in
            guard merges.isEmpty else {
                controller.statusLabel.stringValue = "Merge commits cannot be cherry-picked together with others."
                NSSound.beep()
                return
            }
            guard controller.confirm("Cherry-pick \(selection.count) commits?", "Applied oldest first on top of \(controller.currentBranchTitle).",
                                     button: "Cherry-Pick") else { return }
            controller.runGit("Cherry-Pick", [["cherry-pick"] + selection.reversed().map(\.revision.hash.string)])
        })
        menu.addItem(item("Combine to One Commit…") { $0.combine(selection) })
        menu.addItem(item("Format Patch for \(selection.count) Commits…", symbol: "doc.badge.plus") { $0.formatPatches(selection.map(\.revision)) })
        menu.addItem(.separator())
        menu.addItem(copyMenu(selection))
    }

    /// TortoiseGit's "Copy to clipboard" submenu.
    private func copyMenu(_ selection: [GitLogEntry]) -> NSMenuItem {
        func copy(_ title: String, _ transform: @escaping (GitLogEntry) -> String) -> NSMenuItem {
            item(title) { controller in controller.copyToClipboard(selection.map(transform).joined(separator: "\n")) }
        }
        return submenu("Copy to Clipboard", [
            copy("Full Information", fullInformation(_:)),
            copy("SHA-1") { $0.revision.hash.string },
            copy("Short SHA-1") { $0.revision.hash.short },
            copy("Subject") { $0.revision.subject },
            copy("Message") { $0.revision.fullMessage },
            copy("Author") { "\($0.revision.author.name) <\($0.revision.author.email)>" },
            copy("Author Name") { $0.revision.author.name },
            copy("Author Email") { $0.revision.author.email },
            copy("Ref Names") { [refMap] entry in refMap.labels(for: entry.revision.hash.string).map(\.shortName).joined(separator: ", ") }
        ])
    }

    // MARK: - Commit actions

    private func exportVersion(_ revision: GitRevision) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(repositoryPath.filename)-\(revision.hash.short).zip"
        panel.message = "Export the files of \(revision.hash.short) as .zip, .tar or .tar.gz"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.lastPathComponent.lowercased()
        let format = name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") ? "tar.gz" : (name.hasSuffix(".tar") ? "tar" : "zip")
        runGit("Export", [["archive", "--format=\(format)", "-o", url.path, revision.hash.string]]) { outcome in
            outcome.succeeded ? [ProgressWindowController.PostAction("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }] : []
        }
    }

    /// `git format-patch`, one numbered patch per commit, oldest first.
    func formatPatches(_ revisions: [GitRevision]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Patches"
        panel.message = "Choose the folder for the patch files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ordered = revisions.sorted { (row(forHash: $0.hash.string) ?? 0) > (row(forHash: $1.hash.string) ?? 0) }
        let commands = ordered.enumerated().map { index, revision in
            ["format-patch", "-o", url.path, "--start-number", "\(index + 1)", "-1", revision.hash.string]
        }
        runGit("Format Patch", commands) { outcome in
            outcome.succeeded ? [ProgressWindowController.PostAction("Show in Finder") { NSWorkspace.shared.open(url) }] : []
        }
    }

    /// `git notes` editor (LG-19). An empty text removes the note.
    private func editNotes(_ entry: GitLogEntry) {
        let alert = NSAlert()
        alert.messageText = "Notes for \(entry.revision.hash.short)"
        alert.informativeText = "Stored with git notes (refs/notes/commits). Leave empty to remove the note."
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
        scroll.borderType = .bezelBorder
        let textView = scroll.documentView as! NSTextView
        textView.string = entry.notes
        textView.font = NSFont.systemFont(ofSize: 12)
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = textView
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = entry.revision.hash.string
        let args = text.isEmpty ? ["notes", "remove", "--ignore-missing", hash] : ["notes", "add", "-f", "-m", text, hash]
        let root = repositoryPath
        Task { @MainActor in
            do {
                try await GitCLIRunner().runChecked(arguments: args, workingDirectory: root)
            } catch {
                self.showError(error)
            }
        }
    }

    private func deleteRefs(_ labels: [GitRefLabel]) {
        let names = labels.map(\.shortName).joined(separator: ", ")
        let remote = labels.contains { $0.kind == .remoteBranch }
        guard confirm("Delete \(names)?",
                      remote ? "Remote branches are deleted on the server." : "Unmerged commits of deleted branches can only be found through the reflog.",
                      button: "Delete") else { return }
        var commands: [[String]] = []
        for label in labels {
            switch label.kind {
            case .localBranch:
                commands.append(["branch", "-D", label.shortName])
            case .tag, .annotatedTag:
                commands.append(["tag", "-d", label.shortName])
            case .remoteBranch:
                let parts = label.shortName.split(separator: "/", maxSplits: 1).map(String.init)
                if parts.count == 2 { commands.append(["push", "--progress", parts[0], "--delete", parts[1]]) }
            default:
                break
            }
        }
        guard !commands.isEmpty else { return }
        runGit("Delete", commands)
    }

    /// TortoiseGit's "Combine to one commit" (LG-21): squashes a contiguous first-parent range of
    /// the current branch. Commits above the range are re-applied with cherry-pick.
    private func combine(_ selection: [GitLogEntry]) {
        let revisions = selection.map(\.revision)
        guard let newest = revisions.first, let oldest = revisions.last, let base = oldest.parentHashes.first else {
            statusLabel.stringValue = "The oldest selected commit has no parent; it cannot be combined."
            NSSound.beep()
            return
        }
        for (index, revision) in revisions.enumerated() where index + 1 < revisions.count {
            guard revision.parentHashes.count == 1, revision.parentHashes.first == revisions[index + 1].hash else {
                statusLabel.stringValue = "Combine needs consecutive commits without merges."
                NSSound.beep()
                return
            }
        }
        // The range must be on the current branch: walk first parents down from HEAD.
        guard let head = refMap.headHash else { return }
        var above: [GitRevision] = []
        var cursor = head
        while cursor != newest.hash.string {
            guard let revision = entry(forHash: cursor)?.revision, let parent = revision.parentHashes.first,
                  revision.parentHashes.count == 1 else {
                statusLabel.stringValue = "The selected commits are not a straight part of the current branch."
                NSSound.beep()
                return
            }
            above.append(revision)
            cursor = parent.string
        }
        let tracked = workingTreeChanges.filter { $0.status != .untracked }
        guard tracked.isEmpty else {
            statusLabel.stringValue = "Commit or stash your changes before combining commits."
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Combine \(revisions.count) commits into one"
        alert.informativeText = above.isEmpty
            ? "The commits are replaced by a single commit with this message."
            : "The commits are replaced by a single commit; the \(above.count) newer commit(s) are re-applied on top."
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 200)
        scroll.borderType = .bezelBorder
        let textView = scroll.documentView as! NSTextView
        textView.string = revisions.reversed().map(\.fullMessage).joined(separator: "\n\n")
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Combine")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let message = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        var commands: [[String]] = []
        if !above.isEmpty { commands.append(["reset", "--hard", newest.hash.string]) }
        commands.append(["reset", "--soft", base.string])
        commands.append(["commit", "--no-verify", "-m", message])
        if !above.isEmpty { commands.append(["cherry-pick", "\(newest.hash.string)..\(head)"]) }
        runGit("Combine Commits", commands) { [head] outcome in
            outcome.succeeded ? [] : [ProgressWindowController.PostAction("Restore Original (reset --hard \(String(head.prefix(8))))") { [weak self] in
                self?.runGit("Restore", [["cherry-pick", "--abort"], ["reset", "--hard", head]])
            }]
        }
    }

    // MARK: - Changed files menu (LG-12)

    func buildFilesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = changedFilesTableView.clickedRow
        if clicked >= 0, !changedFilesTableView.selectedRowIndexes.contains(clicked) {
            changedFilesTableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        let files = changedFilesTableView.selectedRowIndexes.compactMap { listedFiles.indices.contains($0) ? listedFiles[$0] : nil }
        guard !files.isEmpty else { return }
        let root = repositoryPath
        let existing = files.map { root.appending($0.path).url }.filter { FileManager.default.fileExists(atPath: $0.path) }

        if workingTreeRowSelected {
            if files.count == 1, let file = files.first, file.status != "?" {
                menu.addItem(item("Compare with Base", symbol: "plusminus") { $0.diffFile(file) })
            }
        } else if let revision = selectedEntries.first?.revision {
            let hash = revision.hash.string
            let parent = changedFilesParent
            if files.count == 1, let file = files.first {
                let filePath = root.appending(file.path)
                if file.status != "D" {
                    menu.addItem(item("Compare with Previous Revision", symbol: "plusminus") { $0.diffFile(file) })
                    menu.addItem(item("Compare with Working Tree") { _ in
                        DiffWindowController.present(filePath: filePath, oldRevision: hash, newRevision: nil, repository: root)
                    })
                }
                menu.addItem(item("Show Changes as Unified Diff") { controller in
                    controller.showOutput(title: "\(file.path) @ \(revision.hash.short)",
                                          arguments: ["diff", "-M", "--no-color", parent ?? GitRepository.emptyTreeHash, hash, "--"]
                                            + [file.oldPath, file.path].compactMap { $0 })
                })
                menu.addItem(.separator())
                menu.addItem(item("Show Log of This File") { _ in
                    WindowRegistry.shared.present({ LogWindowController(repositoryPath: root, path: file.path) }, repository: root)
                })
                if file.isSubmodule, FileManager.default.fileExists(atPath: filePath.appending(".git").rawPath) {
                    menu.addItem(item("Show Log of Submodule") { _ in
                        WindowRegistry.shared.present({ LogWindowController(repositoryPath: filePath) }, repository: filePath)
                    })
                }
                if file.oldPath != nil {
                    menu.addItem(item("Show Log Before Rename") { _ in
                        WindowRegistry.shared.present({ LogWindowController(repositoryPath: root, path: file.oldPath, revisions: [parent ?? hash]) },
                                                      repository: root)
                    })
                }
                if FileManager.default.fileExists(atPath: filePath.rawPath) {
                    menu.addItem(item("Blame (Working Tree)") { _ in CommandRouter.shared.execute(command: .blame, targetPath: filePath.rawPath) })
                }
                if file.status != "D", !file.isSubmodule {
                    menu.addItem(item("Save Revision to…", symbol: "square.and.arrow.down") { $0.saveRevision(of: file, at: hash) })
                    menu.addItem(item("Open This Revision") { $0.openRevision(of: file, at: hash) })
                }
                menu.addItem(.separator())
            }
            // Revert files to this or the parent revision (TortoiseGit "Revert to this revision").
            let restorable = files.filter { $0.status != "D" && !$0.isSubmodule }
            if !restorable.isEmpty {
                menu.addItem(item("Revert to This Revision…") { controller in
                    let paths = restorable.map(\.path)
                    guard controller.confirm("Revert \(paths.count) file(s) to \(revision.hash.short)?",
                                             "The working tree files are replaced by their content in this commit.", button: "Revert") else { return }
                    controller.runGit("Revert to Revision", [["checkout", hash, "--"] + paths])
                })
            }
            if let parent {
                menu.addItem(item("Revert Changes of This Commit…") { controller in
                    let existed = files.filter { $0.status != "A" }.map { $0.oldPath ?? $0.path }
                    let added = files.filter { $0.status == "A" }.map(\.path)
                    guard controller.confirm("Revert \(files.count) file(s) to the parent revision?",
                                             "The files are restored as they were before \(revision.hash.short); files it added are removed.",
                                             button: "Revert") else { return }
                    var commands: [[String]] = []
                    if !existed.isEmpty { commands.append(["checkout", parent, "--"] + existed) }
                    if !added.isEmpty { commands.append(["rm", "-f", "--ignore-unmatch", "--"] + added) }
                    controller.runGit("Revert Changes", commands)
                })
            }
            if revision.parentHashes.count > 1 {
                menu.addItem(submenu("List Changes Against", revision.parentHashes.enumerated().map { index, parentHash in
                    let entryItem = item("Parent \(index + 1): \(parentHash.short)") { controller in
                        controller.loadChangedFiles(for: revision, parentIndex: index)
                    }
                    entryItem.state = index == changedFilesParentIndex ? .on : .off
                    return entryItem
                }))
            }
            menu.addItem(.separator())
        }
        if !existing.isEmpty {
            menu.addItem(item("Show in Finder", symbol: "folder") { _ in NSWorkspace.shared.activateFileViewerSelecting(existing) })
            menu.addItem(item("Open") { _ in existing.forEach { NSWorkspace.shared.open($0) } })
        }
        menu.addItem(submenu("Copy to Clipboard", [
            item("Paths") { $0.copyToClipboard(files.map(\.path).joined(separator: "\n")) },
            item("Full Paths") { $0.copyToClipboard(files.map { root.appending($0.path).rawPath }.joined(separator: "\n")) },
            item("Names") { $0.copyToClipboard(files.map { ($0.path as NSString).lastPathComponent }.joined(separator: "\n")) },
            item("All Information") { _ in
                let text = files.map { file in
                    [LogWindowController.actionTitle(file), file.path, file.oldPath ?? "", file.added.map { "+\($0)" } ?? "", file.removed.map { "-\($0)" } ?? ""]
                        .joined(separator: "\t")
                }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        ]))
    }

    private func revisionData(of file: GitChangedFile, at hash: String) async throws -> Data {
        try await GitCLIRunner.runDataAsync(arguments: ["show", "\(hash):\(file.path)"], workingDirectory: repositoryPath)
    }

    private func saveRevision(of file: GitChangedFile, at hash: String) {
        let panel = NSSavePanel()
        let name = (file.path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        panel.nameFieldStringValue = ext.isEmpty ? "\(base)-\(hash.prefix(8))" : "\(base)-\(hash.prefix(8)).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                try await self.revisionData(of: file, at: hash).write(to: url)
            } catch {
                self.showError(error)
            }
        }
    }

    private func openRevision(of file: GitChangedFile, at hash: String) {
        Task { @MainActor in
            do {
                let data = try await self.revisionData(of: file, at: hash)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinGit-Log/\(hash.prefix(8))", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent((file.path as NSString).lastPathComponent)
                try data.write(to: url)
                NSWorkspace.shared.open(url)
            } catch {
                self.showError(error)
            }
        }
    }
}
