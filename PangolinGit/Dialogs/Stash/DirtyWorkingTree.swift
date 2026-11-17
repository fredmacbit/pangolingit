import Cocoa
import PangolinGitCore

/// The "working tree is dirty, stash first?" offer TortoiseGit makes before switching, rebasing,
/// bisecting, merging or pulling (`CAppUtils::IsWorkingTreeDirty` + `CAppUtils::StashSave`).
@MainActor
enum DirtyWorkingTree {

    /// Whether tracked files have staged or unstaged changes (untracked files do not block git).
    static func hasChanges(_ root: PangolinPath) async -> Bool {
        let output = (try? await GitCLIRunner.runAsync(arguments: ["status", "--porcelain", "--untracked-files=no"],
                                                       workingDirectory: root)) ?? ""
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum Decision {
        /// Clean, or the user chose to go on with the changes in place.
        case proceed
        /// The changes were stashed; offer *Stash Pop* afterwards.
        case stashed
        case cancel
    }

    /// Asks what to do with local changes before `operation` (e.g. "rebase"). `allowContinue` adds
    /// a *Continue* button for operations git can run on a dirty tree (switch carries changes over).
    static func prepare(_ root: PangolinPath, operation: String, allowContinue: Bool, window: NSWindow?) async -> Decision {
        guard await hasChanges(root) else { return .proceed }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The working tree has uncommitted changes"
        alert.informativeText = allowContinue
            ? "Stash them before the \(operation) and restore them later with Stash Pop, or continue and let git carry them over (it stops if they conflict)."
            : "The \(operation) needs a clean working tree. Stash the changes now and restore them later with Stash Pop."
        alert.addButton(withTitle: "Stash Changes")
        if allowContinue { alert.addButton(withTitle: "Continue") }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return await stash(root, reason: operation, window: window) ? .stashed : .cancel
        case .alertSecondButtonReturn where allowContinue:
            return .proceed
        default:
            return .cancel
        }
    }

    /// `git stash push` with a message naming the operation; reports failure in an alert.
    static func stash(_ root: PangolinPath, reason: String, window: NSWindow?) async -> Bool {
        do {
            try await GitCLIRunner.runAsync(arguments: ["stash", "push", "-m", "PangolinGit: before \(reason)"], workingDirectory: root)
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Stashing failed"
            alert.runModal()
            return false
        }
    }

    /// Post-action restoring the stash made by `prepare` (TortoiseGit's *Stash Pop* button after an operation).
    static func stashPopAction(_ root: PangolinPath) -> ProgressWindowController.PostAction {
        ProgressWindowController.PostAction("Stash Pop") {
            ProgressWindowController.run(title: "Stash Pop", commands: [["stash", "pop"]], workingDirectory: root, postActions: { outcome in
                outcome.succeeded ? [StashActions.showChangesAction(root)] : []
            })
        }
    }
}

/// Stash commands shared by the Finder entries (*Stash Pop*, *Stash Apply*), the stash list and RefLog.
@MainActor
enum StashActions {
    /// Applies or pops `stash` (default the newest) in the progress window, then offers to show the changes
    /// ("Do you want to see the changes?" in TortoiseGit).
    static func apply(_ root: PangolinPath, stash: String = "stash@{0}", pop: Bool) {
        ProgressWindowController.run(title: pop ? "Stash Pop" : "Stash Apply",
                                     commands: [["stash", pop ? "pop" : "apply", stash]],
                                     workingDirectory: root, postActions: { outcome in
            outcome.succeeded ? [showChangesAction(root)] : [resolveAction(root)]
        })
    }

    static func showChangesAction(_ root: PangolinPath) -> ProgressWindowController.PostAction {
        ProgressWindowController.PostAction("Show Changes") {
            CommandRouter.shared.execute(command: .changed, targetPath: root.rawPath)
        }
    }

    /// After a conflicting apply the changes window lists the conflicted files.
    static func resolveAction(_ root: PangolinPath) -> ProgressWindowController.PostAction {
        ProgressWindowController.PostAction("Resolve Conflicts…") {
            CommandRouter.shared.execute(command: .changed, targetPath: root.rawPath)
        }
    }

    /// Whether `refs/stash` exists.
    static func hasStashes(_ root: PangolinPath) async -> Bool {
        let result = try? await GitCLIRunner().run(arguments: ["rev-parse", "--verify", "--quiet", "refs/stash"], workingDirectory: root)
        return result?.isSuccess ?? false
    }
}
