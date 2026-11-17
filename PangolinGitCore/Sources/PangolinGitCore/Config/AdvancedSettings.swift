import Foundation

/// Typed advanced options (TortoiseGit's Settings ▸ Advanced, `src/TortoiseProc/Settings/SetAdvanced.cpp`).
/// Only options with a PangolinGit consumer are listed; each says where it is read. Values are kept in
/// `ConfigManager.advancedSettings` (string dictionary) so managed preferences can preset them.
public struct AdvancedSetting: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case bool(Bool)
        case int(Int)
        case string(String)
    }

    public let key: String
    public let defaultValue: Kind
    public let summary: String

    public init(key: String, defaultValue: Kind, summary: String) {
        self.key = key
        self.defaultValue = defaultValue
        self.summary = summary
    }

    public var defaultString: String {
        switch defaultValue {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .string(let value): return value
        }
    }

    /// Whether `text` is a valid value for this option.
    public func accepts(_ text: String) -> Bool {
        switch defaultValue {
        case .bool: return ["true", "false", "1", "0", "yes", "no"].contains(text.lowercased())
        case .int: return Int(text) != nil
        case .string: return true
        }
    }

    public static let versionCheck = AdvancedSetting(
        key: "VersionCheck", defaultValue: .bool(true),
        summary: "Allow update checks at all (automatic and manual). Read by the update checker.")
    public static let updateCheckURL = AdvancedSetting(
        key: "UpdateCheckURL", defaultValue: .string(""),
        summary: "Alternative release feed (GitHub releases API compatible), e.g. an intranet mirror. Read by the update checker.")
    public static let styleGitOutput = AdvancedSetting(
        key: "StyleGitOutput", defaultValue: .bool(true),
        summary: "Colour errors and warnings in the git progress window.")
    public static let maxActionLogLines = AdvancedSetting(
        key: "MaxLinesInLogfile", defaultValue: .int(4000),
        summary: "Lines kept in the action log (Settings ▸ Saved Data); 0 disables the log.")
    public static let daemonPort = AdvancedSetting(
        key: "DaemonPort", defaultValue: .int(9418),
        summary: "TCP port of the Git daemon started from the Daemon command.")
    public static let lfsLocksFromServer = AdvancedSetting(
        key: "LFSLocksFromServer", defaultValue: .bool(true),
        summary: "LFS Locks dialog asks the LFS server by default (off: show the locally cached locks).")
    public static let sshKeygenDefaultType = AdvancedSetting(
        key: "SSHKeyDefaultType", defaultValue: .string("ed25519"),
        summary: "Key type preselected when generating an SSH key (ed25519, ecdsa or rsa).")

    /// Every option shown on the Advanced page, alphabetically.
    public static let all: [AdvancedSetting] = [
        daemonPort, lfsLocksFromServer, maxActionLogLines,
        sshKeygenDefaultType, styleGitOutput, updateCheckURL, versionCheck
    ].sorted { $0.key.lowercased() < $1.key.lowercased() }
}

extension ConfigManager {
    /// Raw stored value of an advanced option, nil when it uses its default.
    public func advancedValue(_ setting: AdvancedSetting) -> String? {
        let value = advancedSettings[setting.key]?.trimmingCharacters(in: .whitespaces)
        return (value?.isEmpty ?? true) ? nil : value
    }

    public func advancedBool(_ setting: AdvancedSetting) -> Bool {
        guard case .bool(let fallback) = setting.defaultValue else { return false }
        guard let value = advancedValue(setting)?.lowercased() else { return fallback }
        return ["true", "1", "yes"].contains(value)
    }

    public func advancedInt(_ setting: AdvancedSetting) -> Int {
        guard case .int(let fallback) = setting.defaultValue else { return 0 }
        return advancedValue(setting).flatMap(Int.init) ?? fallback
    }

    public func advancedString(_ setting: AdvancedSetting) -> String {
        guard case .string(let fallback) = setting.defaultValue else { return "" }
        return advancedValue(setting) ?? fallback
    }

    /// Sets (or with nil/empty, resets) an advanced option.
    public func setAdvancedValue(_ value: String?, for setting: AdvancedSetting) {
        var current = advancedSettings
        if let value, !value.isEmpty { current[setting.key] = value } else { current.removeValue(forKey: setting.key) }
        advancedSettings = current
    }
}
