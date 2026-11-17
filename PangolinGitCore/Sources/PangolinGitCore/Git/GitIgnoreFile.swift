import Foundation

/// Writes patterns to a repository's `.gitignore` or its local `info/exclude`
/// (the storage half of TortoiseGit's `CIgnoreDlg` / "Add to ignore list").
public enum GitIgnoreFile {

    public enum Target {
        /// `.gitignore` in the working-tree root; shared through commits.
        case gitignore
        /// `$GIT_DIR/info/exclude`; local to this clone.
        case localExclude
    }

    /// Location of the ignore file for `target`. `info/exclude` is resolved through git so worktrees
    /// and custom `GIT_DIR` layouts work.
    public static func url(for target: Target, repositoryRoot: PangolinPath) -> URL {
        switch target {
        case .gitignore:
            return repositoryRoot.url.appendingPathComponent(".gitignore")
        case .localExclude:
            if let out = try? GitCLIRunner.run(arguments: ["rev-parse", "--git-path", "info/exclude"], workingDirectory: repositoryRoot) {
                let path = out.trimmingCharacters(in: .newlines)
                if !path.isEmpty {
                    // A relative result is relative to the repository root
                    return path.hasPrefix("/") ? URL(fileURLWithPath: path) : repositoryRoot.url.appendingPathComponent(path)
                }
            }
            return repositoryRoot.url.appendingPathComponent(".git/info/exclude")
        }
    }

    /// Appends the patterns that are not already present, one per line.
    public static func append(_ patterns: [String], to target: Target, repositoryRoot: PangolinPath) throws {
        let file = url(for: target, repositoryRoot: repositoryRoot)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let updated = appending(patterns, to: existing)
        guard updated != existing else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: file, atomically: true, encoding: .utf8)
    }

    /// `content` with the new patterns added at the end; duplicates and blank patterns are skipped.
    static func appending(_ patterns: [String], to content: String) -> String {
        var present = Set(content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        var result = content
        for pattern in patterns where !pattern.isEmpty && !present.contains(pattern) {
            if !result.isEmpty && !result.hasSuffix("\n") {
                result += "\n"
            }
            result += pattern + "\n"
            present.insert(pattern)
        }
        return result
    }

    // MARK: - Pattern builders

    /// Matches exactly this repository-relative path (anchored to the root).
    public static func exactPattern(forPath relativePath: String) -> String {
        "/" + escape(relativePath)
    }

    /// Matches every file with this extension, or nil for extensionless names. With `folder`, only
    /// inside that repository-relative folder (and below); without it, anywhere in the repository.
    public static func extensionPattern(forPath relativePath: String, inFolder folder: String? = nil) -> String? {
        let ext = (relativePath as NSString).pathExtension
        return ext.isEmpty ? nil : folderPrefix(folder) + "*." + escape(ext)
    }

    /// Matches every file with this file's name. With `folder`, only inside that folder (and below);
    /// without it, anywhere in the repository.
    public static func namePattern(forPath relativePath: String, inFolder folder: String? = nil) -> String {
        folderPrefix(folder) + escape((relativePath as NSString).lastPathComponent)
    }

    /// `/folder/**/` for a non-empty folder, "" (unanchored, matches at any depth) otherwise.
    private static func folderPrefix(_ folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return "" }
        let trimmed = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return "/" + escape(trimmed) + "/**/"
    }

    /// Matches this repository-relative folder and everything below it.
    public static func folderPattern(forFolder relativeFolder: String) -> String {
        let trimmed = relativeFolder.hasSuffix("/") ? String(relativeFolder.dropLast()) : relativeFolder
        return "/" + escape(trimmed) + "/"
    }

    /// Escapes gitignore glob characters, a leading `#`/`!` and trailing spaces so a literal path matches itself.
    public static func escape(_ path: String) -> String {
        var out = ""
        for ch in path {
            if ch == "\\" || ch == "[" || ch == "*" || ch == "?" {
                out.append("\\")
            }
            out.append(ch)
        }
        if out.hasPrefix("#") || out.hasPrefix("!") {
            out = "\\" + out
        }
        if out.hasSuffix(" ") {
            out = String(out.dropLast()) + "\\ "
        }
        return out
    }
}
