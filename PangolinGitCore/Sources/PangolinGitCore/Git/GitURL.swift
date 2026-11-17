import Foundation

/// Helpers for remote repository URLs (clone dialog defaults, TortoiseGit's `CCloneDlg` URL handling).
public enum GitURL {

    /// Folder name git itself would pick for a clone of `url`: the last path component without
    /// `.git` (`https://host/user/repo.git` → `repo`, `git@host:user/repo` → `repo`).
    public static func repositoryName(from url: String) -> String? {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "\\" }).last else { return nil }
        let name = String(last)
        return name.isEmpty || name.contains("@") ? nil : name
    }

    /// Whether `text` looks like something `git clone` accepts as a remote URL.
    public static func looksLikeRemoteURL(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isNewline), !value.contains(" ") else { return false }
        let schemes = ["https://", "http://", "ssh://", "git://", "file://", "git+ssh://", "ssh+git://"]
        if schemes.contains(where: { value.lowercased().hasPrefix($0) }) { return true }
        // scp-like syntax: user@host:path
        if let at = value.firstIndex(of: "@"), let colon = value.firstIndex(of: ":"), at < colon { return true }
        return false
    }
}
