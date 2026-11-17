import Foundation

/// One Git LFS lock (`git lfs locks --json`), shown by the LFS Locks dialog
/// (TortoiseGit's `CLFSLocksDlg` / `GITSLC_SHOWLFSLOCKS` status-list mode).
public struct LFSLock: Equatable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let owner: String
    public let lockedAt: Date?

    public init(id: String, path: String, owner: String, lockedAt: Date? = nil) {
        self.id = id
        self.path = path
        self.owner = owner
        self.lockedAt = lockedAt
    }
}

/// Git LFS helpers: lock listing/parsing, lockable patterns and the install check.
public enum GitLFS {

    public enum LockSource: Sendable {
        /// Ask the LFS server (`git lfs locks`).
        case remote
        /// Locks this clone has cached (`git lfs locks --local`); works offline.
        case local
    }

    /// Parses `git lfs locks --json`.
    public static func parseLocksJSON(_ data: Data) -> [LFSLock]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        return array.compactMap { entry in
            guard let path = entry["path"] as? String else { return nil }
            let id = (entry["id"] as? String) ?? (entry["id"] as? NSNumber)?.stringValue ?? ""
            let owner = (entry["owner"] as? [String: Any])?["name"] as? String ?? ""
            let stamp = entry["locked_at"] as? String
            let date = stamp.flatMap { isoFractional.date(from: $0) ?? iso.date(from: $0) }
            return LFSLock(id: id, path: path, owner: owner, lockedAt: date)
        }
    }

    /// Parses the plain `git lfs locks` table (`<path>\t<owner>\tID:<id>`), for old git-lfs without `--json`.
    public static func parseLocksTable(_ output: String) -> [LFSLock] {
        // Columns are separated by a tab or padded with two or more spaces; a single space belongs to a value.
        let separator = try? NSRegularExpression(pattern: "\\t+|\\s{2,}")
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line).trimmingCharacters(in: .whitespaces)
            let marked = separator?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                             withTemplate: "\u{1}") ?? text
            let fields = marked.split(separator: "\u{1}").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3, let id = fields.last, id.hasPrefix("ID:") else { return nil }
            return LFSLock(id: String(id.dropFirst(3)), path: fields[0], owner: fields[1..<(fields.count - 1)].joined(separator: " "))
        }
    }

    /// Lists locks. Throws when git-lfs is missing or the server cannot be reached; the error text
    /// is git-lfs's own message (shown in the dialog instead of a generic "no locks").
    public static func locks(in repository: PangolinPath, source: LockSource) async throws -> [LFSLock] {
        var arguments = ["lfs", "locks", "--json"]
        if source == .local { arguments.append("--local") }
        let output = try await GitCLIRunner.runAsync(arguments: arguments, workingDirectory: repository)
        return parseLocksJSON(Data(output.utf8)) ?? parseLocksTable(output)
    }

    /// Whether `git lfs` is available (`git lfs version` succeeds).
    public static func isInstalled() async -> Bool {
        (try? await GitCLIRunner.runAsync(arguments: ["lfs", "version"])) != nil
    }

    /// Whether this repository has the LFS filters installed (`git lfs install` was run globally or locally).
    public static func isInitialized(in repository: PangolinPath) async -> Bool {
        let value = try? await GitCLIRunner.runAsync(arguments: ["config", "--get", "filter.lfs.process"], workingDirectory: repository)
        return !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Lockable patterns from `.gitattributes` (`<pattern> … lockable`), i.e. what
    /// `git lfs track --lockable <pattern>` writes.
    public static func lockablePatterns(gitattributes: String) -> [String] {
        gitattributes.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return nil }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields.dropFirst().contains("lockable") else { return nil }
            return String(fields[0])
        }
    }

    /// The git command lines that lock or unlock `paths` (one `git lfs` call per path, like
    /// TortoiseGit's `LFSSetLockedProgressCommand`).
    public static func setLockedCommands(paths: [String], lock: Bool, force: Bool) -> [[String]] {
        paths.map { path in
            var arguments = ["lfs", lock ? "lock" : "unlock"]
            if force && !lock { arguments.append("--force") }
            return arguments + ["--", path]
        }
    }

    /// Unlock-by-id commands for rows of the locks dialog.
    public static func unlockByIDCommands(ids: [String], force: Bool) -> [[String]] {
        ids.map { id in ["lfs", "unlock", "--id", id] + (force ? ["--force"] : []) }
    }
}
