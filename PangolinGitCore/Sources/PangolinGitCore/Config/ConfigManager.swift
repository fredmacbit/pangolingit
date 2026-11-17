import Foundation

/// Configuration and preferences manager backed by the App Group container.
/// Equivalent to TortoiseGit registry configuration (`src/Utils/Registry.cpp`).
public final class ConfigManager: @unchecked Sendable {
    public static let shared = ConfigManager()
    
    /// Internal so feature-specific settings can live in their own extension files.
    let defaults: UserDefaults
    
    public init(suiteName: String = "group.be.macbit.pangolingit") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }
    
    public enum Keys {
        // General & Finder
        public static let gitExecutablePath = "gitExecutablePath"
        public static let showUnversionedOverlay = "showUnversionedOverlay"
        public static let showIgnoredOverlay = "showIgnoredOverlay"
        public static let recursiveStatusDepth = "recursiveStatusDepth"
        
        // External Tools (8.10)
        public static let externalDiffTool = "externalDiffTool"
        public static let externalMergeTool = "externalMergeTool"
        public static let externalDiffToolArgs = "externalDiffToolArgs"
        public static let externalMergeToolArgs = "externalMergeToolArgs"
        
        // Context Menu Entries (8.7)
        public static let contextMenuEntries = "contextMenuEntries"
        
        // Dialog Settings (8.8)
        public static let autoCloseProgress = "autoCloseProgress"
        public static let progressAutoClose = "progressAutoClose"
        public static let defaultCommitAll = "defaultCommitAll"
        public static let showPushAfterCommit = "showPushAfterCommit"
        public static let maxRecentHistory = "maxRecentHistory"
        public static let confirmOnRevert = "confirmOnRevert"
        
        // Colors (8.9)
        public static let diffAddedColorHex = "diffAddedColorHex"
        public static let diffDeletedColorHex = "diffDeletedColorHex"
        public static let diffModifiedColorHex = "diffModifiedColorHex"
        
        // Network & Proxy (8.11)
        public static let httpProxy = "httpProxy"
        public static let httpsProxy = "httpsProxy"
        public static let noProxy = "noProxy"
        public static let sslVerify = "sslVerify"
        
        // Git Hooks (8.12)
        public static let hooksEnabled = "hooksEnabled"
        public static let customHooksDirectory = "customHooksDirectory"
        
        // Advanced (8.13)
        public static let advancedSettings = "advancedSettings"
        
        // Saved Data (8.14)
        public static let recentCommitMessages = "recentCommitMessages"
        public static let recentRepositories = "recentRepositories"
        public static let recentUrls = "recentUrls"
        public static let recentCommitMessagesByRepository = "recentCommitMessagesByRepository"
        
        // Blame Settings (8.16)
        public static let blameColorMode = "blameColorMode" // "author" or "date"
        public static let blameFontName = "blameFontName"
        public static let blameFontSize = "blameFontSize"
        public static let blameDateFormat = "blameDateFormat"
        public static let blameIgnoreWhitespace = "blameIgnoreWhitespace"
        public static let blameFollowCopies = "blameFollowCopies"
        
        // Credential Helper (9.6)
        public static let credentialHelper = "credentialHelper"
        
        // First-run wizard (8.17)
        public static let hasCompletedFirstRun = "hasCompletedFirstRun"
    }
    
    // MARK: - First Run
    
    public var hasCompletedFirstRun: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedFirstRun) }
        set { defaults.set(newValue, forKey: Keys.hasCompletedFirstRun) }
    }
    
    // MARK: - General
    
    public var gitExecutablePath: String {
        get { defaults.string(forKey: Keys.gitExecutablePath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.gitExecutablePath) }
    }
    
    public var showUnversionedOverlay: Bool {
        get { defaults.object(forKey: Keys.showUnversionedOverlay) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showUnversionedOverlay) }
    }
    
    public var showIgnoredOverlay: Bool {
        get { defaults.object(forKey: Keys.showIgnoredOverlay) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showIgnoredOverlay) }
    }
    
    public var recursiveStatusDepth: Int {
        get { defaults.object(forKey: Keys.recursiveStatusDepth) as? Int ?? 3 }
        set { defaults.set(newValue, forKey: Keys.recursiveStatusDepth) }
    }
    
    // MARK: - External Tools (8.10)
    
    public var externalDiffTool: String {
        get { defaults.string(forKey: Keys.externalDiffTool) ?? "" }
        set { defaults.set(newValue, forKey: Keys.externalDiffTool) }
    }
    
    public var externalMergeTool: String {
        get { defaults.string(forKey: Keys.externalMergeTool) ?? "" }
        set { defaults.set(newValue, forKey: Keys.externalMergeTool) }
    }
    
    public var externalDiffToolArgs: String {
        get { defaults.string(forKey: Keys.externalDiffToolArgs) ?? "\"$LOCAL\" \"$REMOTE\"" }
        set { defaults.set(newValue, forKey: Keys.externalDiffToolArgs) }
    }
    
    public var externalMergeToolArgs: String {
        get { defaults.string(forKey: Keys.externalMergeToolArgs) ?? "\"$LOCAL\" \"$REMOTE\" \"$BASE\" \"$MERGED\"" }
        set { defaults.set(newValue, forKey: Keys.externalMergeToolArgs) }
    }
    
    // MARK: - Context Menu Customization (8.7)
    
    public var contextMenuEntries: [String: Bool] {
        get {
            if let dict = defaults.dictionary(forKey: Keys.contextMenuEntries) as? [String: Bool] {
                return dict
            }
            return [
                "commit": true,
                "diff": true,
                "log": true,
                "blame": true,
                "pull": true,
                "push": true,
                "sync": true,
                "changed": true,
                "revert": true,
                "reset": true,
                "switch": true,
                "browseRefs": true,
                "stash": true,
                "worktree": true,
                "submodule": true,
                "patch": true,
                "requestPull": true,
                "lfsLocks": true,
                "stats": true,
                "repoBrowser": true,
                "reflog": true,
                "bisect": true,
                "add": true,
                "ignore": true,
                "export": true,
                "rename": true,
                "remove": true,
                "remotes": true,
                "ssh": true,
                "settings": true
            ]
        }
        set { defaults.set(newValue, forKey: Keys.contextMenuEntries) }
    }
    
    public func isContextMenuEnabled(for command: String) -> Bool {
        return contextMenuEntries[command] ?? true
    }
    
    public func setContextMenuEnabled(_ enabled: Bool, for command: String) {
        var current = contextMenuEntries
        current[command] = enabled
        contextMenuEntries = current
    }
    
    // MARK: - Dialog Settings (8.8)
    
    /// When the progress window closes by itself (TortoiseGit's "Autoclose git.exe dialog").
    public enum ProgressAutoClose: Int, CaseIterable, Sendable {
        case manual = 0
        /// Close after success when there is no follow-up action to offer.
        case ifNoFurtherOptions = 1
        /// Close after every successful run.
        case ifNoErrors = 2

        public var title: String {
            switch self {
            case .manual: return "Close manually"
            case .ifNoFurtherOptions: return "Close automatically if there are no further options"
            case .ifNoErrors: return "Close automatically if there are no errors"
            }
        }
    }

    public var progressAutoClose: ProgressAutoClose {
        get {
            if let raw = defaults.object(forKey: Keys.progressAutoClose) as? Int, let mode = ProgressAutoClose(rawValue: raw) {
                return mode
            }
            // Earlier versions stored a single on/off flag.
            return defaults.bool(forKey: Keys.autoCloseProgress) ? .ifNoErrors : .manual
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.progressAutoClose) }
    }
    
    public var defaultCommitAll: Bool {
        get { defaults.object(forKey: Keys.defaultCommitAll) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.defaultCommitAll) }
    }
    
    /// Open the Push dialog after a successful commit (when the repository has a remote).
    public var showPushAfterCommit: Bool {
        get { defaults.object(forKey: Keys.showPushAfterCommit) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showPushAfterCommit) }
    }
    
    public var maxRecentHistory: Int {
        get { defaults.object(forKey: Keys.maxRecentHistory) as? Int ?? 25 }
        set { defaults.set(newValue, forKey: Keys.maxRecentHistory) }
    }
    
    public var confirmOnRevert: Bool {
        get { defaults.object(forKey: Keys.confirmOnRevert) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.confirmOnRevert) }
    }
    
    // MARK: - Colors (8.9)
    
    public var diffAddedColorHex: String {
        get { defaults.string(forKey: Keys.diffAddedColorHex) ?? "#28A745" }
        set { defaults.set(newValue, forKey: Keys.diffAddedColorHex) }
    }
    
    public var diffDeletedColorHex: String {
        get { defaults.string(forKey: Keys.diffDeletedColorHex) ?? "#D73A49" }
        set { defaults.set(newValue, forKey: Keys.diffDeletedColorHex) }
    }
    
    public var diffModifiedColorHex: String {
        get { defaults.string(forKey: Keys.diffModifiedColorHex) ?? "#0366D6" }
        set { defaults.set(newValue, forKey: Keys.diffModifiedColorHex) }
    }
    
    // MARK: - Network & Proxy (8.11)
    
    public var httpProxy: String {
        get { defaults.string(forKey: Keys.httpProxy) ?? "" }
        set { defaults.set(newValue, forKey: Keys.httpProxy) }
    }
    
    public var httpsProxy: String {
        get { defaults.string(forKey: Keys.httpsProxy) ?? "" }
        set { defaults.set(newValue, forKey: Keys.httpsProxy) }
    }
    
    public var noProxy: String {
        get { defaults.string(forKey: Keys.noProxy) ?? "localhost,127.0.0.1" }
        set { defaults.set(newValue, forKey: Keys.noProxy) }
    }
    
    public var sslVerify: Bool {
        get { defaults.object(forKey: Keys.sslVerify) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.sslVerify) }
    }
    
    // MARK: - Hooks (8.12)
    
    public var hooksEnabled: Bool {
        get { defaults.object(forKey: Keys.hooksEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.hooksEnabled) }
    }
    
    public var customHooksDirectory: String {
        get { defaults.string(forKey: Keys.customHooksDirectory) ?? "" }
        set { defaults.set(newValue, forKey: Keys.customHooksDirectory) }
    }
    
    // MARK: - Advanced (8.13)
    
    public var advancedSettings: [String: String] {
        get { defaults.dictionary(forKey: Keys.advancedSettings) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Keys.advancedSettings) }
    }
    
    // MARK: - Saved Data (8.14)
    
    public var recentCommitMessages: [String] {
        get { defaults.stringArray(forKey: Keys.recentCommitMessages) ?? [] }
        set {
            let trimmed = Array(newValue.prefix(maxRecentHistory))
            defaults.set(trimmed, forKey: Keys.recentCommitMessages)
        }
    }
    
    public func addRecentCommitMessage(_ message: String) {
        var current = recentCommitMessages.filter { $0 != message }
        current.insert(message, at: 0)
        recentCommitMessages = current
    }
    
    public func clearRecentCommitMessages() {
        defaults.removeObject(forKey: Keys.recentCommitMessages)
        defaults.removeObject(forKey: Keys.recentCommitMessagesByRepository)
    }
    
    public var recentRepositories: [String] {
        get { defaults.stringArray(forKey: Keys.recentRepositories) ?? [] }
        set {
            let trimmed = Array(newValue.prefix(maxRecentHistory))
            defaults.set(trimmed, forKey: Keys.recentRepositories)
        }
    }
    
    public func addRecentRepository(_ path: String) {
        var current = recentRepositories.filter { $0 != path }
        current.insert(path, at: 0)
        recentRepositories = current
    }
    
    public func clearRecentRepositories() {
        defaults.removeObject(forKey: Keys.recentRepositories)
    }
    
    public var recentUrls: [String] {
        get { defaults.stringArray(forKey: Keys.recentUrls) ?? [] }
        set {
            let trimmed = Array(newValue.prefix(maxRecentHistory))
            defaults.set(trimmed, forKey: Keys.recentUrls)
        }
    }
    
    public func addRecentUrl(_ url: String) {
        var current = recentUrls.filter { $0 != url }
        current.insert(url, at: 0)
        recentUrls = current
    }
    
    public func clearRecentUrls() {
        defaults.removeObject(forKey: Keys.recentUrls)
    }

    /// Commit messages of one repository, newest first (TortoiseGit keeps the history per working
    /// tree; the global `recentCommitMessages` list remains for the Saved Data count).
    public func recentCommitMessages(forRepository repository: String) -> [String] {
        let all = defaults.dictionary(forKey: Keys.recentCommitMessagesByRepository) as? [String: [String]] ?? [:]
        return all[repository] ?? []
    }

    public func setRecentCommitMessages(_ messages: [String], forRepository repository: String) {
        var all = defaults.dictionary(forKey: Keys.recentCommitMessagesByRepository) as? [String: [String]] ?? [:]
        all[repository] = messages.isEmpty ? nil : Array(messages.prefix(maxRecentHistory))
        defaults.set(all, forKey: Keys.recentCommitMessagesByRepository)
    }

    public func addRecentCommitMessage(_ message: String, forRepository repository: String) {
        addRecentCommitMessage(message)
        var current = recentCommitMessages(forRepository: repository).filter { $0 != message }
        current.insert(message, at: 0)
        setRecentCommitMessages(current, forRepository: repository)
    }
    
    public func clearAllSavedData() {
        clearRecentCommitMessages()
        clearRecentRepositories()
        clearRecentUrls()
    }
    
    // MARK: - Blame Settings (8.16)
    
    public var blameColorMode: String {
        get { defaults.string(forKey: Keys.blameColorMode) ?? "author" }
        set { defaults.set(newValue, forKey: Keys.blameColorMode) }
    }
    
    public var blameFontName: String {
        get { defaults.string(forKey: Keys.blameFontName) ?? "Menlo" }
        set { defaults.set(newValue, forKey: Keys.blameFontName) }
    }
    
    public var blameFontSize: Double {
        get { defaults.object(forKey: Keys.blameFontSize) as? Double ?? 11.0 }
        set { defaults.set(newValue, forKey: Keys.blameFontSize) }
    }
    
    public var blameDateFormat: String {
        get { defaults.string(forKey: Keys.blameDateFormat) ?? "yyyy-MM-dd HH:mm" }
        set { defaults.set(newValue, forKey: Keys.blameDateFormat) }
    }
    
    public var blameIgnoreWhitespace: Bool {
        get { defaults.bool(forKey: Keys.blameIgnoreWhitespace) }
        set { defaults.set(newValue, forKey: Keys.blameIgnoreWhitespace) }
    }
    
    public var blameFollowCopies: Bool {
        get { defaults.bool(forKey: Keys.blameFollowCopies) }
        set { defaults.set(newValue, forKey: Keys.blameFollowCopies) }
    }
    
    // MARK: - Credential Helper (9.6)
    
    public var credentialHelper: String {
        get { defaults.string(forKey: Keys.credentialHelper) ?? "osxkeychain" }
        set { defaults.set(newValue, forKey: Keys.credentialHelper) }
    }

    // MARK: - Remote workflow (P6)

    /// Whether git asks for HTTPS logins through PangolinGit's own dialog (username and password in
    /// one form, optionally remembered in the Keychain) when the configured helpers have nothing.
    public var useCredentialPrompt: Bool {
        get { defaults.object(forKey: "useCredentialPrompt") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useCredentialPrompt") }
    }

    // MARK: - Trash (TortoiseGit "Use recycle bin when reverting")

    /// Move files to the Trash before Revert overwrites them and when Delete / Clean up removes them.
    public var useTrashOnRevert: Bool {
        get { defaults.object(forKey: "useTrashOnRevert") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useTrashOnRevert") }
    }

    // MARK: - General: extra PATH and update check (SE-03, UP-01)

    /// Folders prepended to PATH for every git run (TortoiseGit's "Extra PATH" on the General page),
    /// e.g. where git-lfs or a credential helper lives. Colon-separated.
    public var extraPath: String {
        get { defaults.string(forKey: "extraPath") ?? "" }
        set { defaults.set(newValue, forKey: "extraPath") }
    }

    /// Check for updates once a week (TortoiseGit's "Automatically check for newer versions every week").
    public var automaticUpdateCheck: Bool {
        get { defaults.object(forKey: "automaticUpdateCheck") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "automaticUpdateCheck") }
    }

    /// Offer pre-releases as updates (TortoiseGit's preview release channel).
    public var updateIncludesPrereleases: Bool {
        get { defaults.bool(forKey: "updateIncludesPrereleases") }
        set { defaults.set(newValue, forKey: "updateIncludesPrereleases") }
    }

    /// When the update check last ran (automatic or manual).
    public var lastUpdateCheck: Date? {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }

    /// "Remind me later": no automatic update prompt before this date.
    public var updateRemindAfter: Date? {
        get { defaults.object(forKey: "updateRemindAfter") as? Date }
        set { defaults.set(newValue, forKey: "updateRemindAfter") }
    }

    /// The suite's own stored preferences, for Settings ▸ Saved Data ▸ Export.
    public func exportedSettings(suiteName: String = "group.be.macbit.pangolingit") -> [String: Any] {
        defaults.persistentDomain(forName: suiteName) ?? [:]
    }

    /// Stores an exported set of preferences (keys not in the set keep their values).
    public func importSettings(_ values: [String: Any]) {
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
    }
}
