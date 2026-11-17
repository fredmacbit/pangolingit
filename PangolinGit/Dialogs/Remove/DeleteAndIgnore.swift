import Cocoa
import PangolinGitCore

/// "Delete and add to ignore list" (TortoiseGit's *Delete and add to ignore list ▸ by name / by
/// extension*, which then asks whether to keep the local file): stops tracking the selection, adds
/// it to an ignore file and optionally moves the files to the Trash.
@MainActor
enum DeleteAndIgnore {

    static func run(paths: [String], root: PangolinPath) {
        let selection = paths.filter { !$0.isEmpty }
        guard !selection.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = selection.count == 1 ? "Delete “\(selection[0])” and ignore it?" : "Delete \(selection.count) items and ignore them?"
        alert.informativeText = "The items are removed from version control and an ignore rule is added so they are not offered for commit again."

        let byName = NSButton(radioButtonWithTitle: "Ignore by name", target: nil, action: nil)
        let byExtension = NSButton(radioButtonWithTitle: "Ignore by extension", target: nil, action: nil)
        byName.state = .on
        // Radio buttons in one superview with the same action form a group.
        let radioAction = #selector(RadioGroupTarget.changed(_:))
        [byName, byExtension].forEach { $0.target = RadioGroupTarget.shared; $0.action = radioAction }
        byExtension.isEnabled = selection.contains { !($0 as NSString).pathExtension.isEmpty }

        let location = NSPopUpButton()
        location.addItems(withTitles: [".gitignore in the repository root", ".gitignore in the containing folder", "Local exclude list (info/exclude)"])
        let recursive = NSButton(checkboxWithTitle: "Match in subfolders too (recursively)", target: nil, action: nil)
        let keepLocal = NSButton(checkboxWithTitle: "Keep the files on disk", target: nil, action: nil)
        keepLocal.state = .on

        let stack = NSStackView(views: [byName, byExtension, location, recursive, keepLocal])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 140)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Delete and Ignore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let ignoreLocation = GitIgnoreFile.Location(rawValue: location.indexOfSelectedItem) ?? .rootGitignore
        let scope: GitIgnoreFile.Scope = recursive.state == .on ? .recursive : .containingFolderOnly
        do {
            try GitIgnoreFile.ignore(selection, byExtension: byExtension.state == .on, scope: scope,
                                     location: ignoreLocation, repositoryRoot: root)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let keep = keepLocal.state == .on
        ProgressWindowController.run(title: "Delete and Ignore", commands: [["rm", "-r", "--cached", "--"] + selection],
                                     workingDirectory: root, postActions: { $0.succeeded ? [WorkingTreeOperations.commitAction(root)] : [] },
                                     onFinish: { outcome in
            guard outcome.succeeded, !keep else { return }
            let useTrash = ConfigManager.shared.useTrashOnRevert
            let failures = useTrash ? WorkingTreeOperations.trash(selection, root: root)
                                    : WorkingTreeOperations.deletePermanently(selection, root: root)
            WorkingTreeOperations.reportFailures(failures, action: "Delete")
        })
    }
}

/// Makes radio buttons in alert accessory views behave as one group.
final class RadioGroupTarget: NSObject {
    static let shared = RadioGroupTarget()

    @objc func changed(_ sender: NSButton) {
        sender.superview?.subviews.compactMap { $0 as? NSButton }
            .filter { $0 !== sender && $0.action == sender.action }
            .forEach { $0.state = .off }
        sender.state = .on
    }
}
