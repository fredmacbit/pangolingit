import Cocoa
import FinderSync
import PangolinGitCore

/// Finder Sync extension providing overlay badges, context menus, and toolbar items in macOS Finder.
/// Equivalent to TortoiseGit's Explorer shell extension DLL (`src/TortoiseShell/`).
///
/// The extension is sandboxed and cannot read working trees itself: all status questions go to the
/// `PangolinGitAgent` launch agent, and all actions are forwarded to the main app via `pangolingit://` URLs.
final class FinderSync: FIFinderSync, PangolinGitStatusCacheClientProtocol {

    /// How long `menu(for:)` waits for the agent to describe the selection before falling back to
    /// what the badge replies already told us.
    private static let menuStateTimeout: TimeInterval = 1.0

    private let stateLock = NSLock()
    private var connection: NSXPCConnection?
    /// Working-tree roots learned from badge and menu replies; the fallback when the agent is slow.
    private var knownRoots = Set<String>()
    /// URLs Finder asked badges for, per repository root, so they can be re-badged after a change.
    private var badgedURLs: [String: Set<URL>] = [:]
    private static let maxTrackedURLsPerRoot = 4_000
    /// Menu layout and folder preferences relayed by the agent; defaults until the first reply.
    private var settings = FinderSettings()
    /// Set once the agent has answered; until then the menu cannot know which folders are repositories.
    private var agentReachable = false

    override init() {
        super.init()
        registerBadgeImages()
        // Finder only shows our menu and asks for badges inside these folders. In the sandbox,
        // FileManager's home directory is the extension's container, so look up the real one.
        FIFinderSyncController.default().directoryURLs = [
            Self.realHomeDirectory,
            URL(fileURLWithPath: "/Volumes")
        ]
        refreshSettings()
    }

    /// The user's actual home folder (not the sandbox container).
    private static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true)
    }

    // MARK: - Agent connection

    private func agent(errorHandler: (@Sendable (Error) -> Void)? = nil) -> PangolinGitStatusCacheProtocol? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if connection == nil {
            let newConnection = NSXPCConnection(machServiceName: StatusCacheInterface.machServiceName, options: [])
            newConnection.remoteObjectInterface = StatusCacheInterface.makeInterface()
            newConnection.exportedInterface = StatusCacheInterface.makeClientInterface()
            newConnection.exportedObject = self
            newConnection.invalidationHandler = { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                self.connection = nil
                self.stateLock.unlock()
            }
            newConnection.resume()
            connection = newConnection
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            PangolinLog.finder.error("Status agent unavailable: \(error.localizedDescription, privacy: .public)")
            errorHandler?(error)
        } as? PangolinGitStatusCacheProtocol
    }

    /// Fetches the preferences again (each time a menu opens, so settings changes apply to the next one)
    /// and follows changes to the watched folders (SH-04).
    private func refreshSettings() {
        agent()?.finderSettings { [weak self] data in
            guard let self, let decoded = FinderSettings.decode(data) else { return }
            self.stateLock.lock()
            let rootsChanged = decoded.watchedRoots != self.settings.watchedRoots
            self.settings = decoded
            self.agentReachable = true
            self.stateLock.unlock()
            if rootsChanged && !decoded.watchedRoots.isEmpty {
                let urls = decoded.watchedRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
                DispatchQueue.main.async {
                    FIFinderSyncController.default().directoryURLs = Set(urls)
                }
            }
        }
    }

    // MARK: - Badges

    private func registerBadgeImages() {
        let badges: [(GitBadgeKind, String, NSColor, String)] = [
            (.normal, "checkmark.circle.fill", .systemGreen, "Unmodified"),
            (.modified, "exclamationmark.circle.fill", .systemRed, "Modified"),
            (.conflicted, "exclamationmark.triangle.fill", .systemOrange, "Conflicted"),
            (.added, "plus.circle.fill", .systemBlue, "Added"),
            (.deleted, "xmark.circle.fill", .systemRed, "Deleted"),
            (.ignored, "minus.circle.fill", .systemGray, "Ignored"),
            (.unversioned, "questionmark.circle.fill", .systemTeal, "Unversioned"),
            (.locked, "lock.circle.fill", .systemBrown, "Skip-worktree"),
            (.needsLock, "pin.circle.fill", .systemPurple, "Assume-unchanged")
        ]
        for (kind, symbol, color, label) in badges {
            FIFinderSyncController.default().setBadgeImage(
                Self.badgeImage(symbol: symbol, color: color),
                label: label,
                forBadgeIdentifier: kind.rawValue
            )
        }
    }

    /// Renders a white-on-colour SF Symbol badge; Finder scales it to the icon size.
    private static func badgeImage(symbol: String, color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
    }

    override func requestBadgeIdentifier(for url: URL) {
        agent()?.queryStatus(forPath: url.path) { [weak self] badge, _, root in
            guard let self else { return }
            self.stateLock.lock()
            self.agentReachable = true
            self.stateLock.unlock()
            // URLs outside any repository are kept under "" so they can be badged once a
            // repository appears there (Create Repository Here, Clone).
            self.stateLock.lock()
            if !root.isEmpty { self.knownRoots.insert(root) }
            var urls = self.badgedURLs[root, default: []]
            if urls.count >= Self.maxTrackedURLsPerRoot { urls.removeAll() }
            urls.insert(url)
            self.badgedURLs[root] = urls
            self.stateLock.unlock()
            let kind = GitBadgeKind(rawValue: badge) ?? .none
            FIFinderSyncController.default().setBadgeIdentifier(kind == .none ? "" : kind.rawValue, for: url)
        }
    }

    func repositoryStatusDidChange(atRoot root: String) {
        // Overlay settings changes arrive this way too (the app invalidates every repository).
        refreshSettings()
        stateLock.lock()
        var urls = badgedURLs[root] ?? []
        if var outside = badgedURLs[""] {
            let adopted = outside.filter { $0.path == root || $0.path.hasPrefix(root + "/") }
            outside.subtract(adopted)
            badgedURLs[""] = outside
            urls.formUnion(adopted)
        }
        stateLock.unlock()
        urls.forEach(requestBadgeIdentifier(for:))
    }

    // MARK: - Toolbar

    override var toolbarItemName: String { "PangolinGit" }
    override var toolbarItemToolTip: String { "PangolinGit source control actions" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "PangolinGit") ?? NSImage()
    }

    // MARK: - Context menu

    /// The items a menu (or a command chosen from it) applies to: the selection, or the folder the
    /// window shows when the click was on its background or the toolbar button.
    private static func menuTargets(for menuKind: FIMenuKind?) -> [URL] {
        let controller = FIFinderSyncController.default()
        var targets = controller.selectedItemURLs() ?? []
        if targets.isEmpty || menuKind == .contextualMenuForContainer || menuKind == .toolbarItemMenu,
           let container = controller.targetedURL() {
            targets = [container]
        }
        return targets
    }

    /// Asks the agent what the selection is (status, folder, repository state). Falls back to the
    /// roots learned from badge replies when the agent does not answer in time.
    /// Set by `selectionState` when the agent did not answer and no known root contains the
    /// selection, so it is unknown whether it is in a repository.
    private var repositoryUnknown = false

    private func selectionState(paths: [String]) -> ShellItemStateEvaluator.Result {
        repositoryUnknown = false
        final class Box: @unchecked Sendable { var result: ShellItemStateEvaluator.Result? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let proxy = agent { _ in semaphore.signal() }
        proxy?.menuState(forPaths: paths) { raw, root, isAdmin in
            box.result = ShellItemStateEvaluator.Result(state: ShellItemState(rawValue: raw), root: root, isAdminDirectory: isAdmin)
            semaphore.signal()
        }
        if proxy != nil, semaphore.wait(timeout: .now() + Self.menuStateTimeout) == .success, let result = box.result {
            stateLock.lock()
            agentReachable = true
            if !result.root.isEmpty { knownRoots.insert(result.root) }
            stateLock.unlock()
            return result
        }
        PangolinLog.finder.notice("No menu state from the agent; using cached repository roots.")
        let fallback = fallbackState(paths: paths)
        repositoryUnknown = fallback.root.isEmpty
        return fallback
    }

    /// Coarse state from what is known without the agent: "versioned" inside a known root, else nothing.
    private func fallbackState(paths: [String]) -> ShellItemStateEvaluator.Result {
        var state: ShellItemState = []
        if paths.count == 1 { state.insert(.onlyOne) }
        if paths.count == 2 { state.insert(.two) }
        if paths.contains(where: { ["patch", "diff"].contains(($0 as NSString).pathExtension.lowercased()) }) {
            state.insert(.patchFile)
        }
        guard let first = paths.first else { return ShellItemStateEvaluator.Result(state: state, root: "") }
        let isDirectory = (try? URL(fileURLWithPath: first).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory { state.insert(.folder) }
        stateLock.lock()
        let root = knownRoots.first { first == $0 || first.hasPrefix($0 + "/") }
        stateLock.unlock()
        if let root {
            state.formUnion([.inGit, .inVersionedFolder])
            if isDirectory { state.insert(.folderInGit) }
            if first == root { state.insert(.wcRoot) }
            return ShellItemStateEvaluator.Result(state: state, root: root)
        }
        // Without an agent reply a plain folder cannot be told from one inside a repository;
        // `menu(for:)` then offers both menus (see `repositoryUnknown`).
        return ShellItemStateEvaluator.Result(state: state, root: "")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let targets = Self.menuTargets(for: menuKind)
        let paths = targets.map(\.path)
        guard !paths.isEmpty else { return nil }
        // Shift + right-click shows the extended entries (TortoiseGit: `CMF_EXTENDEDVERBS`).
        let extended = NSEvent.modifierFlags.contains(.shift)
        PangolinLog.finder.notice("Menu requested (kind \(menuKind.rawValue)) for \(paths.count) item(s), extended: \(extended)")

        var selection = selectionState(paths: paths)
        if extended { selection.state.insert(.extended) }
        stateLock.lock()
        let settings = self.settings
        stateLock.unlock()
        // Pick up settings changes for the next time the menu opens.
        refreshSettings()

        let resolvedLayout = repositoryUnknown
            ? settings.layoutForUnknownRepository(paths: paths, state: selection.state)
            : settings.layout(paths: paths, state: selection.state, isAdminDirectory: selection.isAdminDirectory)
        guard let layout = resolvedLayout else {
            return nil
        }

        func item(_ entry: ShellMenuEntry, topLevel: Bool) -> NSMenuItem {
            // Top-level entries carry a "Git" prefix so they stand out among Finder's own (TortoiseGit does the same).
            let title = topLevel ? "Git \(entry.title)" : entry.title
            let menuItem = NSMenuItem(title: title, action: #selector(performMenuCommand(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = ShellMenuCatalog.entries.firstIndex(of: entry) ?? -1
            if settings.showMenuIcons {
                menuItem.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
            }
            if entry.command == "inaccessible" {
                // A hint, not an action: the folder has a .git entry the agent could not read.
                menuItem.action = nil
                menuItem.toolTip = "The .git folder here cannot be read. Check its permissions."
            }
            return menuItem
        }

        let menu = NSMenu(title: "PangolinGit")
        layout.topLevel.forEach { menu.addItem(item($0, topLevel: true)) }
        if !layout.submenu.isEmpty {
            let submenu = NSMenu(title: "PangolinGit")
            for entry in layout.submenu {
                submenu.addItem(entry.map { item($0, topLevel: false) } ?? .separator())
            }
            let submenuItem = NSMenuItem(title: "PangolinGit", action: nil, keyEquivalent: "")
            if settings.showMenuIcons {
                submenuItem.image = NSImage(named: "MenuIcon")
            }
            submenuItem.submenu = submenu
            menu.addItem(submenuItem)
        }
        return menu
    }

    /// Forwards the command to the main app as `pangolingit://<command>?path=…&path=…`.
    @objc private func performMenuCommand(_ sender: NSMenuItem) {
        guard ShellMenuCatalog.entries.indices.contains(sender.tag) else {
            PangolinLog.finder.error("Menu item without a valid command tag: \(sender.title, privacy: .public)")
            return
        }
        let command = ShellMenuCatalog.entries[sender.tag].command
        // The selection is read again here because Finder's copy of the item carries no payload.
        let targets = Self.menuTargets(for: nil)

        if command == "refresh" {
            // Handled here without launching the app: the agent re-reads the repositories and
            // tells us to re-badge (TortoiseGit's shell "Refresh" / F5).
            for target in targets {
                agent()?.invalidateCache(forPath: target.path) { _ in }
            }
            return
        }

        var components = URLComponents()
        components.scheme = "pangolingit"
        components.host = command
        components.queryItems = targets.map { URLQueryItem(name: "path", value: $0.path) }
        guard let url = components.url else { return }
        PangolinLog.finder.notice("Menu command \(command, privacy: .public) for \(targets.count) item(s)")
        if !NSWorkspace.shared.open(url) {
            PangolinLog.finder.error("Could not open \(url.absoluteString, privacy: .public)")
        }
    }
}
