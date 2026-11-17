import Foundation
import Cocoa
import PangolinGitCore

/// Dialog for renaming or moving versioned files/directories via `git mv` (`RenameDlg.cpp` in TortoiseGit).
/// One item gets a new name or path (with a save panel behind `…`); several items are moved into a
/// destination folder. The destination is validated (inside this working tree, a usable name) and
/// the sources must be tracked; submodules are moved by `git mv` itself.
public final class RenameWindowController: NSWindowController {

    public let repositoryPath: PangolinPath
    public let sourceRelativePaths: [String]
    public var sourceRelativePath: String { sourceRelativePaths.first ?? "" }
    private var isMove: Bool { sourceRelativePaths.count > 1 }

    private var destinationField: NSTextField!
    private var forceCheckbox: NSButton!
    private var dryRunCheckbox: NSButton!
    private var statusLabel: NSTextField!
    private var renameButton: NSButton!

    public convenience init(repositoryPath: PangolinPath, sourceRelativePath: String) {
        self.init(repositoryPath: repositoryPath, sourceRelativePaths: [sourceRelativePath])
    }

    public init(repositoryPath: PangolinPath, sourceRelativePaths: [String]) {
        self.repositoryPath = repositoryPath
        self.sourceRelativePaths = sourceRelativePaths

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = sourceRelativePaths.count > 1
            ? "Move \(sourceRelativePaths.count) Items"
            : "Rename / Move — \(URL(fileURLWithPath: sourceRelativePaths.first ?? "").lastPathComponent)"

        super.init(window: window)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let sourceLabel = NSTextField(labelWithString: isMove ? "Items:" : "Source:")
        let sourceField = NSTextField(wrappingLabelWithString: sourceRelativePaths.prefix(5).joined(separator: "\n")
            + (sourceRelativePaths.count > 5 ? "\n… (\(sourceRelativePaths.count) in total)" : ""))
        sourceField.isSelectable = true
        sourceField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        let destLabel = NSTextField(labelWithString: isMove ? "Destination folder (relative to the repository root):"
                                                            : "New name or path (relative to the repository root):")
        destinationField = NSTextField()
        destinationField.stringValue = isMove ? StatusListActions.parentFolder(sourceRelativePath) : sourceRelativePath
        destinationField.placeholderString = isMove ? "folder/subfolder" : "folder/new-name.ext"
        let browseButton = NSButton(title: "…", target: self, action: #selector(browseClicked))
        browseButton.bezelStyle = .rounded
        let destRow = NSStackView(views: [destinationField, browseButton])
        destinationField.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true

        forceCheckbox = NSButton(checkboxWithTitle: "Force rename even if target exists (--force)", target: nil, action: nil)
        dryRunCheckbox = NSButton(checkboxWithTitle: "Dry run (simulate rename without modifying worktree)", target: nil, action: nil)

        let stack = NSStackView(views: [sourceLabel, sourceField, destLabel, destRow, forceCheckbox, dryRunCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: sourceField)
        stack.setCustomSpacing(12, after: destRow)
        stack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        renameButton = NSButton(title: isMove ? "Move" : "Rename", target: self, action: #selector(renameClicked))
        renameButton.bezelStyle = .rounded
        renameButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [statusLabel, cancelButton, renameButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        [stack, buttons].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -14)
        ])
    }

    /// Chooses the destination with a save panel (one item) or a folder panel (several).
    @objc private func browseClicked() {
        guard let window else { return }
        let current = Self.resolve(destinationField.stringValue, root: repositoryPath) ?? (isMove ? "" : sourceRelativePath)
        let startFolder = repositoryPath.appending(isMove ? current : StatusListActions.parentFolder(current)).url
        let handler: (URL?) -> Void = { [weak self] url in
            guard let self, let url else { return }
            guard let relative = PangolinPath(url: url).relative(to: self.repositoryPath) else {
                self.statusLabel.stringValue = "The destination must be inside this working tree."
                return
            }
            self.destinationField.stringValue = relative
        }
        if isMove {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = startFolder
            panel.prompt = "Choose"
            panel.beginSheetModal(for: window) { response in handler(response == .OK ? panel.url : nil) }
        } else {
            let panel = NSSavePanel()
            panel.directoryURL = startFolder
            panel.nameFieldStringValue = (current as NSString).lastPathComponent
            panel.canCreateDirectories = true
            panel.prompt = "Rename"
            panel.beginSheetModal(for: window) { response in handler(response == .OK ? panel.url : nil) }
        }
    }

    /// Repository-relative form of a destination typed relative to the root (or absolute inside it);
    /// nil when it leaves the working tree or names nothing.
    static func resolve(_ input: String, root: PangolinPath) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let absolute = trimmed.hasPrefix("/") ? trimmed : root.appending(trimmed).rawPath
        let standardized = (absolute as NSString).standardizingPath
        let rootPath = (root.rawPath as NSString).standardizingPath
        if standardized == rootPath { return "" }
        guard standardized.hasPrefix(rootPath + "/") else { return nil }
        return String(standardized.dropFirst(rootPath.count + 1))
    }

    /// A reason why `relative` cannot be a destination name, or nil if it is fine.
    static func validationError(forDestination relative: String) -> String? {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.contains(".git") { return "The destination cannot be inside the .git folder." }
        if components.contains(where: { $0.isEmpty }) { return "The destination contains an empty name." }
        if components.contains(where: { $0.contains(":") }) { return "Names cannot contain a colon (Finder shows it as “/”)." }
        return nil
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func renameClicked() {
        guard let destination = Self.resolve(destinationField.stringValue, root: repositoryPath) else {
            statusLabel.stringValue = "Enter a destination inside this working tree."
            return
        }
        if !isMove {
            guard !destination.isEmpty, destination != sourceRelativePath else {
                statusLabel.stringValue = "The new name is identical to the source."
                return
            }
        }
        if !destination.isEmpty, let problem = Self.validationError(forDestination: destination) {
            statusLabel.stringValue = problem
            return
        }

        // Only tracked items can be moved with git mv (TortoiseGit refuses unversioned sources too).
        let untracked = sourceRelativePaths.filter {
            (try? GitCLIRunner.run(arguments: ["ls-files", "--error-unmatch", "--", $0], workingDirectory: repositoryPath)) == nil
        }
        guard untracked.isEmpty else {
            statusLabel.stringValue = "Not under version control: \(untracked.prefix(3).joined(separator: ", "))"
            return
        }

        let force = forceCheckbox.state == .on
        let dryRun = dryRunCheckbox.state == .on
        if force && !dryRun {
            let confirm = NSAlert()
            confirm.messageText = "Force Rename?"
            confirm.informativeText = "If '\(destination)' already exists it will be overwritten (git mv -f)."
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: isMove ? "Move" : "Rename")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        if isMove, !destination.isEmpty {
            // git mv needs the destination folder to exist.
            try? FileManager.default.createDirectory(at: repositoryPath.appending(destination).url, withIntermediateDirectories: true)
        }
        var args = ["mv", "-v"]
        if force { args.append("-f") }
        if dryRun { args.append("-n") }
        args.append("--")
        args.append(contentsOf: sourceRelativePaths)
        args.append(destination.isEmpty ? "." : destination)

        if dryRun {
            statusLabel.stringValue = "Simulating…"
            Task { @MainActor in
                do {
                    let output = try await GitCLIRunner.runAsync(arguments: args, workingDirectory: repositoryPath)
                    self.statusLabel.stringValue = "Dry run OK: " + (output.isEmpty ? "nothing to do" : output.replacingOccurrences(of: "\n", with: "; "))
                } catch {
                    self.statusLabel.stringValue = "Error: \(error.localizedDescription)"
                }
            }
            return
        }
        let root = repositoryPath
        window?.close()
        ProgressWindowController.run(title: isMove ? "Move" : "Rename", commands: [args], workingDirectory: root,
                                     postActions: { $0.succeeded ? [WorkingTreeOperations.commitAction(root)] : [] })
    }
}
