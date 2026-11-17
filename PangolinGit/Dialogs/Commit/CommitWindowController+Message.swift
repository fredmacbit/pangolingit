import Cocoa
import PangolinGitCore

/// Message helpers of the commit dialog: recent messages (CM-06), sign-off (CM-03), the message
/// box context menu with the Log pickers (CM-07), word completion (CM-08) and Restore after commit (ST-14).
extension CommitWindowController: NSMenuDelegate {

    /// Replaces the message, keeping undo and the markup styling.
    func setMessage(_ text: String) {
        let full = NSRange(location: 0, length: (messageTextView.string as NSString).length)
        if messageTextView.shouldChangeText(in: full, replacementString: text) {
            messageTextView.replaceCharacters(in: full, with: text)
            messageTextView.didChangeText()
        }
        messageTextView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Inserts at the cursor (replacing the selection), as TortoiseGit's paste entries do.
    func insertIntoMessage(_ text: String) {
        window?.makeFirstResponder(messageTextView)
        messageTextView.insertText(text, replacementRange: messageTextView.selectedRange())
    }

    // MARK: - Recent messages (CM-06)

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === historyButton.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }

        menu.addItem(ClosureMenuItem(title: "Paste Last Commit Message") { [weak self] in self?.pasteLastCommitMessage() })
        let messages = ConfigManager.shared.recentCommitMessages(forRepository: repositoryPath.rawPath)
        menu.addItem(.separator())
        if messages.isEmpty {
            let empty = NSMenuItem(title: "No recent messages", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for message in messages {
            let title = Self.menuTitle(for: message)
            let insert = ClosureMenuItem(title: title) { [weak self] in self?.insertIntoMessage(message) }
            insert.toolTip = message
            menu.addItem(insert)
            // Holding ⌥ turns the entry into "Delete" (TortoiseGit deletes with the Delete key in its list).
            let delete = ClosureMenuItem(title: "Delete “\(title)”") { [weak self] in self?.deleteRecentMessage(message) }
            delete.isAlternate = true
            delete.keyEquivalentModifierMask = .option
            menu.addItem(delete)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Clear Recent Messages") { [weak self] in
            guard let self else { return }
            ConfigManager.shared.setRecentCommitMessages([], forRepository: self.repositoryPath.rawPath)
        })
    }

    /// First line, shortened for the menu.
    static func menuTitle(for message: String) -> String {
        let firstLine = message.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? message
        return firstLine.count > 70 ? String(firstLine.prefix(69)) + "…" : firstLine
    }

    private func deleteRecentMessage(_ message: String) {
        let root = repositoryPath.rawPath
        let remaining = ConfigManager.shared.recentCommitMessages(forRepository: root).filter { $0 != message }
        ConfigManager.shared.setRecentCommitMessages(remaining, forRepository: root)
    }

    private func pasteLastCommitMessage() {
        guard let repo = repository, repo.hasHead else { return }
        Task { @MainActor in
            if let message = try? await repo.commitMessage() {
                insertIntoMessage(message)
            }
        }
    }

    // MARK: - Sign-off (CM-03)

    @objc func onSignOffClicked() {
        Task { @MainActor in
            _ = await addSignOff()
        }
    }

    /// Appends the committer's Signed-off-by line; false when git knows no identity.
    func addSignOff() async -> Bool {
        guard let line = await signOffLine() else {
            statusLabel.stringValue = "Set user.name and user.email to sign off."
            return false
        }
        let updated = CommitMessage.appendingSignOff(messageTextView.string, line: line)
        if updated != messageTextView.string {
            let selection = messageTextView.selectedRange()
            setMessage(updated)
            messageTextView.setSelectedRange(selection)
        }
        return true
    }

    func signOffLine() async -> String? {
        guard let repo = repository, let identity = await repo.committerIdentity() else { return nil }
        return CommitMessage.signOffLine(name: identity.name, email: identity.email)
    }

    // MARK: - Message box context menu (CM-07)

    func messageMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items.append(ClosureMenuItem(title: "Paste Filename List", symbol: "list.bullet") { [weak self] in
            guard let self else { return }
            let paths = self.statusListView.checkedPaths
            guard !paths.isEmpty else { return }
            self.insertIntoMessage(paths.joined(separator: "\n") + "\n")
        })
        items.append(ClosureMenuItem(title: "Paste Last Commit Message", symbol: "doc.on.clipboard") { [weak self] in
            self?.pasteLastCommitMessage()
        })
        items.append(ClosureMenuItem(title: "Pick Commit Hash…", symbol: "number") { [weak self] in
            self?.pickCommit { hash, _ in self?.insertIntoMessage(String(hash.prefix(12))) }
        })
        items.append(ClosureMenuItem(title: "Pick Commit Message…", symbol: "text.quote") { [weak self] in
            self?.pickCommit { hash, repo in
                Task { @MainActor in
                    if let message = try? await repo.commitMessage(of: hash) {
                        self?.insertIntoMessage(message)
                    }
                }
            }
        })
        return items
    }

    /// Opens the Log as a picker (TortoiseGit's `IDS_COMMITDLG_POPUP_PASTECOMMITHASH`/`…MESSAGE`).
    private func pickCommit(_ completion: @escaping (String, GitRepository) -> Void) {
        guard let repo = repository else { return }
        WindowRegistry.shared.present({
            LogWindowController(repositoryPath: repositoryPath) { hash in completion(hash, repo) }
        }, repository: repositoryPath)
    }

    // MARK: - Word completion (CM-08)

    /// File names of the listed changes plus identifiers declared in them (read off the main thread;
    /// big or binary files are skipped, as TortoiseGit limits its parsing).
    func updateCompletionWords(_ items: [GitItemStatusInfo]) {
        let root = repositoryPath
        let files = items.filter { !$0.isDirectory && !$0.isSubmodule && $0.status != .deleted && $0.status != .missing }
            .prefix(200).map(\.path)
        Task.detached(priority: .utility) {
            var words = Set<String>()
            for path in files {
                let name = (path as NSString).lastPathComponent
                words.insert(name)
                words.insert((name as NSString).deletingPathExtension)
                let ext = (path as NSString).pathExtension
                let url = root.appending(path).url
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      (attributes[.size] as? Int ?? 0) < 300_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                words.formUnion(CommitAutoCompletion.identifiers(in: text, fileExtension: ext))
            }
            let found = words.filter { $0.count >= 3 }
            await MainActor.run { [weak self] in self?.messageTextView.completionWords = found }
        }
    }

    /// `~/Library/Application Support/PangolinGit/snippet.txt` (TortoiseGit reads `snippet.txt` from its app data folder).
    static func loadSnippets() -> [String: String] {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [:] }
        let url = support.appendingPathComponent("PangolinGit/snippet.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return CommitAutoCompletion.parseSnippets(text)
    }

    // MARK: - Restore after commit (ST-14)

    /// Keeps a copy of each file; after the commit the copy is put back, so a trimmed version
    /// (e.g. without debug code) is committed while the full one stays in the working tree.
    func markForRestore(_ paths: [String]) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PangolinGit-Restore", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, path) in paths.enumerated() where restorePaths[path] == nil {
                let copy = folder.appendingPathComponent("\(index)-\((path as NSString).lastPathComponent)")
                try FileManager.default.copyItem(at: repositoryPath.appending(path).url, to: copy)
                restorePaths[path] = copy
            }
            statusLabel.stringValue = "\(restorePaths.count) file(s) will be restored after the commit. Edit them now, then commit."
        } catch {
            statusLabel.stringValue = "Could not keep a copy: \(error.localizedDescription)"
        }
    }

    /// Puts the kept copies back (and touches them so the status cache notices).
    func restoreFiles(_ paths: [String]) {
        var failed: [String] = []
        for path in paths {
            guard let copy = restorePaths[path] else { continue }
            let target = repositoryPath.appending(path).url
            do {
                let data = try Data(contentsOf: copy)
                try data.write(to: target)
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                try? FileManager.default.removeItem(at: copy)
                restorePaths[path] = nil
            } catch {
                failed.append(path)
            }
        }
        if !failed.isEmpty {
            statusLabel.stringValue = "Could not restore: \(failed.joined(separator: ", "))"
        }
        RepositoryEvents.post(repositoryPath)
    }
}
