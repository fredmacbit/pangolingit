import Foundation

/// Where a Finder context-menu command appears (TortoiseGit: the `ContextMenuEntries` top-level mask
/// plus the `ContextMenuEntriesMask` hide mask, Settings ▸ Context Menu).
public enum ContextMenuPlacement: String, Codable, CaseIterable, Sendable {
    case topLevel
    case submenu
    case hidden

    public var title: String {
        switch self {
        case .topLevel: return "Top level"
        case .submenu: return "Submenu"
        case .hidden: return "Hidden"
        }
    }
}

/// One Finder context-menu command: the `pangolingit://<command>` it opens and when it is offered.
public struct ShellMenuEntry: Hashable, Sendable {
    public let command: String
    public let title: String
    public let symbol: String
    /// Shown when any rule matches (`MenuInfo.first…fourth`).
    public let rules: [ShellMenuRule]
    /// Whether the user can move or hide it in Settings ▸ Context Menu.
    public let isConfigurable: Bool

    public init(_ command: String, _ title: String, symbol: String, rules: [ShellMenuRule], isConfigurable: Bool = true) {
        self.command = command
        self.title = title
        self.symbol = symbol
        self.rules = rules
        self.isConfigurable = isConfigurable
    }

    public func isApplicable(to state: ShellItemState) -> Bool {
        rules.contains { $0.matches(state) }
    }
}

/// The menu actually offered for a selection: top-level entries, then the submenu (`nil` = separator).
public struct ShellMenuLayout: Equatable, Sendable {
    public var topLevel: [ShellMenuEntry] = []
    public var submenu: [ShellMenuEntry?] = []

    public var isEmpty: Bool { topLevel.isEmpty && submenu.isEmpty }
    public var commands: [String] { topLevel.map(\.command) + submenu.compactMap { $0?.command } }
}

/// Every Finder menu command in display order, with TortoiseGit's show-if rules (`src/TortoiseShell/MenuInfo.cpp`).
/// Commands without a TortoiseGit entry (Compare Revisions, Statistics, Request Pull, Remotes, SSH Keys,
/// Refresh status) use rules modelled on their closest relative.
public enum ShellMenuCatalog {
    private typealias R = ShellMenuRule

    /// "Always": TortoiseGit's `{ITEMIS_FOLDER, 0}, {0, ITEMIS_FOLDER}`.
    private static let always: [ShellMenuRule] = [R(.folder), R([], .folder)]
    private static let logRules: [ShellMenuRule] = [
        R([.inGit, .onlyOne], .added), R([.folder, .folderInGit, .onlyOne], .added),
        R([.folderInGit, .onlyOne], .added), R(.bareRepo)
    ]
    private static let repoFolder: [ShellMenuRule] = [R([.folderInGit, .onlyOne])]
    private static let repoFolderOrBare: [ShellMenuRule] = [R([.folderInGit, .onlyOne]), R(.bareRepo)]
    private static let repoFolderIdle: [ShellMenuRule] = [R([.folderInGit, .onlyOne], [.bisect, .mergeActive])]
    private static let outsideRepository: ShellItemState = [.inGit, .folderInGit, .bareRepo, .inaccessible]

    /// Display order; `nil` separates groups.
    public static let items: [ShellMenuEntry?] = [
        ShellMenuEntry("inaccessible", "Repository Inaccessible", symbol: "exclamationmark.lock",
                       rules: [R(.inaccessible, [.inGit, .folderInGit, .bareRepo])], isConfigurable: false),
        ShellMenuEntry("clone", "Clone…", symbol: "square.and.arrow.down",
                       rules: [R(.folder, outsideRepository), R([.folder, .ignored]), R([.folder, .extended])]),
        ShellMenuEntry("pull", "Pull…", symbol: "arrow.down.circle",
                       rules: [R([.folderInGit, .onlyOne], [.bisect, .mergeActive]), R(.wcRoot, [.bisect, .mergeActive])]),
        ShellMenuEntry("fetch", "Fetch…", symbol: "arrow.down.to.line.circle",
                       rules: [R([.folderInGit, .onlyOne]), R(.bareRepo), R(.wcRoot)]),
        ShellMenuEntry("push", "Push…", symbol: "arrow.up.circle",
                       rules: [R([.folderInGit, .onlyOne]), R(.bareRepo), R(.wcRoot)]),
        ShellMenuEntry("sync", "Sync…", symbol: "arrow.triangle.2.circlepath", rules: repoFolderIdle),
        nil,
        ShellMenuEntry("commit", "Commit…", symbol: "checkmark.circle", rules: [R(.inGit), R(.folderInGit)]),
        nil,
        ShellMenuEntry("diff", "Diff", symbol: "plusminus", rules: [R([.inGit, .onlyOne]), R(.two, .folder)]),
        ShellMenuEntry("diffprevious", "Diff with Previous Version", symbol: "plusminus.circle",
                       rules: [R([.inGit, .onlyOne], [.added, .folder])]),
        ShellMenuEntry("filediff", "Compare Revisions…", symbol: "arrow.left.arrow.right", rules: [R([.inGit, .onlyOne], .added)]),
        nil,
        ShellMenuEntry("log", "Show Log", symbol: "clock.arrow.circlepath", rules: logRules),
        ShellMenuEntry("reflog", "Show RefLog", symbol: "list.bullet.rectangle", rules: repoFolderOrBare),
        ShellMenuEntry("browserefs", "Browse References", symbol: "tag", rules: repoFolderOrBare),
        ShellMenuEntry("daemon", "Daemon", symbol: "server.rack", rules: logRules),
        ShellMenuEntry("revisiongraph", "Revision Graph", symbol: "point.3.connected.trianglepath.dotted", rules: logRules),
        ShellMenuEntry("repobrowser", "Repository Browser", symbol: "folder", rules: [R([.folderInGit, .onlyOne]), R([.bareRepo, .onlyOne])]),
        ShellMenuEntry("stats", "Revision Statistics", symbol: "chart.bar", rules: repoFolder),
        ShellMenuEntry("changed", "Check for Modifications", symbol: "doc.text.magnifyingglass",
                       rules: [R(.inGit), R([.folder, .folderInGit])]),
        ShellMenuEntry("rebase", "Rebase…", symbol: "arrow.uturn.up", rules: repoFolderIdle),
        ShellMenuEntry("stash", "Stash Changes…", symbol: "tray.and.arrow.down", rules: [R([.inGit, .onlyOne], .mergeActive)]),
        ShellMenuEntry("stashapply", "Stash Apply", symbol: "tray.and.arrow.up", rules: [R([.folderInGit, .onlyOne, .stash])]),
        ShellMenuEntry("stashpop", "Stash Pop", symbol: "tray.and.arrow.up.fill", rules: [R([.folderInGit, .onlyOne, .stash])]),
        ShellMenuEntry("stashlist", "Stash List", symbol: "tray.full", rules: [R([.folderInGit, .onlyOne, .stash])]),
        nil,
        ShellMenuEntry("bisect", "Bisect…", symbol: "scope", rules: [R([.folderInGit, .onlyOne], .mergeActive)]),
        nil,
        ShellMenuEntry("merge", "Edit Conflicts", symbol: "exclamationmark.triangle", rules: [R([.inGit, .conflicted], .folder)]),
        // TortoiseGit offers Resolve on every versioned folder; only offer it while something can conflict.
        ShellMenuEntry("resolve", "Resolve…", symbol: "checkmark.seal",
                       rules: [R([.inGit, .conflicted]), R([.folderInGit, .mergeActive]),
                               R([.folderInGit, .rebaseActive]), R([.folderInGit, .cherryPickActive])]),
        ShellMenuEntry("abortmerge", "Abort Merge…", symbol: "xmark.octagon",
                       rules: [R([.inGit, .mergeActive]), R([.folderInGit, .mergeActive])]),
        ShellMenuEntry("rename", "Rename…", symbol: "pencil",
                       rules: [R([.inGit, .onlyOne, .inVersionedFolder], .wcRoot), R([.wcRoot, .submodule])]),
        ShellMenuEntry("remove", "Delete…", symbol: "trash",
                       rules: [R([.inGit, .inVersionedFolder], [.added, .wcRoot]), R([.folderInGit, .wcRoot, .submodule])]),
        ShellMenuEntry("deletekeeplocal", "Delete (Keep Local)", symbol: "trash.slash",
                       rules: [R([.inGit, .inVersionedFolder], [.added, .wcRoot])]),
        ShellMenuEntry("revert", "Revert…", symbol: "arrow.uturn.backward", rules: [R(.inGit, .normal), R(.folderInGit)]),
        ShellMenuEntry("reset", "Reset…", symbol: "exclamationmark.arrow.circlepath", rules: repoFolder),
        ShellMenuEntry("cleanup", "Clean Up…", symbol: "sparkles", rules: [R([.folderInGit, .folder])]),
        nil,
        ShellMenuEntry("lfslocks", "LFS Locks…", symbol: "lock.rectangle.stack", rules: [R([.folderInGit, .onlyOne, .lfs])]),
        ShellMenuEntry("lfslock", "LFS Lock", symbol: "lock", rules: [R([.inGit, .inVersionedFolder, .lfs], .folder)]),
        ShellMenuEntry("lfsunlock", "LFS Unlock", symbol: "lock.open", rules: [R([.inGit, .inVersionedFolder, .lfs], .folder)]),
        nil,
        ShellMenuEntry("switch", "Switch/Checkout…", symbol: "arrow.triangle.branch", rules: repoFolder),
        ShellMenuEntry("mergebranch", "Merge…", symbol: "arrow.triangle.merge", rules: repoFolderIdle),
        ShellMenuEntry("branch", "Create Branch/Tag…", symbol: "plus.square.on.square", rules: repoFolder),
        ShellMenuEntry("export", "Export…", symbol: "square.and.arrow.up", rules: repoFolderOrBare),
        nil,
        ShellMenuEntry("createrepo", "Create Repository Here…", symbol: "plus.rectangle.on.folder",
                       rules: [R(.folder, outsideRepository), R([.folder, .ignored]), R([.folder, .extended], .inGit)]),
        ShellMenuEntry("add", "Add…", symbol: "plus.circle",
                       rules: [R(.inVersionedFolder, .inGit), R([.inGit, .folder]), R(.ignored), R(.deleted, [.folder, .onlyOne])]),
        ShellMenuEntry("blame", "Blame…", symbol: "person.text.rectangle", rules: [R([.inGit, .onlyOne], [.folder, .added])]),
        ShellMenuEntry("ignore", "Add to Ignore List…", symbol: "eye.slash",
                       rules: [R(.inVersionedFolder, [.ignored, .inGit, .wcRoot])]),
        ShellMenuEntry("deleteandignore", "Delete and Add to Ignore List…", symbol: "eye.slash.circle",
                       rules: [R([.inVersionedFolder, .inGit], [.ignored, .wcRoot])]),
        ShellMenuEntry("removefromignore", "Remove from Ignore List…", symbol: "eye", rules: [R([.inVersionedFolder, .ignored])]),
        nil,
        ShellMenuEntry("worktree", "Worktrees…", symbol: "square.stack.3d.up", rules: repoFolderOrBare),
        ShellMenuEntry("submodule", "Submodules…", symbol: "shippingbox", rules: repoFolder),
        nil,
        ShellMenuEntry("formatpatch", "Create Patch Serial…", symbol: "doc.badge.plus", rules: repoFolder),
        ShellMenuEntry("applypatchserial", "Apply Patch Serial…", symbol: "doc.badge.arrow.up",
                       rules: [R([.patchFile, .inVersionedFolder]), R([.folderInGit, .onlyOne])]),
        ShellMenuEntry("patch", "Create/Apply Patch…", symbol: "bandage",
                       rules: [R([.patchFile, .onlyOne, .inVersionedFolder]), R([.folderInGit, .onlyOne])]),
        ShellMenuEntry("sendmail", "Send Mail…", symbol: "envelope.badge", rules: [R(.patchFile), R(.extended, .folder)]),
        ShellMenuEntry("requestpull", "Request Pull…", symbol: "envelope", rules: repoFolder),
        ShellMenuEntry("remotes", "Remotes…", symbol: "network", rules: repoFolder),
        nil,
        ShellMenuEntry("refresh", "Refresh Status", symbol: "arrow.clockwise", rules: [R(.inVersionedFolder), R(.bareRepo)]),
        ShellMenuEntry("ssh", "SSH Keys…", symbol: "key", rules: always),
        ShellMenuEntry("settings", "Settings…", symbol: "gearshape", rules: always),
        ShellMenuEntry("help", "Help", symbol: "questionmark.circle", rules: always),
        ShellMenuEntry("about", "About", symbol: "info.circle", rules: always)
    ]

    public static let entries: [ShellMenuEntry] = items.compactMap { $0 }

    /// Entries listed in Settings ▸ Context Menu.
    public static var configurableEntries: [ShellMenuEntry] { entries.filter(\.isConfigurable) }

    public static func entry(for command: String) -> ShellMenuEntry? {
        entries.first { $0.command == command }
    }

    /// Shown directly in the Finder menu by default (TortoiseGit's `defaultTopMenuEntries` plus
    /// PangolinGit's long-standing Diff and Show Log).
    public static let defaultTopLevel: Set<String> = ["clone", "createrepo", "sync", "commit", "diff", "log"]

    /// Only shown with Shift held, by default (`defaultExtMenuEntries`).
    public static let defaultExtended: Set<String> = ["stashapply"]

    /// Builds the menu for a selection (`CShellExt::QueryContextMenu`): drops entries the user hid,
    /// extended-only entries without Shift and entries whose rules do not match, and collapses
    /// separators so none leads, trails or doubles.
    public static func layout(for state: ShellItemState, settings: FinderSettings) -> ShellMenuLayout {
        var layout = ShellMenuLayout()
        var pendingSeparator = false
        for item in items {
            guard let entry = item else {
                pendingSeparator = true
                continue
            }
            let placement = entry.isConfigurable ? settings.placement(for: entry.command) : .submenu
            if placement == .hidden { continue }
            if settings.isExtended(entry.command) && !state.contains(.extended) { continue }
            guard entry.isApplicable(to: state) else { continue }
            if placement == .topLevel {
                layout.topLevel.append(entry)
                continue
            }
            if pendingSeparator && !layout.submenu.isEmpty {
                layout.submenu.append(nil)
            }
            pendingSeparator = false
            layout.submenu.append(entry)
        }
        return layout
    }
}
