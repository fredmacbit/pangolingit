import Cocoa
import PangolinGitCore

/// The commit itself (TortoiseGit's `CCommitDlg::OnOK`): checks, then the git commands in the
/// progress window with ReCommit / Push / Pull / Create Tag as follow-ups, and Commit & Push.
extension CommitWindowController {

    @objc func onCommitClicked() {
        guard !isCommitting, commitButton.isEnabled, let repo = repository else { return }
        Task { @MainActor in
            await self.commit(repo)
        }
    }

    /// Two- or three-button question; returns the index of the chosen button.
    private func ask(_ title: String, _ detail: String, buttons: [String], style: NSAlert.Style = .warning) -> Int {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = detail
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    private func tell(_ title: String, _ detail: String) {
        _ = ask(title, detail, buttons: ["OK"])
    }

    private func commit(_ repo: GitRepository) async {
        // Message: Bug-ID, template and sign-off checks, then cleanup (CM-03, CM-09, CM-10, CM-11).
        var raw = messageTextView.string
        if let bugtraq {
            let id = bugIDField.stringValue.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty && !bugtraq.isValid(id: id) {
                tell("Invalid issue number", "Only numbers (separated by commas) are allowed in “\(bugtraq.label)”.")
                window?.makeFirstResponder(bugIDField)
                return
            }
            if id.isEmpty && bugtraq.warnIfNoIssue {
                guard ask("No issue number entered", "Commit without referencing an issue?", buttons: ["Commit", "Cancel"]) == 0 else {
                    window?.makeFirstResponder(bugIDField)
                    return
                }
            }
            raw = bugtraq.apply(id: id, to: raw)
        }
        if let template, CommitMessage.isUnchangedTemplate(message: raw, template: template, commentChar: commentChar) {
            guard ask("Commit message template not edited", "The message is still the unchanged commit.template. Commit anyway?",
                      buttons: ["Commit Anyway", "Cancel"]) == 0 else { return }
        }
        if warnNoSignedOffBy, let line = await signOffLine(), !raw.contains(line) {
            switch ask("No Signed-off-by line", "This repository asks for a sign-off (tgit.warnnosignedoffby).",
                       buttons: ["Add Sign-off", "Commit Without", "Cancel"]) {
            case 0:
                raw = CommitMessage.appendingSignOff(raw, line: line)
                setMessage(CommitMessage.appendingSignOff(messageTextView.string, line: line))
            case 1: break
            default: return
            }
        }
        let message = CommitMessage.cleanup(raw, commentChar: commentChar)
        guard !message.isEmpty else {
            tell("Empty Commit Message", "Please enter a commit message before committing.")
            return
        }
        if message.count < minimumMessageLength {
            tell("Commit message too short", "This repository requires at least \(minimumMessageLength) characters (tgit.logminsize).")
            return
        }

        // Branch (CM-01).
        var newBranch: String?
        if newBranchCheckbox.state == .on {
            let name = newBranchField.stringValue.trimmingCharacters(in: .whitespaces)
            guard await repo.isValidBranchName(name) else {
                tell("Invalid branch name", name.isEmpty ? "Enter a name for the new branch." : "“\(name)” is not a valid branch name.")
                window?.makeFirstResponder(newBranchField)
                return
            }
            if await repo.refExists("refs/heads/\(name)") {
                tell("Branch already exists", "A branch named “\(name)” exists. Delete it first or choose a different name.")
                window?.makeFirstResponder(newBranchField)
                return
            }
            if await repo.refExists("refs/tags/\(name)") {
                guard ask("A tag with this name exists", "“\(name)” would be ambiguous between the tag and the new branch.",
                          buttons: ["Continue", "Cancel"]) == 0 else { return }
            }
            newBranch = name
        } else if await repo.isHeadDetached() {
            switch ask("You are on a detached HEAD", "A commit here belongs to no branch and is easily lost. Create a branch for it?",
                       buttons: ["Create Branch…", "Commit Anyway", "Cancel"]) {
            case 0:
                newBranchCheckbox.state = .on
                newBranchField.isEnabled = true
                window?.makeFirstResponder(newBranchField)
                return
            case 1: break
            default: return
            }
        }

        // Files (CM-04, CM-12, CM-16).
        let amend = amendCheckbox.state == .on
        let messageOnly = messageOnlyCheckbox.state == .on
        let commitsIndex = isStagingEnabled || isMergeInProgress
        let checked = messageOnly ? [] : statusListView.checkedItems
        if !messageOnly && !amend && !isMergeInProgress {
            let nothing = isStagingEnabled ? !statusListView.listedItems.contains { Self.isStagedEntry($0.info) } : checked.isEmpty
            if nothing {
                tell(isStagingEnabled ? "Nothing staged" : "No Files Selected",
                     isStagingEnabled ? "Stage at least one file or hunk, or tick Message only."
                                      : "Please select at least one file to commit, or tick Message only.")
                return
            }
        }
        if !messageOnly, statusListView.listedItems.contains(where: { $0.info.isConflicted }) {
            guard ask("Unresolved conflicts", "Some files still have merge conflicts. Committing a checked conflicted file marks it resolved.",
                      buttons: ["Commit Anyway", "Cancel"]) == 0 else { return }
        }
        guard await confirmNoConflictMarkers(in: checked), await confirmSubmodulesClean(checked, repo: repo) else { return }

        // Commands.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PangolinGit-COMMIT_EDITMSG-\(UUID().uuidString)")
        do {
            try (message + "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            tell("Could not save the commit message", error.localizedDescription)
            return
        }
        if let old = messageFile { try? FileManager.default.removeItem(at: old) }
        messageFile = file

        var plan = CommitPlan(messageFile: file.path)
        plan.newBranch = newBranch
        plan.amend = amend
        plan.allowEmpty = messageOnly
        if !messageOnly && !isStagingEnabled {
            // Staged deletions and rename sources exist in neither the index nor the working tree,
            // so `git add` would reject them; `commit --only` picks them up by itself.
            plan.pathsToStage = checked.filter { $0.status != .deleted }.map(\.path)
        }
        if !commitsIndex {
            // Renames need both sides in the pathspec, or only half of the rename is committed.
            // A file added to the index and then deleted from disk is known neither to HEAD nor,
            // after `git add -A`, to the index: it is dropped from the index but not named (CM-16).
            let addedThenDeleted = { (item: StatusListItem) in item.status == .missing && item.info.stagedStatus == .added }
            let paths = checked.filter { !addedThenDeleted($0) }
                .flatMap { [$0.info.path] + ($0.info.originalPath.map { [$0] } ?? []) }
            if paths.isEmpty && !amend && !messageOnly {
                tell("Nothing to commit", "The checked files were added and then deleted again; there is no change to commit.")
                return
            }
            plan.commitPaths = paths
        }
        if setAuthorCheckbox.state == .on {
            let author = authorField.stringValue.trimmingCharacters(in: .whitespaces)
            guard author.contains("<") && author.hasSuffix(">") else {
                tell("Invalid author", "Enter the author as “Name <email>”.")
                window?.makeFirstResponder(authorField)
                return
            }
            plan.author = author
        }
        if setDateCheckbox.state == .on {
            plan.date = amend && resetDateCheckbox.state == .on ? "now" : CommitPlan.dateArgument(datePicker.dateValue)
        }

        run(plan, message: message, repo: repo)
    }

    /// CM-16: unresolved `<<<<<<<` / `>>>>>>>` blocks in checked text files.
    private func confirmNoConflictMarkers(in items: [StatusListItem]) async -> Bool {
        let root = repositoryPath
        let paths = items.filter { !$0.info.isDirectory && !$0.info.isSubmodule && $0.status != .deleted && $0.status != .missing }.map(\.path)
        let offenders = await Task.detached(priority: .userInitiated) { () -> [String] in
            paths.filter { path in
                let url = root.appending(path).url
                guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size < 2_000_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return CommitMessage.containsConflictMarkers(text)
            }
        }.value
        guard !offenders.isEmpty else { return true }
        return ask("Conflict markers found", "These files still contain conflict markers:\n" + offenders.prefix(10).joined(separator: "\n"),
                   buttons: ["Commit Anyway", "Cancel"]) == 0
    }

    /// CM-16: a checked submodule with its own uncommitted changes (TortoiseGit offers to commit it first).
    private func confirmSubmodulesClean(_ items: [StatusListItem], repo: GitRepository) async -> Bool {
        for item in items where item.info.isSubmodule {
            guard await repo.isSubmoduleDirty(item.path) else { continue }
            switch ask("Submodule “\(item.path)” has uncommitted changes",
                       "The commit records only the submodule's current commit, not those changes.",
                       buttons: ["Commit Submodule…", "Ignore", "Cancel"]) {
            case 0:
                CommandRouter.shared.execute(command: .commit, targetPath: repositoryPath.appending(item.path).rawPath)
                return false
            case 1: continue
            default: return false
            }
        }
        return true
    }

    private func setCommitting(_ committing: Bool) {
        isCommitting = committing
        commitButton.isEnabled = !committing
        commitActionButton.isEnabled = !committing
        cancelButton.isEnabled = !committing
        if !committing { updateCommitButtonState() }
    }

    /// Runs the plan in the progress window (CM-19, CM-21: git's full output, hooks included).
    private func run(_ plan: CommitPlan, message: String, repo: GitRepository) {
        let action = commitAction
        let root = repositoryPath
        ConfigManager.shared.addRecentCommitMessage(message, forRepository: root.rawPath)
        setCommitting(true)
        statusLabel.stringValue = "Committing..."

        ProgressWindowController.run(
            title: "Commit",
            commands: plan.commands(),
            workingDirectory: root,
            postActions: { outcome in
                guard outcome.succeeded else { return [] }
                var actions: [ProgressWindowController.PostAction] = []
                if action != .commitAndPush {
                    actions.append(.init("Push…") { CommandRouter.shared.execute(command: .push, targetPath: root.rawPath) })
                }
                actions.append(.init("Pull…") { CommandRouter.shared.execute(command: .pull, targetPath: root.rawPath) })
                if action != .reCommit {
                    actions.append(.init("ReCommit") { CommandRouter.shared.execute(command: .commit, targetPath: root.rawPath) })
                }
                actions.append(.init("Create Tag…") {
                    WindowRegistry.shared.present({ CreateBranchTagWindowController(repositoryPath: root, createTag: true) }, repository: root)
                })
                return actions
            },
            onFinish: { [weak self] outcome in
                self?.commitFinished(succeeded: outcome.succeeded, action: action, repo: repo)
            })
    }

    private func commitFinished(succeeded: Bool, action: CommitAction, repo: GitRepository) {
        setCommitting(false)
        guard succeeded else {
            statusLabel.stringValue = "Commit failed — git's output is in the progress window."
            return
        }
        if let messageFile {
            try? FileManager.default.removeItem(at: messageFile)
            self.messageFile = nil
        }
        restoreFiles(Array(restorePaths.keys))

        switch action {
        case .commitAndPush:
            pushAfterCommit(repo)
        case .commit:
            // TortoiseGit offers to push right after a commit; open the Push dialog when there is a remote.
            if ConfigManager.shared.showPushAfterCommit, let remotes = try? repo.remotes(), !remotes.isEmpty {
                CommandRouter.shared.execute(command: .push, targetPath: repositoryPath.rawPath)
            }
        case .reCommit:
            break
        }

        if action == .reCommit {
            resetForNextCommit()
        } else {
            close()
        }
    }

    /// CM-15 Commit & Push: push to the configured upstream right away; without one the Push dialog
    /// asks where to.
    private func pushAfterCommit(_ repo: GitRepository) {
        let root = repositoryPath
        Task { @MainActor in
            guard await repo.headUpstream() != nil,
                  let branch = try? await GitCLIRunner.runAsync(arguments: ["symbolic-ref", "--short", "HEAD"], workingDirectory: root)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let remote = await repo.configValue("branch.\(branch).remote"),
                  let merge = await repo.configValue("branch.\(branch).merge") else {
                CommandRouter.shared.execute(command: .push, targetPath: root.rawPath)
                return
            }
            ProgressWindowController.run(
                title: "Push",
                commands: [["push", "--progress", remote, "HEAD:\(merge)"]],
                workingDirectory: root,
                postActions: { outcome in
                    outcome.succeeded ? [] : [.init("Push…") { CommandRouter.shared.execute(command: .push, targetPath: root.rawPath) }]
                })
        }
    }

    /// ReCommit keeps the dialog open for the next commit with a fresh message and options.
    private func resetForNextCommit() {
        amendCheckbox.state = .off
        amendDiffCheckbox.state = .off
        amendDiffCheckbox.isEnabled = false
        messageOnlyCheckbox.state = .off
        statusListView.alphaValue = 1
        newBranchCheckbox.state = .off
        newBranchField.stringValue = ""
        newBranchField.isEnabled = false
        setDateCheckbox.state = .off
        datePicker.isEnabled = false
        resetDateCheckbox.state = .off
        resetDateCheckbox.isEnabled = false
        bugIDField.stringValue = ""
        amendMessage = nil
        isMergeInProgress = repository?.isMergeInProgress ?? false
        mergeBanner.isHidden = !isMergeInProgress
        setMessage(template ?? "")
        knownPaths = []
        reloadStatus()
        window?.makeFirstResponder(messageTextView)
    }
}
