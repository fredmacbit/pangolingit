import Foundation

/// Settings of the patch, mail and blame tools (TortoiseGit: `SettingsTBlame`, `SettingsSMTP`,
/// `FormatPatchDlg` remembered values). Kept in their own file and key namespace so the shared
/// `ConfigManager` stays untouched; they live in the same App Group suite.
public extension ConfigManager {

    enum ToolKeys {
        public static let blameMoveDetection = "blameMoveDetection"
        public static let blameMoveThreshold = "blameMoveThreshold"
        public static let blameFirstParent = "blameFirstParent"
        public static let blameNewestColorHex = "blameNewestColorHex"
        public static let blameOldestColorHex = "blameOldestColorHex"
        public static let formatPatchDirectory = "formatPatchDirectory"
        public static let sendMailDelivery = "sendMailDelivery"
        public static let sendMailTo = "sendMailTo"
        public static let sendMailCC = "sendMailCC"
        public static let sendMailAsAttachment = "sendMailAsAttachment"
        public static let sendMailCombine = "sendMailCombine"
    }

    private static let toolDefaults = UserDefaults(suiteName: "group.be.macbit.pangolingit") ?? .standard

    private var store: UserDefaults { Self.toolDefaults }

    // MARK: - Blame

    /// Detect moved or copied lines; falls back to the older *Follow copies* toggle (`-C -C`).
    var blameMoveDetection: GitBlame.MoveDetection {
        get {
            if let raw = store.object(forKey: ToolKeys.blameMoveDetection) as? Int, let value = GitBlame.MoveDetection(rawValue: raw) {
                return value
            }
            return blameFollowCopies ? .fromExistingFiles : .disabled
        }
        set {
            store.set(newValue.rawValue, forKey: ToolKeys.blameMoveDetection)
            blameFollowCopies = newValue.rawValue >= GitBlame.MoveDetection.fromExistingFiles.rawValue
        }
    }

    /// Minimum characters of a moved/copied block (`-M<n>` / `-C<n>`); 0 = git's default (20).
    var blameMoveThreshold: Int {
        get { store.integer(forKey: ToolKeys.blameMoveThreshold) }
        set { store.set(max(0, newValue), forKey: ToolKeys.blameMoveThreshold) }
    }

    var blameFirstParent: Bool {
        get { store.bool(forKey: ToolKeys.blameFirstParent) }
        set { store.set(newValue, forKey: ToolKeys.blameFirstParent) }
    }

    /// End points of the age gradient (TortoiseGitBlame's *Newest* / *Oldest* colours).
    var blameNewestColorHex: String {
        get { store.string(forKey: ToolKeys.blameNewestColorHex) ?? "#F2A541" }
        set { store.set(newValue, forKey: ToolKeys.blameNewestColorHex) }
    }

    var blameOldestColorHex: String {
        get { store.string(forKey: ToolKeys.blameOldestColorHex) ?? "#5B7DB1" }
        set { store.set(newValue, forKey: ToolKeys.blameOldestColorHex) }
    }

    // MARK: - Patches and mail

    /// Last output folder of *Create Patch Serial*.
    var formatPatchDirectory: String {
        get { store.string(forKey: ToolKeys.formatPatchDirectory) ?? "" }
        set { store.set(newValue, forKey: ToolKeys.formatPatchDirectory) }
    }

    /// 0 = compose in the default mail app, 1 = `git send-email` (uses the `sendemail.*` git config).
    var sendMailDelivery: Int {
        get { store.integer(forKey: ToolKeys.sendMailDelivery) }
        set { store.set(newValue, forKey: ToolKeys.sendMailDelivery) }
    }

    var sendMailTo: String {
        get { store.string(forKey: ToolKeys.sendMailTo) ?? "" }
        set { store.set(newValue, forKey: ToolKeys.sendMailTo) }
    }

    var sendMailCC: String {
        get { store.string(forKey: ToolKeys.sendMailCC) ?? "" }
        set { store.set(newValue, forKey: ToolKeys.sendMailCC) }
    }

    var sendMailAsAttachment: Bool {
        get { store.object(forKey: ToolKeys.sendMailAsAttachment) as? Bool ?? true }
        set { store.set(newValue, forKey: ToolKeys.sendMailAsAttachment) }
    }

    var sendMailCombine: Bool {
        get { store.bool(forKey: ToolKeys.sendMailCombine) }
        set { store.set(newValue, forKey: ToolKeys.sendMailCombine) }
    }
}
