import Cocoa
import PangolinGitCore

/// Recent repositories as menus: the Dock menu and File ▸ Open Recent (PR-09). TortoiseGit has no
/// main window; on macOS these give the same quick access its Explorer menus give for a working tree.
@MainActor
final class RecentRepositoriesMenu: NSObject, NSMenuDelegate {
    static let shared = RecentRepositoriesMenu()

    /// Repositories that still exist, most recent first.
    private var repositories: [String] {
        ConfigManager.shared.recentRepositories.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Dock menu: one submenu per repository with the everyday commands.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        for path in repositories.prefix(10) {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent, action: nil, keyEquivalent: "")
            item.toolTip = path
            item.submenu = commandMenu(for: path)
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(title: "Clone Repository…") {
            CommandRouter.shared.execute(command: .clone, paths: [])
        })
        return menu
    }

    /// Commands offered for a recent repository.
    func commandMenu(for path: String) -> NSMenu {
        let menu = NSMenu()
        let commands: [(String, PangolinCommand)] = [("Show Log", .log), ("Check for Modifications", .changed),
                                                     ("Commit…", .commit), ("Pull…", .pull), ("Push…", .push), ("Sync…", .sync)]
        for (title, command) in commands {
            menu.addItem(ClosureMenuItem(title: title) { CommandRouter.shared.execute(command: command, targetPath: path) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        })
        return menu
    }

    /// File ▸ Open Recent: rebuilt each time it opens; choosing a repository shows its log, like the launcher.
    func openRecentMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Open Recent")
        submenu.delegate = self
        item.submenu = submenu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for path in repositories.prefix(15) {
            let item = ClosureMenuItem(title: (path as NSString).abbreviatingWithTildeInPath) {
                CommandRouter.shared.execute(command: .log, targetPath: path)
            }
            item.image = NSWorkspace.shared.icon(forFile: path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No Recent Repositories", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Clear Menu") { ConfigManager.shared.clearRecentRepositories() })
        }
    }
}
