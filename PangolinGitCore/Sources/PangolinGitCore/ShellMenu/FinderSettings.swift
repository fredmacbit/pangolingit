import Foundation

/// Finder-extension preferences, relayed by the agent as JSON because the sandboxed extension cannot
/// read the app's defaults (TortoiseGit's shell extension reads the same values via `ShellCache`).
public struct FinderSettings: Codable, Equatable, Sendable {
    /// Placement per command; commands not listed use `ShellMenuCatalog.defaultTopLevel` / `.submenu`.
    public var placements: [String: ContextMenuPlacement]
    /// Commands only shown with Shift held (Settings ▸ Context Menu "Shift" column).
    public var extendedCommands: Set<String>
    /// No menu for items outside any repository unless Shift is held (`HideMenusForUnversionedItems`).
    public var hideMenusOutsideRepositories: Bool
    /// Paths that never get a menu; a trailing `*` matches every path that starts with the rest
    /// (`ShellCache::IsContextPathAllowed`).
    public var menuExcludedPaths: [String]
    /// Folders Finder offers badges and menus in (`FIFinderSyncController.directoryURLs`).
    public var watchedRoots: [String]
    /// Show SF Symbol icons next to menu entries (`ShowContextMenuIcons`).
    public var showMenuIcons: Bool

    public init(
        placements: [String: ContextMenuPlacement] = [:],
        extendedCommands: Set<String> = ShellMenuCatalog.defaultExtended,
        hideMenusOutsideRepositories: Bool = false,
        menuExcludedPaths: [String] = [],
        watchedRoots: [String] = [],
        showMenuIcons: Bool = true
    ) {
        self.placements = placements
        self.extendedCommands = extendedCommands
        self.hideMenusOutsideRepositories = hideMenusOutsideRepositories
        self.menuExcludedPaths = menuExcludedPaths
        self.watchedRoots = watchedRoots
        self.showMenuIcons = showMenuIcons
    }

    public func placement(for command: String) -> ContextMenuPlacement {
        placements[command] ?? Self.defaultPlacement(for: command)
    }

    public static func defaultPlacement(for command: String) -> ContextMenuPlacement {
        ShellMenuCatalog.defaultTopLevel.contains(command) ? .topLevel : .submenu
    }

    public func isExtended(_ command: String) -> Bool {
        extendedCommands.contains(command)
    }

    /// Whether `path` may get a context menu at all (exclusion list only; repository checks need the state).
    public func isMenuAllowed(for path: String) -> Bool {
        let candidate = path.lowercased()
        for raw in menuExcludedPaths {
            let pattern = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !pattern.isEmpty else { continue }
            if pattern.hasSuffix("*") {
                if candidate.hasPrefix(String(pattern.dropLast())) { return false }
            } else if candidate == pattern || candidate == pattern + "/" || candidate + "/" == pattern {
                return false
            }
        }
        return true
    }

    /// The whole decision for one selection: nil when no menu should be shown.
    public func layout(paths: [String], state: ShellItemState, isAdminDirectory: Bool) -> ShellMenuLayout? {
        guard !isAdminDirectory, let first = paths.first, isMenuAllowed(for: first) else { return nil }
        if hideMenusOutsideRepositories && !state.contains(.extended) && state.isDisjoint(with: .gitRelated) {
            return nil
        }
        let layout = ShellMenuCatalog.layout(for: state, settings: self)
        return layout.isEmpty ? nil : layout
    }

    /// The menu for a folder when it is unknown whether it lies in a repository (the status agent did
    /// not answer): the entries for a plain folder (Clone, Create Repository) together with those for
    /// a versioned folder, so neither set goes missing. The app rejects whatever does not apply.
    public func layoutForUnknownRepository(paths: [String], state: ShellItemState) -> ShellMenuLayout? {
        let plain = layout(paths: paths, state: state, isAdminDirectory: false)
        let versioned = layout(paths: paths, state: state.union([.inGit, .inVersionedFolder, .folderInGit]), isAdminDirectory: false)
        guard var merged = versioned ?? plain else { return nil }
        guard let plain, versioned != nil else { return merged }
        let order = ShellMenuCatalog.entries
        let topLevel = Set(merged.topLevel + plain.topLevel)
        merged.topLevel = order.filter { topLevel.contains($0) }
        let present = Set(merged.submenu.compactMap { $0 })
        let extra = plain.submenu.compactMap { $0 }.filter { !present.contains($0) }
        if !extra.isEmpty {
            if !merged.submenu.isEmpty { merged.submenu.append(nil) }
            merged.submenu.append(contentsOf: extra)
        }
        return merged
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> FinderSettings? {
        try? JSONDecoder().decode(FinderSettings.self, from: data)
    }
}

/// How the agent computes badges (TortoiseGit Settings ▸ Icon Overlays "Status cache").
public enum OverlayCacheMode: String, CaseIterable, Sendable {
    /// Whole-tree `git status` including untracked files (TortoiseGit "Default").
    case full
    /// Tracked files only (`git status -uno`): much faster on huge trees, no unversioned badges.
    case trackedOnly
    /// No badges at all (TortoiseGit "None"); menus still work.
    case off

    public var title: String {
        switch self {
        case .full: return "Full (tracked and untracked files)"
        case .trackedOnly: return "Tracked files only (faster on large trees)"
        case .off: return "None (no badges)"
        }
    }
}
