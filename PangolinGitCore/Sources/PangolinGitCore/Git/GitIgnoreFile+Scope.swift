import Foundation

/// The Ignore dialog's file × scope choices (TortoiseGit's `CIgnoreDlg` and `CAppUtils::IgnoreFile`),
/// plus removing a rule again ("Remove from ignore list").
extension GitIgnoreFile {

    /// Where the pattern is written.
    public enum Location: Int, Sendable {
        /// `.gitignore` in the working-tree root.
        case rootGitignore = 0
        /// `.gitignore` in the folder that contains the item (one file per containing folder).
        case containingFolder = 1
        /// `$GIT_DIR/info/exclude`.
        case localExclude = 2
    }

    /// How far the pattern reaches.
    public enum Scope: Int, Sendable {
        /// Only the item's own folder (anchored with a leading `/`).
        case containingFolderOnly = 0
        /// The name (or extension) in that folder and every folder below / anywhere.
        case recursive = 1
    }

    /// Repository-relative folder whose `.gitignore` receives the pattern for `path` at `location`
    /// ("" = root); nil for `info/exclude`.
    public static func ignoreFileFolder(for path: String, location: Location) -> String? {
        switch location {
        case .rootGitignore: return ""
        case .localExclude: return nil
        case .containingFolder: return (trimSlash(path) as NSString).deletingLastPathComponent
        }
    }

    /// Pattern for `path` following TortoiseGit's rules: anchored `/dir/name` for "only in the
    /// containing folder" (just `/name` inside that folder's own `.gitignore`), bare `name` for
    /// "recursively". With `byExtension` the name becomes `*.ext` (nil for extensionless names).
    /// Folders (`isFolder` or a trailing `/`) get a trailing `/` so only directories match.
    public static func pattern(forPath path: String, isFolder: Bool = false, byExtension: Bool,
                               scope: Scope, location: Location) -> String? {
        let trimmed = trimSlash(path)
        guard !trimmed.isEmpty else { return nil }
        let folder = isFolder || path.hasSuffix("/")
        let name = (trimmed as NSString).lastPathComponent
        var last: String
        if byExtension {
            let ext = (name as NSString).pathExtension
            guard !ext.isEmpty else { return nil }
            last = "*." + escape(ext)
        } else {
            last = escape(name)
            if folder { last += "/" }
        }
        guard scope == .containingFolderOnly else { return last }
        let parent = (trimmed as NSString).deletingLastPathComponent
        if location != .containingFolder && !parent.isEmpty {
            return "/" + escape(parent) + "/" + last
        }
        return "/" + last
    }

    /// `.gitignore` inside the repository-relative `folder` ("" = root).
    public static func gitignoreURL(inFolder folder: String, repositoryRoot: PangolinPath) -> URL {
        let base = folder.isEmpty ? repositoryRoot.url : repositoryRoot.url.appendingPathComponent(folder, isDirectory: true)
        return base.appendingPathComponent(".gitignore")
    }

    /// Appends the patterns that are not yet in `file`, creating it (and its folder) when needed.
    public static func append(_ patterns: [String], toFile file: URL) throws {
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let updated = appending(patterns, to: existing)
        guard updated != existing else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Writes each path's pattern to the ignore file chosen by `location`; returns the files changed.
    @discardableResult
    public static func ignore(_ paths: [String], byExtension: Bool, scope: Scope, location: Location,
                              repositoryRoot: PangolinPath) throws -> [URL] {
        var byFile: [URL: [String]] = [:]
        var order: [URL] = []
        for path in paths {
            guard let pattern = pattern(forPath: path, byExtension: byExtension, scope: scope, location: location) else { continue }
            let file: URL
            if let folder = ignoreFileFolder(for: path, location: location) {
                file = gitignoreURL(inFolder: folder, repositoryRoot: repositoryRoot)
            } else {
                file = url(for: .localExclude, repositoryRoot: repositoryRoot)
            }
            if byFile[file] == nil { order.append(file) }
            byFile[file, default: []].append(pattern)
        }
        for file in order {
            try append(byFile[file] ?? [], toFile: file)
        }
        return order
    }

    /// Removes line `lineNumber` (1-based) from `file`; used by "Remove from ignore list".
    public static func removeLine(_ lineNumber: Int, from file: URL) throws {
        let content = try String(contentsOf: file, encoding: .utf8)
        try removingLine(lineNumber, from: content).write(to: file, atomically: true, encoding: .utf8)
    }

    /// `content` without line `lineNumber` (1-based); unchanged when out of range.
    static func removingLine(_ lineNumber: Int, from content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard lineNumber >= 1, lineNumber <= lines.count else { return content }
        // The empty string after a final newline is not a line of its own.
        if lineNumber == lines.count && lines[lineNumber - 1].isEmpty { return content }
        lines.remove(at: lineNumber - 1)
        return lines.joined(separator: "\n")
    }

    /// Negation that re-includes exactly this path, for when the matching rule is too broad to delete.
    public static func exceptionPattern(forPath path: String) -> String {
        "!" + exactPattern(forPath: trimSlash(path)) + (path.hasSuffix("/") ? "/" : "")
    }

    private static func trimSlash(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
