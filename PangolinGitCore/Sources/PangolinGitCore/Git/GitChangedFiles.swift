import Foundation

/// A file changed by a commit, as listed in the Log's lower pane (TortoiseGit's `CTGitPath` with
/// `m_Action`, `m_StatAdd`, `m_StatDel`).
public struct GitChangedFile: Hashable, Sendable {
    /// Status letter: A, M, D, R, C, T, U.
    public let status: String
    public let path: String
    /// Source path of a rename or copy.
    public let oldPath: String?
    /// Lines added / removed; nil for binaries.
    public var added: Int?
    public var removed: Int?
    /// True for a submodule (gitlink, mode 160000).
    public let isSubmodule: Bool

    public init(status: String, path: String, oldPath: String? = nil, added: Int? = nil, removed: Int? = nil, isSubmodule: Bool = false) {
        self.status = status
        self.path = path
        self.oldPath = oldPath
        self.added = added
        self.removed = removed
        self.isSubmodule = isSubmodule
    }

    public var isBinary: Bool { added == nil && removed == nil }
}

public enum GitChangedFilesParser {
    /// Arguments listing what `revision` changed against `parent` (nil = the empty tree, for a root commit).
    public static func rawArguments(parent: String?, revision: String) -> [String] {
        ["diff", "--raw", "-z", "-M", "--no-abbrev", parent ?? GitRepository.emptyTreeHash, revision]
    }

    public static func numstatArguments(parent: String?, revision: String) -> [String] {
        ["diff", "--numstat", "-z", "-M", parent ?? GitRepository.emptyTreeHash, revision]
    }

    /// Parses `git diff --raw -z` (`:old-mode new-mode old-sha new-sha STATUS\0path\0[new-path\0]`)
    /// and merges the line counts of `git diff --numstat -z`.
    public static func parse(raw: String, numstat: String) -> [GitChangedFile] {
        var files: [GitChangedFile] = []
        let fields = raw.components(separatedBy: "\0")
        var i = 0
        while i < fields.count {
            let header = fields[i]
            guard header.hasPrefix(":") else { i += 1; continue }
            let parts = header.dropFirst().split(separator: " ").map(String.init)
            guard parts.count >= 5 else { i += 1; continue }
            let status = String(parts[4].prefix(1))
            let isSubmodule = parts[0] == "160000" || parts[1] == "160000"
            if (status == "R" || status == "C"), i + 2 < fields.count {
                files.append(GitChangedFile(status: status, path: fields[i + 2], oldPath: fields[i + 1], isSubmodule: isSubmodule))
                i += 3
            } else if i + 1 < fields.count {
                files.append(GitChangedFile(status: status, path: fields[i + 1], isSubmodule: isSubmodule))
                i += 2
            } else {
                break
            }
        }
        let counts = parseNumstat(numstat)
        for index in files.indices {
            if let count = counts[files[index].path] {
                files[index].added = count.added
                files[index].removed = count.removed
            }
        }
        return files
    }

    /// `added\tremoved\tpath\0`, or for renames `added\tremoved\t\0old\0new\0`; `-` for binaries.
    static func parseNumstat(_ output: String) -> [String: (added: Int?, removed: Int?)] {
        var result: [String: (added: Int?, removed: Int?)] = [:]
        let fields = output.components(separatedBy: "\0")
        var i = 0
        while i < fields.count {
            let parts = fields[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { i += 1; continue }
            let added = Int(parts[0]), removed = Int(parts[1])
            let path = parts[2]
            if path.isEmpty, i + 2 < fields.count {
                result[fields[i + 2]] = (added, removed)
                i += 3
            } else {
                result[path] = (added, removed)
                i += 1
            }
        }
        return result
    }
}
