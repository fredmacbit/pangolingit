import Foundation
import Cocoa
import PangolinGitCore

/// Window for managing remotes (`pangolingit://remotes`, the *Manage* buttons of Pull/Push/Sync).
/// TortoiseGit shows this as Settings ▸ Git ▸ Remote; the editor itself is shared with the
/// Settings pane (`RemotesEditorViewController`).
public final class RemotesWindowController: NSWindowController {

    public let repositoryPath: PangolinPath
    private let editor: RemotesEditorViewController

    public init(repositoryPath: PangolinPath) {
        self.repositoryPath = repositoryPath
        self.editor = RemotesEditorViewController(repositoryPath: repositoryPath)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Manage Remotes — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 680, height: 380)
        super.init(window: window)
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 760, height: 420))
        window.center()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
