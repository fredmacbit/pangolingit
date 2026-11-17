import Foundation

/// Helper for `GIT_ASKPASS` and `SSH_ASKPASS` interactions.
/// Equivalent to TortoiseGit's `SshAskPass.exe`: git and ssh spawn the `pangolin-askpass` tool
/// (shipped in `PangolinGit.app/Contents/MacOS`) with the prompt as its only argument and read
/// the answer from its standard output. The same tool doubles as a git credential helper
/// (`pangolin-askpass get|store|erase`) so HTTPS logins are asked for in one form.
public enum AskPassHelper {

    public static let executableName = "pangolin-askpass"

    /// Arguments git passes to a credential helper.
    public static let credentialActions: Set<String> = ["get", "store", "erase"]

    public enum PromptKind: Equatable, Sendable {
        case username
        case password
        case passphrase
        case confirmation   // e.g. ssh host key "Are you sure you want to continue connecting (yes/no)?"
    }

    /// Path of the askpass tool next to the running executable, if it is installed.
    public static var helperExecutablePath: String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let candidate = dir.appendingPathComponent(executableName).path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// Classifies a git/ssh prompt so the UI can choose a plain or secure input field.
    public static func classify(prompt: String) -> PromptKind {
        let lower = prompt.lowercased()
        if lower.contains("(yes/no") { return .confirmation }
        if lower.hasPrefix("username") { return .username }
        if lower.contains("passphrase") { return .passphrase }
        return .password
    }

    /// Environment variables that route git and OpenSSH prompts to the askpass tool and, when
    /// `credentialPrompt` is on, append it as the last credential helper. It runs after the user's
    /// own helpers (osxkeychain, …), so it only asks when they had nothing.
    public static func askPassEnvironment(helperPath: String,
                                          credentialPrompt: Bool = ConfigManager.shared.useCredentialPrompt,
                                          inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = [
            "GIT_ASKPASS": helperPath,
            "SSH_ASKPASS": helperPath,
            "SSH_ASKPASS_REQUIRE": "force"
        ]
        // Never clobber config the user already injects through the environment.
        if credentialPrompt, inherited["GIT_CONFIG_COUNT"] == nil {
            env["GIT_CONFIG_COUNT"] = "1"
            env["GIT_CONFIG_KEY_0"] = "credential.helper"
            env["GIT_CONFIG_VALUE_0"] = credentialHelperValue(helperPath: helperPath)
        }
        return env
    }

    /// `credential.helper` value running the tool: the `!` form is a shell snippet, so a path with
    /// spaces still works (git appends ` get` / ` store` / ` erase`).
    public static func credentialHelperValue(helperPath: String) -> String {
        "!" + GitRemotes.shellQuote(helperPath)
    }

    // MARK: - Prompt parsing

    /// The ssh "authenticity of host" question, split up so the dialog can show the fingerprint
    /// prominently (TortoiseGit's plink host-key dialog).
    public struct HostKeyPrompt: Equatable, Sendable {
        public let host: String
        public let keyType: String
        public let fingerprint: String
        /// True for "REMOTE HOST IDENTIFICATION HAS CHANGED" style warnings.
        public let changed: Bool
    }

    public static func parseHostKeyPrompt(_ prompt: String) -> HostKeyPrompt? {
        guard let host = firstMatch(#"authenticity of host '([^']+)'"#, in: prompt)
                ?? firstMatch(#"host key for ([^\s]+) has changed"#, in: prompt),
              let keyLine = firstMatchGroups(#"([A-Za-z0-9-]+) key fingerprint is ([^\s]+?)\.?(?:\s|$)"#, in: prompt) else { return nil }
        let changed = prompt.uppercased().contains("HAS CHANGED")
        return HostKeyPrompt(host: host, keyType: keyLine[0], fingerprint: keyLine[1], changed: changed)
    }

    /// The URL git names in `Username for 'https://host': ` / `Password for 'https://user@host': `.
    public static func promptLocation(_ prompt: String) -> String? {
        firstMatch(#"for '([^']+)'"#, in: prompt)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        firstMatchGroups(pattern, in: text)?.first
    }

    private static func firstMatchGroups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
