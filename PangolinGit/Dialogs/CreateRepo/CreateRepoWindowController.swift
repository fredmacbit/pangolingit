import Cocoa
import PangolinGitCore

/// "Create repository here": `git init [--bare]` in the clicked folder.
/// Equivalent to TortoiseGit's `CreateRepoDlg.cpp` and `CreateRepositoryCommand.cpp`.
final class CreateRepoWindowController: NSWindowController {

    private let folder: PangolinPath
    private let bareCheckbox = NSButton(checkboxWithTitle: "Make it bare (no working tree)", target: nil, action: nil)
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(folder: PangolinPath) {
        self.folder = folder
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Create Repository — \(folder.filename)"
        super.init(window: window)
        setupUI()
        // A folder named "*.git" is almost always meant to be a bare repository (TortoiseGit does the same).
        bareCheckbox.state = folder.rawPath.hasSuffix(".git") ? .on : .off
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window else { return }
        let container = NSView()
        window.contentView = container

        let intro = NSTextField(labelWithString: "Create a new Git repository in:")
        let pathField = NSTextField(labelWithString: folder.rawPath)
        pathField.isSelectable = true
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        if let existing = GitAdminDir.findRepository(startingAt: folder) {
            statusLabel.stringValue = existing.workingTreeRoot.rawPath == folder.rawPath
                ? "This folder already is a repository; git init will only reinitialise it."
                : "This folder lies inside the repository “\(existing.workingTreeRoot.rawPath)”. The new repository will be nested in it."
        }

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(createClicked)
        createButton.keyEquivalent = "\r"

        for view in [intro, pathField, bareCheckbox, statusLabel, cancelButton, createButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            intro.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            pathField.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 6),
            pathField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            pathField.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            bareCheckbox.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 16),
            bareCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            statusLabel.topAnchor.constraint(equalTo: bareCheckbox.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            createButton.topAnchor.constraint(greaterThanOrEqualTo: statusLabel.bottomAnchor, constant: 16),
            createButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            createButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            createButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            cancelButton.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -8),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
        ])
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func createClicked() {
        let bare = bareCheckbox.state == .on
        if Self.isSpecialFolder(folder),
           !confirm("“\(folder.rawPath)” is a special folder and is not supposed to be a repository root. Create a repository there anyway?") {
            return
        }
        if bare && !Self.isEmptyDirectory(folder),
           !confirm("The folder “\(folder.rawPath)” is not empty. Initialise a bare repository inside it anyway?") {
            return
        }
        createButton.isEnabled = false
        let arguments = Self.initArguments(folder: folder, bare: bare)
        Task { @MainActor in
            do {
                try await GitCLIRunner.runAsync(arguments: arguments, workingDirectory: nil)
                // `git init` is not a working-tree mutation the runner announces; tell the agent so
                // Finder badges the new repository right away.
                StatusAgentClient.invalidate(folder)
                RepositoryEvents.post(folder)
                window?.close()
                let alert = NSAlert()
                alert.messageText = "Repository created"
                alert.informativeText = "Initialized empty Git repository in \(folder.rawPath)."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            } catch {
                showFailure(error.localizedDescription)
            }
        }
    }

    private func showFailure(_ message: String) {
        createButton.isEnabled = true
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not create the repository"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    private func confirm(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Create repository?"
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Proceed")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// `git init [--bare] -- <folder>`; git creates the folder if it does not exist.
    static func initArguments(folder: PangolinPath, bare: Bool) -> [String] {
        var arguments = ["init"]
        if bare { arguments.append("--bare") }
        arguments += ["--", folder.rawPath]
        return arguments
    }

    /// Volume roots, the home folder and well-known system/user folders (`CheckSpecialFolder`).
    static func isSpecialFolder(_ folder: PangolinPath) -> Bool {
        let path = folder.url.standardizedFileURL.path
        if path == "/" { return true }
        if path.hasPrefix("/Volumes/") && path.split(separator: "/").count == 2 { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let special = [home, "/System", "/Library", "/Applications", "/Users", "/usr", "/private",
                       home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Library"]
        return special.contains(path)
    }

    private static func isEmptyDirectory(_ folder: PangolinPath) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.rawPath)) ?? []
        return contents.allSatisfy { $0 == ".DS_Store" }
    }
}
