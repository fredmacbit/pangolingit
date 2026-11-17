import Foundation

/// Git patch and unified diff parser.
/// Equivalent to TortoiseGit's `CGitPatch` (`src/Git/GitPatch.cpp`).
public struct GitPatchHunk: Sendable {
    public let header: String
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [String]
}

public struct GitPatchFile: Sendable {
    public let oldPath: String?
    public let newPath: String?
    public let hunks: [GitPatchHunk]
}

public enum GitPatch {
    public static func parse(unifiedDiff: String) -> [GitPatchFile] {
        var files: [GitPatchFile] = []

        var oldPath: String?
        var newPath: String?
        var hunks: [GitPatchHunk] = []

        var hunkHeader = ""
        var hunkLines: [String] = []
        var hunkRange = (oldStart: 0, oldCount: 0, newStart: 0, newCount: 0)
        // Lines still expected for the current hunk; while positive, "--- " is content, not a file header.
        var oldRemaining = 0
        var newRemaining = 0

        func flushHunk() {
            guard !hunkHeader.isEmpty else { return }
            hunks.append(GitPatchHunk(
                header: hunkHeader,
                oldStart: hunkRange.oldStart,
                oldCount: hunkRange.oldCount,
                newStart: hunkRange.newStart,
                newCount: hunkRange.newCount,
                lines: hunkLines
            ))
            hunkHeader = ""
            hunkLines.removeAll()
        }

        func flushFile() {
            flushHunk()
            if oldPath != nil || newPath != nil {
                files.append(GitPatchFile(oldPath: oldPath, newPath: newPath, hunks: hunks))
            }
            oldPath = nil
            newPath = nil
            hunks.removeAll()
        }

        for line in unifiedDiff.components(separatedBy: "\n") {
            if oldRemaining > 0 || newRemaining > 0 {
                switch line.first {
                case "+": newRemaining -= 1
                case "-": oldRemaining -= 1
                case "\\": break // "\ No newline at end of file"
                default: oldRemaining -= 1; newRemaining -= 1
                }
                hunkLines.append(line)
                continue
            }

            if line.hasPrefix("--- ") {
                flushFile()
                oldPath = stripPrefix(String(line.dropFirst(4)))
            } else if line.hasPrefix("+++ ") {
                newPath = stripPrefix(String(line.dropFirst(4)))
            } else if line.hasPrefix("@@ ") {
                flushHunk()
                hunkHeader = line
                hunkRange = parseHeader(line)
                oldRemaining = hunkRange.oldCount
                newRemaining = hunkRange.newCount
            } else if line.hasPrefix("\\"), !hunkHeader.isEmpty {
                hunkLines.append(line)
            }
        }
        flushFile()
        return files
    }

    /// Drops the `a/` / `b/` prefixes and trailing tab-separated timestamps; `/dev/null` becomes nil.
    private static func stripPrefix(_ raw: String) -> String? {
        let path = raw.components(separatedBy: "\t")[0]
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    /// Parses `@@ -oldStart[,oldCount] +newStart[,newCount] @@`.
    private static func parseHeader(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        func range(_ token: Substring?) -> (Int, Int) {
            guard let token = token else { return (0, 0) }
            let parts = token.dropFirst().split(separator: ",")
            let start = Int(parts.first ?? "") ?? 0
            let count = parts.count > 1 ? (Int(parts[1]) ?? 0) : 1
            return (start, count)
        }
        let tokens = header.split(separator: " ")
        let old = range(tokens.first(where: { $0.hasPrefix("-") }))
        let new = range(tokens.first(where: { $0.hasPrefix("+") }))
        return (old.0, old.1, new.0, new.1)
    }
}
