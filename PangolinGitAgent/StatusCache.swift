import Foundation
import PangolinGitCore

/// Central status cache: one `RepositoryStatusSnapshot` per working tree, refreshed lazily after
/// FSEvents reports a change. Equivalent to TortoiseGit's `CGITStatusCache` (`src/TGitCache/GITStatusCache.cpp`).
final class StatusCache: @unchecked Sendable {
    static let shared = StatusCache()

    /// Upper bound on snapshot age even without FSEvents (e.g. network volumes that don't report events).
    private static let maxSnapshotAge: TimeInterval = 60
    private static let maxRepositories = 64

    /// Per-repository state. All mutation of `snapshot`/`isStale` happens on `queue`.
    private final class Entry: @unchecked Sendable {
        let root: PangolinPath
        let queue: DispatchQueue
        var snapshot: RepositoryStatusSnapshot?
        var isStale = true
        var lastAccess = Date()
        var watcher: FSEventsWatcher?

        init(root: PangolinPath) {
            self.root = root
            self.queue = DispatchQueue(label: "be.macbit.pangolingit.agent.repo", qos: .userInitiated)
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Folder → working-tree root (or nil when outside any repository), to avoid walking up for every file.
    private var rootLookup: [String: String?] = [:]
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Invoked (on an arbitrary queue) when a repository's status changed after a refresh.
    var onRepositoryChanged: (@Sendable (String) -> Void)?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            PangolinLog.cache.info("Memory pressure; dropping status cache.")
            self?.purgeAll()
        }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Queries

    func queryStatus(forPath rawPath: String, reply: @escaping @Sendable (GitBadgeKind, GitItemStatus, String) -> Void) {
        let path = PangolinPath(rawPath)
        let isDirectory = path.isDirectory
        guard let entry = entry(for: path, isDirectory: isDirectory) else {
            reply(.none, .unknown, "")
            return
        }

        let config = ConfigManager.shared
        // Cache mode "None" and excluded paths: no badge, but the root is still reported for menus.
        if config.overlayCacheMode == .off || !Self.isOverlayAllowed(rawPath, config: config) {
            reply(.none, .unknown, entry.root.rawPath)
            return
        }

        entry.queue.async {
            entry.lastAccess = Date()
            if entry.isStale || entry.snapshot == nil
                || Date().timeIntervalSince(entry.snapshot!.createdAt) > Self.maxSnapshotAge {
                self.refresh(entry)
            }
            guard let snapshot = entry.snapshot, let rel = path.relative(to: entry.root) else {
                reply(.none, .unknown, entry.root.rawPath)
                return
            }
            var result = snapshot.lookup(relativePath: rel, isDirectory: isDirectory)
            if !config.isOverlayEnabled(result.badge) { result.badge = .none }
            reply(result.badge, result.status, entry.root.rawPath)
        }
    }

    /// Status of one path for the context menu, computed synchronously (call off the main queue).
    /// Nil outside a working tree or when git status failed.
    func itemStatus(forPath rawPath: String) -> GitItemStatus? {
        let path = PangolinPath(rawPath)
        let isDirectory = path.isDirectory
        guard let entry = entry(for: path, isDirectory: isDirectory) else { return nil }
        return entry.queue.sync {
            entry.lastAccess = Date()
            if entry.isStale || entry.snapshot == nil {
                refresh(entry)
            }
            guard let snapshot = entry.snapshot, let rel = path.relative(to: entry.root) else { return nil }
            return snapshot.lookup(relativePath: rel, isDirectory: isDirectory).status
        }
    }

    /// Overlay exclusion list (TortoiseGit Settings ▸ Icon Overlays "Exclude paths"), same patterns as
    /// the context-menu exclusions.
    private static func isOverlayAllowed(_ path: String, config: ConfigManager) -> Bool {
        let excluded = config.overlayExcludedPaths
        guard !excluded.isEmpty else { return true }
        return FinderSettings(menuExcludedPaths: excluded).isMenuAllowed(for: path)
    }

    /// An empty path marks every repository stale (overlay settings changed).
    func invalidate(path rawPath: String) {
        if rawPath.isEmpty {
            lock.lock()
            let all = Array(entries.values)
            rootLookup.removeAll()
            lock.unlock()
            all.forEach(markStale)
            return
        }
        // Forget cached "not a repository" answers at and below the path: it may just have been
        // initialised, cloned into or deleted.
        lock.lock()
        for folder in rootLookup.keys where folder == rawPath || folder.hasPrefix(rawPath + "/") {
            rootLookup.removeValue(forKey: folder)
        }
        lock.unlock()
        let path = PangolinPath(rawPath)
        guard let entry = entry(for: path, isDirectory: path.isDirectory) else { return }
        entry.queue.async {
            // A repository seen for the first time (e.g. just created): read it and announce it so
            // Finder re-badges the folders it showed without badges.
            guard entry.snapshot == nil else { return }
            self.refresh(entry)
            self.onRepositoryChanged?(entry.root.rawPath)
        }
        markStale(entry)
    }

    // MARK: - Internals

    /// Must be called on `entry.queue`.
    private func refresh(_ entry: Entry) {
        let previous = entry.snapshot
        entry.isStale = false
        let config = ConfigManager.shared
        do {
            let repo = GitRepository(workingDirectory: entry.root, gitDirectory: entry.root.appending(".git"))
            // "Tracked files only" skips the untracked scan, the expensive part on huge trees (SH-07).
            let items = try repo.status(
                untrackedFiles: config.overlayCacheMode == .trackedOnly ? "no" : "normal",
                includeIgnored: config.showIgnoredOverlay && config.overlayCacheMode == .full
            )
            var options = RepositoryStatusSnapshot.Options(
                unversionedMarksParentModified: config.unversionedMarksParentModified,
                submoduleStatusInParent: config.submoduleStatusInParent
            )
            if config.isOverlayEnabled(.locked) || config.isOverlayEnabled(.needsLock) {
                options.flaggedFiles = Self.indexFlags(root: entry.root)
            }
            entry.snapshot = RepositoryStatusSnapshot(root: entry.root, items: items, options: options)
        } catch {
            PangolinLog.cache.error("git status failed for \(entry.root.rawPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            entry.snapshot = RepositoryStatusSnapshot(root: entry.root, items: [])
        }
        if previous != nil {
            onRepositoryChanged?(entry.root.rawPath)
        }
    }

    /// Skip-worktree / assume-unchanged files (SH-05). Empty when git fails.
    private static func indexFlags(root: PangolinPath) -> [String: GitBadgeKind] {
        guard let output = try? GitCLIRunner.run(arguments: GitIndexFlags.arguments, workingDirectory: root) else { return [:] }
        return GitIndexFlags.parse(output)
    }

    private func markStale(_ entry: Entry) {
        entry.queue.async {
            guard !entry.isStale else { return }
            entry.isStale = true
            // Without badges nothing needs the new status until a menu asks for it.
            if ConfigManager.shared.overlayCacheMode == .off { return }
            // Refresh eagerly so Finder can be told to re-query visible badges.
            self.refresh(entry)
        }
    }

    private func entry(for path: PangolinPath, isDirectory: Bool) -> Entry? {
        let folder = isDirectory ? path.rawPath : path.deletingLastPathComponent.rawPath

        lock.lock()
        let cachedRoot = rootLookup[folder]
        lock.unlock()

        let rootPath: String
        if let cachedRoot {
            guard let cachedRoot else { return nil }
            rootPath = cachedRoot
        } else {
            let locations = GitAdminDir.findRepository(startingAt: PangolinPath(folder))
            let root = (locations?.isBare == false) ? locations?.workingTreeRoot.rawPath : nil
            lock.lock()
            if rootLookup.count > 20_000 { rootLookup.removeAll() }
            rootLookup[folder] = .some(root)
            lock.unlock()
            guard let root else { return nil }
            rootPath = root
        }

        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[rootPath] {
            return existing
        }
        if entries.count >= Self.maxRepositories,
           let oldest = entries.values.min(by: { $0.lastAccess < $1.lastAccess }) {
            oldest.watcher?.stop()
            entries.removeValue(forKey: oldest.root.rawPath)
        }
        let entry = Entry(root: PangolinPath(rootPath))
        let watcher = FSEventsWatcher(path: rootPath) { [weak self, weak entry] changedPaths in
            guard let self, let entry, changedPaths.contains(where: Self.isRelevantChange) else { return }
            self.markStale(entry)
        }
        watcher.start()
        entry.watcher = watcher
        entries[rootPath] = entry
        return entry
    }

    /// Ignores churn inside `.git` other than the files that actually change status (index, HEAD, refs).
    private static func isRelevantChange(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else {
            return !path.hasSuffix("/.git")
        }
        let inside = path[range.upperBound...]
        return inside == "index" || inside == "HEAD" || inside.hasPrefix("refs/")
            || inside == "packed-refs" || inside == "MERGE_HEAD" || inside == "info/exclude"
            || inside == "CHERRY_PICK_HEAD" || inside == "BISECT_START" || inside.hasPrefix("rebase-merge")
    }

    private func purgeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.values.forEach { $0.watcher?.stop() }
        entries.removeAll()
        rootLookup.removeAll()
    }
}
