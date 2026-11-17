import Foundation
import Cocoa
import PangolinGitCore

/// Dialog for deleting / removing versioned files or directories via `git rm` (`DeleteCommand.cpp` in TortoiseGit).
/// Warns about uncommitted and unversioned content first and, with *Use the Trash* on, moves the
/// files to the Trash instead of letting git delete them.
public final class RemoveWindowController: NSWindowController {
    
    public let repositoryPath: PangolinPath
    public let targetPaths: [String]
    
    private var fileListView: NSTableView!
    private var cachedCheckbox: NSButton!
    private var forceCheckbox: NSButton!
    private var recursiveCheckbox: NSButton!
    private var statusLabel: NSTextField!
    private var removeButton: NSButton!
    
    public init(repositoryPath: PangolinPath, targetPaths: [String]) {
        self.repositoryPath = repositoryPath
        self.targetPaths = targetPaths
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = targetPaths.count == 1
            ? "Remove — \(URL(fileURLWithPath: targetPaths.first ?? "").lastPathComponent)"
            : "Remove \(targetPaths.count) Items"
        
        super.init(window: window)
        setupUI()
        runPreflight()
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = self.window else { return }
        
        let container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        
        let instructionLabel = NSTextField(labelWithString: "The following items will be removed from Git version control:")
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(instructionLabel)
        
        // Scrollable list of files to remove
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        let textView = NSTextView()
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = targetPaths.joined(separator: "\n")
        scrollView.documentView = textView
        container.addSubview(scrollView)
        
        // Checkboxes
        cachedCheckbox = NSButton(checkboxWithTitle: "Keep local file in working tree (--cached)", target: nil, action: nil)
        cachedCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cachedCheckbox)
        
        forceCheckbox = NSButton(checkboxWithTitle: "Force removal of modified/staged files (-f)", target: nil, action: nil)
        forceCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(forceCheckbox)
        
        recursiveCheckbox = NSButton(checkboxWithTitle: "Remove directories recursively (-r)", target: nil, action: nil)
        recursiveCheckbox.state = .on
        recursiveCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(recursiveCheckbox)
        
        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cancelButton)
        
        removeButton = NSButton(title: "Remove", target: self, action: #selector(removeClicked))
        removeButton.bezelStyle = .rounded
        removeButton.keyEquivalent = "\r"
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(removeButton)
        
        NSLayoutConstraint.activate([
            instructionLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            instructionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            instructionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            scrollView.topAnchor.constraint(equalTo: instructionLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(equalToConstant: 110),
            
            cachedCheckbox.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            cachedCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            cachedCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            forceCheckbox.topAnchor.constraint(equalTo: cachedCheckbox.bottomAnchor, constant: 6),
            forceCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            forceCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            recursiveCheckbox.topAnchor.constraint(equalTo: forceCheckbox.bottomAnchor, constant: 6),
            recursiveCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            recursiveCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -12),
            
            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -8),
            cancelButton.widthAnchor.constraint(equalToConstant: 90),
            
            removeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            removeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            removeButton.widthAnchor.constraint(equalToConstant: 90)
        ])
    }
    
    @objc private func cancelClicked() {
        window?.close()
    }
    
    /// What deleting the selection would destroy beyond committed content: tracked files with
    /// uncommitted changes and unversioned files inside the selected folders (TortoiseGit warns
    /// about both before `git rm -r -f`).
    private struct Preflight {
        var modified: [String] = []
        var unversioned: [String] = []
        var isEmpty: Bool { modified.isEmpty && unversioned.isEmpty }
    }

    private func runPreflight() {
        guard let repo = GitRepository.open(at: repositoryPath) else { return }
        let paths = targetPaths
        Task { @MainActor in
            let items = (try? await repo.getStatus(pathspec: paths)) ?? []
            var result = Preflight()
            result.modified = items.filter { ![.untracked, .ignored, .clean, .missing, .deleted].contains($0.status) }.map(\.path)
            result.unversioned = items.filter { $0.status == .untracked }.map(\.path)
            self.preflight = result
            var notes: [String] = []
            if !result.modified.isEmpty { notes.append("\(result.modified.count) file(s) have uncommitted changes") }
            if !result.unversioned.isEmpty { notes.append("\(result.unversioned.count) unversioned file(s) inside the selection will be deleted too") }
            self.statusLabel.stringValue = notes.isEmpty ? "Ready" : "⚠️ " + notes.joined(separator: "; ")
            self.statusLabel.textColor = notes.isEmpty ? .secondaryLabelColor : .systemOrange
        }
    }

    private var preflight: Preflight?

    @objc private func removeClicked() {
        let keepLocal = cachedCheckbox.state == .on
        let useTrash = !keepLocal && ConfigManager.shared.useTrashOnRevert
        var force = forceCheckbox.state == .on
        let warnings = preflight ?? Preflight()

        // Confirm whenever files with uncommitted content would be lost from disk.
        if !keepLocal && (!warnings.isEmpty || force) {
            let confirm = NSAlert()
            confirm.alertStyle = useTrash ? .warning : .critical
            confirm.messageText = "Delete files with uncommitted content?"
            var lines: [String] = []
            if !warnings.modified.isEmpty {
                lines.append("Modified:\n" + warnings.modified.prefix(6).map { "• " + $0 }.joined(separator: "\n"))
            }
            if !warnings.unversioned.isEmpty {
                lines.append("Unversioned:\n" + warnings.unversioned.prefix(6).map { "• " + $0 }.joined(separator: "\n"))
            }
            lines.append(useTrash ? "The files are moved to the Trash." : "These changes will be lost permanently.")
            confirm.informativeText = lines.joined(separator: "\n\n")
            confirm.addButton(withTitle: useTrash ? "Move to Trash" : "Delete")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            // The content survives in the Trash, so git need not refuse modified files.
            if useTrash { force = true }
        } else if keepLocal && force {
            let confirm = NSAlert()
            confirm.messageText = "Force Remove?"
            confirm.informativeText = "Forcing removal (-f) discards staged changes for these items from the index."
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Force Remove")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }

        var args = ["rm"]
        // With the Trash, git only drops the index entries; the files are trashed afterwards.
        if keepLocal || useTrash { args.append("--cached") }
        if force { args.append("-f") }
        if recursiveCheckbox.state == .on { args.append("-r") }
        args.append("--")
        args.append(contentsOf: targetPaths)

        let root = repositoryPath
        let paths = targetPaths
        window?.close()
        ProgressWindowController.run(title: "Delete", commands: [args], workingDirectory: root, postActions: { outcome in
            outcome.succeeded ? [WorkingTreeOperations.commitAction(root)] : []
        }, onFinish: { outcome in
            guard outcome.succeeded, useTrash else { return }
            WorkingTreeOperations.reportFailures(WorkingTreeOperations.trash(paths, root: root), action: "Moving to the Trash")
            RepositoryEvents.post(root)
        })
    }
}
