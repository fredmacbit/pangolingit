import Foundation

/// Where a git-config-backed setting is read from or saved to. Mirrors the "Config source" /
/// "Save to" choices on TortoiseGit's per-repository settings pages (Dialogs 3, Issue Tracker).
public enum GitConfigScope: String, CaseIterable, Sendable {
    /// Local, then project (`.tgitconfig`), then global, then system — `ProjectProperties::ReadProps`.
    case effective
    /// `.git/config` of the repository.
    case local
    /// `.tgitconfig` in the working-tree root, committed so every clone shares it.
    case project
    /// `~/.gitconfig`.
    case global
    /// The system git configuration.
    case system

    public var title: String {
        switch self {
        case .effective: return "Effective"
        case .local: return "Local (.git/config)"
        case .project: return "Project (.tgitconfig)"
        case .global: return "Global (~/.gitconfig)"
        case .system: return "System"
        }
    }

    /// Scopes a value can be written to.
    public static let writable: [GitConfigScope] = [.local, .project, .global]

    /// Whether this scope needs a repository.
    public var needsRepository: Bool { self == .local || self == .project || self == .effective }
}

/// Reads and writes git configuration at an explicit scope, including TortoiseGit's `.tgitconfig`.
public struct GitConfigStore: Sendable {
    public let repository: PangolinPath?

    public init(repository: PangolinPath?) {
        self.repository = repository
    }

    /// The `git config` options selecting a single file scope.
    func scopeArguments(_ scope: GitConfigScope) -> [String]? {
        switch scope {
        case .effective: return nil
        case .local: return repository == nil ? nil : ["--local"]
        case .project: return repository.map { ["-f", $0.url.appendingPathComponent(".tgitconfig").path] }
        case .global: return ["--global"]
        case .system: return ["--system"]
        }
    }

    /// All values of one scope (last value wins for multi-valued keys). Keys are lower-cased by git.
    public func values(in scope: GitConfigScope) async -> [String: String] {
        if scope == .effective {
            var merged: [String: String] = [:]
            for layer in [GitConfigScope.system, .global, .project, .local] {
                merged.merge(await values(in: layer)) { _, new in new }
            }
            return merged
        }
        guard let options = scopeArguments(scope) else { return [:] }
        if scope == .project, let repository,
           !FileManager.default.fileExists(atPath: repository.url.appendingPathComponent(".tgitconfig").path) {
            return [:]
        }
        guard let output = try? await GitCLIRunner.runAsync(arguments: ["config"] + options + ["--list", "-z"],
                                                            workingDirectory: repository) else { return [:] }
        return Self.parseListZ(output)
    }

    /// Value of `key` in `scope`, nil when unset.
    public func value(_ key: String, in scope: GitConfigScope) async -> String? {
        await values(in: scope)[key.lowercased()]
    }

    /// Sets `key` (nil or empty removes it) in a writable scope.
    public func set(_ key: String, to value: String?, in scope: GitConfigScope) async throws {
        guard let options = scopeArguments(scope), scope != .effective else { return }
        if let value, !value.isEmpty {
            try await GitCLIRunner.runAsync(arguments: ["config"] + options + [key, value], workingDirectory: repository)
        } else {
            // Exit code 5 means the key was not set; nothing to remove.
            _ = try? await GitCLIRunner.runAsync(arguments: ["config"] + options + ["--unset-all", key], workingDirectory: repository)
        }
    }

    /// Parses `git config --list -z` (`key\nvalue\0`; a key without value has no newline).
    public static func parseListZ(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            if let newline = record.firstIndex(of: "\n") {
                result[record[..<newline].lowercased()] = String(record[record.index(after: newline)...])
            } else {
                result[record.lowercased()] = "true"
            }
        }
        return result
    }

    /// The issue-tracker settings in effect for the repository.
    public func bugtraq(in scope: GitConfigScope = .effective) async -> BugtraqConfig {
        BugtraqConfig(values: await values(in: scope))
    }

    /// TortoiseGit's per-project commit options (`tgit.*`), read with the effective precedence.
    public func projectSettings(in scope: GitConfigScope = .effective) async -> ProjectSettings {
        ProjectSettings(values: await values(in: scope))
    }
}

/// Per-repository commit-dialog options TortoiseGit stores in git config / `.tgitconfig`
/// (Settings ▸ Dialogs 3, `ProjectProperties`). Consumed by the commit dialog.
public struct ProjectSettings: Equatable, Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case logMinSize = "tgit.logminsize"
        case logWidthMarker = "tgit.logwidthmarker"
        case warnNoSignedOffBy = "tgit.warnnosignedoffby"
        case projectLanguage = "tgit.projectlanguage"
        case icon = "tgit.icon"
    }

    /// Minimum commit message length; 0 = no minimum.
    public var logMinSize = 0
    /// Column of the right-margin marker in the message editor; 0 = none.
    public var logWidthMarker = 0
    /// Warn when the message lacks a Signed-off-by line.
    public var warnNoSignedOffBy = false
    /// Spell-check language of commit messages (an `NSSpellChecker` language such as "en_GB");
    /// empty = system default, "-1" = spell checking off (TortoiseGit's value for "disabled").
    public var projectLanguage = ""
    /// Project logo shown in the commit dialog, relative to the working-tree root.
    public var icon = ""

    public init() {}

    public init(values: [String: String]) {
        logMinSize = values[Key.logMinSize.rawValue].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        logWidthMarker = values[Key.logWidthMarker.rawValue].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        warnNoSignedOffBy = values[Key.warnNoSignedOffBy.rawValue].map(BugtraqConfig.parseBool) ?? false
        projectLanguage = values[Key.projectLanguage.rawValue] ?? ""
        icon = values[Key.icon.rawValue] ?? ""
    }

    /// Whether spell checking is switched off for this project.
    public var spellCheckingDisabled: Bool { projectLanguage == "-1" }
}
