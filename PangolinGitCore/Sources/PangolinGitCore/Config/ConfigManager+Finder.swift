import Foundation

/// Finder integration preferences: context-menu layout (TortoiseGit Settings ▸ Context Menu / Context
/// Menu 2) and icon overlays (Settings ▸ Icon Overlays / Overlay Handlers).
extension ConfigManager {

    public enum FinderKeys {
        public static let contextMenuPlacements = "contextMenuPlacements"
        public static let contextMenuExtended = "contextMenuExtended"
        public static let hideMenusOutsideRepositories = "hideMenusOutsideRepositories"
        public static let contextMenuExcludedPaths = "contextMenuExcludedPaths"
        public static let showContextMenuIcons = "showContextMenuIcons"
        public static let overlayWatchedRoots = "overlayWatchedRoots"
        public static let overlayExcludedPaths = "overlayExcludedPaths"
        public static let overlayCacheMode = "overlayCacheMode"
        public static let overlayDisabledBadges = "overlayDisabledBadges"
        public static let unversionedMarksParentModified = "unversionedMarksParentModified"
        public static let submoduleStatusInParent = "submoduleStatusInParent"
    }

    // MARK: - Context menu

    /// Placement of one command. Falls back to the legacy on/off `contextMenuEntries` (keys there are
    /// camel-cased, e.g. "browseRefs"), then to the catalog default.
    public func contextMenuPlacement(for command: String) -> ContextMenuPlacement {
        let stored = defaults.dictionary(forKey: FinderKeys.contextMenuPlacements) as? [String: String] ?? [:]
        if let raw = stored[command], let placement = ContextMenuPlacement(rawValue: raw) {
            return placement
        }
        if let legacy = defaults.dictionary(forKey: Keys.contextMenuEntries) as? [String: Bool],
           legacy.contains(where: { $0.key.lowercased() == command && !$0.value }) {
            return .hidden
        }
        return FinderSettings.defaultPlacement(for: command)
    }

    public func setContextMenuPlacement(_ placement: ContextMenuPlacement, for command: String) {
        var stored = defaults.dictionary(forKey: FinderKeys.contextMenuPlacements) as? [String: String] ?? [:]
        stored[command] = placement.rawValue
        defaults.set(stored, forKey: FinderKeys.contextMenuPlacements)
        // Keep the legacy visibility map in step for `isContextMenuEnabled(for:)` callers.
        var legacy = defaults.dictionary(forKey: Keys.contextMenuEntries) as? [String: Bool] ?? [:]
        for key in legacy.keys where key.lowercased() == command { legacy.removeValue(forKey: key) }
        legacy[command] = placement != .hidden
        defaults.set(legacy, forKey: Keys.contextMenuEntries)
    }

    /// Commands shown only with Shift held.
    public var contextMenuExtendedCommands: Set<String> {
        get {
            guard let stored = defaults.stringArray(forKey: FinderKeys.contextMenuExtended) else {
                return ShellMenuCatalog.defaultExtended
            }
            return Set(stored)
        }
        set { defaults.set(newValue.sorted(), forKey: FinderKeys.contextMenuExtended) }
    }

    /// Restores TortoiseGit-like defaults ("Restore Default" in Settings ▸ Context Menu).
    public func resetContextMenu() {
        defaults.removeObject(forKey: FinderKeys.contextMenuPlacements)
        defaults.removeObject(forKey: FinderKeys.contextMenuExtended)
        defaults.removeObject(forKey: Keys.contextMenuEntries)
    }

    public var hideMenusOutsideRepositories: Bool {
        get { defaults.bool(forKey: FinderKeys.hideMenusOutsideRepositories) }
        set { defaults.set(newValue, forKey: FinderKeys.hideMenusOutsideRepositories) }
    }

    public var contextMenuExcludedPaths: [String] {
        get { defaults.stringArray(forKey: FinderKeys.contextMenuExcludedPaths) ?? [] }
        set { defaults.set(newValue, forKey: FinderKeys.contextMenuExcludedPaths) }
    }

    public var showContextMenuIcons: Bool {
        get { defaults.object(forKey: FinderKeys.showContextMenuIcons) as? Bool ?? true }
        set { defaults.set(newValue, forKey: FinderKeys.showContextMenuIcons) }
    }

    // MARK: - Overlays

    /// Folders Finder badges and offers menus in; empty means the default (home folder and `/Volumes`).
    public var overlayWatchedRoots: [String] {
        get { defaults.stringArray(forKey: FinderKeys.overlayWatchedRoots) ?? [] }
        set { defaults.set(newValue, forKey: FinderKeys.overlayWatchedRoots) }
    }

    /// Paths that never get badges (same pattern rules as `contextMenuExcludedPaths`).
    public var overlayExcludedPaths: [String] {
        get { defaults.stringArray(forKey: FinderKeys.overlayExcludedPaths) ?? [] }
        set { defaults.set(newValue, forKey: FinderKeys.overlayExcludedPaths) }
    }

    public var overlayCacheMode: OverlayCacheMode {
        get { defaults.string(forKey: FinderKeys.overlayCacheMode).flatMap(OverlayCacheMode.init(rawValue:)) ?? .full }
        set { defaults.set(newValue.rawValue, forKey: FinderKeys.overlayCacheMode) }
    }

    /// Badge kinds switched off in Settings ▸ Overlays (TortoiseGit's Overlay Handlers page).
    /// Unversioned and ignored keep their own long-standing switches.
    public var overlayDisabledBadges: Set<GitBadgeKind> {
        get { Set((defaults.stringArray(forKey: FinderKeys.overlayDisabledBadges) ?? []).compactMap(GitBadgeKind.init(rawValue:))) }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: FinderKeys.overlayDisabledBadges) }
    }

    /// Whether a badge kind is shown at all.
    public func isOverlayEnabled(_ badge: GitBadgeKind) -> Bool {
        switch badge {
        case .unversioned: return showUnversionedOverlay
        case .ignored: return showIgnoredOverlay
        case .none: return true
        default: return !overlayDisabledBadges.contains(badge)
        }
    }

    public func setOverlayEnabled(_ enabled: Bool, for badge: GitBadgeKind) {
        switch badge {
        case .unversioned: showUnversionedOverlay = enabled
        case .ignored: showIgnoredOverlay = enabled
        case .none: break
        default:
            var disabled = overlayDisabledBadges
            if enabled { disabled.remove(badge) } else { disabled.insert(badge) }
            overlayDisabledBadges = disabled
        }
    }

    /// A folder holding only unversioned files shows the modified badge (TortoiseGit "Unversioned files
    /// mark parent folder as modified").
    public var unversionedMarksParentModified: Bool {
        get { defaults.bool(forKey: FinderKeys.unversionedMarksParentModified) }
        set { defaults.set(newValue, forKey: FinderKeys.unversionedMarksParentModified) }
    }

    /// Changes inside a submodule mark the folders above it as modified (TortoiseGit "Show status of
    /// submodules in parent folders"); on by default, as before this setting existed.
    public var submoduleStatusInParent: Bool {
        get { defaults.object(forKey: FinderKeys.submoduleStatusInParent) as? Bool ?? true }
        set { defaults.set(newValue, forKey: FinderKeys.submoduleStatusInParent) }
    }

    /// Everything the Finder extension needs, as relayed by the agent. `defaultRoots` fills in an empty
    /// watched-roots list (the agent knows the real home folder; the sandboxed extension does not).
    public func finderSettings(defaultRoots: [String]) -> FinderSettings {
        var placements: [String: ContextMenuPlacement] = [:]
        for entry in ShellMenuCatalog.configurableEntries {
            placements[entry.command] = contextMenuPlacement(for: entry.command)
        }
        let roots = overlayWatchedRoots.filter { !$0.isEmpty }
        return FinderSettings(
            placements: placements,
            extendedCommands: contextMenuExtendedCommands,
            hideMenusOutsideRepositories: hideMenusOutsideRepositories,
            menuExcludedPaths: contextMenuExcludedPaths,
            watchedRoots: roots.isEmpty ? defaultRoots : roots,
            showMenuIcons: showContextMenuIcons
        )
    }
}
