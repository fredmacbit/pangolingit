import Foundation

/// Answers to "Don't show this again" prompts (TortoiseGit's `CMessageBox::ShowCheck` registry
/// values, cleared from Settings ▸ Saved Data ▸ "Stored decisions").
public final class StoredDecisions: @unchecked Sendable {
    public static let shared = StoredDecisions()

    /// Well-known decision keys, named after their TortoiseGit counterparts where one exists.
    public enum Key {
        /// Finder extension / background agent setup prompt on launch.
        public static let finderExtensionPrompt = "FinderExtensionPrompt"
        /// Security warning before starting `git daemon` (TortoiseGit: `DaemonNoSecurityWarning`).
        public static let daemonSecurityWarning = "DaemonNoSecurityWarning"
        /// Confirmation before force-unlocking somebody else's LFS lock.
        public static let lfsForceUnlock = "LFSForceUnlock"
        /// Prefix of project-provided hook script approvals (`.tgitconfig` hooks), suffixed by a hash.
        public static let projectHookApprovalPrefix = "ProjectHookApproval:"
        /// Update offer the user skipped, suffixed by the version.
        public static let skippedUpdatePrefix = "SkippedUpdate:"
    }

    private let defaults: UserDefaults
    private let storageKey = "storedDecisions"

    public init(suiteName: String = "group.be.macbit.pangolingit") {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    private var all: [String: Int] {
        get { defaults.dictionary(forKey: storageKey) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: storageKey) }
    }

    /// The stored answer (e.g. the index of the button that was chosen), or nil to ask again.
    public func decision(for key: String) -> Int? {
        all[key]
    }

    public func store(_ answer: Int, for key: String) {
        var current = all
        current[key] = answer
        all = current
    }

    public func remove(_ key: String) {
        var current = all
        current.removeValue(forKey: key)
        all = current
    }

    public var count: Int { all.count }

    public func removeAll() {
        defaults.removeObject(forKey: storageKey)
    }
}
