import Foundation

/// One annotated line of `git blame --line-porcelain` (TortoiseGit's `CGitBlameLogList` / `TortoiseGitBlameData`).
public struct GitBlameLine: Equatable, Sendable {
    public var finalLine: Int
    public var originalLine: Int
    public var hash: String
    public var author = ""
    public var authorMail = ""
    public var authorTime: TimeInterval = 0
    public var summary = ""
    /// Path of the line's file in `hash` (differs from the blamed path after a rename or copy).
    public var filename = ""
    /// The commit before `hash` and the file's path there (`previous` header), used by
    /// *Blame previous revision*; nil for a line added by a root/boundary commit.
    public var previousHash: String?
    public var previousFilename: String?
    public var isBoundary = false
    public var code = ""

    /// All-zero hash: the line is not committed yet.
    public var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}

public enum GitBlame {

    /// TortoiseGit's *Detect moved or copied lines* choices (`SettingsTBlame` / `-M`/`-C` levels).
    public enum MoveDetection: Int, CaseIterable, Sendable {
        case disabled = 0
        /// `-M`: lines moved within the file.
        case withinFile
        /// `-C`: also lines moved from files modified in the same commit.
        case fromModifiedFiles
        /// `-C -C`: also from files that existed in the commit that created the file.
        case fromExistingFiles
        /// `-C -C -C`: from any file in any commit (slow).
        case fromAllCommits

        public var title: String {
            switch self {
            case .disabled: return "Disabled"
            case .withinFile: return "Within the file (-M)"
            case .fromModifiedFiles: return "From modified files (-C)"
            case .fromExistingFiles: return "From existing files (-C -C)"
            case .fromAllCommits: return "From all commits (-C -C -C)"
            }
        }
    }

    /// Arguments for `git blame`. `threshold` is the minimum number of alphanumeric characters a
    /// moved/copied block must have (git's default is 20); 0 keeps git's default.
    public static func arguments(path: String, revision: String?, ignoreWhitespace: Bool,
                                 detection: MoveDetection, threshold: Int = 0,
                                 firstParent: Bool = false) -> [String] {
        var args = ["blame", "--line-porcelain"]
        if ignoreWhitespace { args.append("-w") }
        if firstParent { args.append("--first-parent") }
        let suffix = threshold > 0 ? String(threshold) : ""
        switch detection {
        case .disabled: break
        case .withinFile: args.append("-M\(suffix)")
        case .fromModifiedFiles: args.append("-C\(suffix)")
        case .fromExistingFiles: args += ["-C\(suffix)", "-C"]
        case .fromAllCommits: args += ["-C\(suffix)", "-C", "-C"]
        }
        if let revision, !revision.isEmpty { args.append(revision) }
        args += ["--", path]
        return args
    }

    /// Parses `--line-porcelain` output (every line carries its full header).
    public static func parse(linePorcelain output: String) -> [GitBlameLine] {
        var result: [GitBlameLine] = []
        var current: GitBlameLine?
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("\t") {
                if var entry = current {
                    entry.code = String(line.dropFirst())
                    result.append(entry)
                }
                current = nil
                continue
            }
            if current == nil {
                if let header = parseHeader(line) {
                    current = GitBlameLine(finalLine: header.final, originalLine: header.original, hash: header.hash)
                }
                continue
            }
            let (key, value) = split(line)
            switch key {
            case "author": current?.author = value
            case "author-mail": current?.authorMail = value.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            case "author-time": current?.authorTime = TimeInterval(value) ?? 0
            case "summary": current?.summary = value
            case "filename": current?.filename = value
            case "boundary": current?.isBoundary = true
            case "previous":
                let (hash, file) = split(value)
                current?.previousHash = hash
                current?.previousFilename = file
            default: break
            }
        }
        return result
    }

    /// `<40 or 64 hex> <orig line> <final line>[ <count>]`
    static func parseHeader(_ line: String) -> (hash: String, original: Int, final: Int)? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == 3 || tokens.count == 4 else { return nil }
        let hash = tokens[0]
        guard hash.count == 40 || hash.count == 64, hash.allSatisfy(\.isHexDigit),
              let original = Int(tokens[1]), let final = Int(tokens[2]) else { return nil }
        return (String(hash), original, final)
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }

    /// Index ranges of consecutive lines that come from the same commit (TortoiseGit's
    /// *Next / Previous block* navigation moves between these).
    public static func blockStarts(_ lines: [GitBlameLine]) -> [Int] {
        lines.indices.filter { $0 == 0 || lines[$0].hash != lines[$0 - 1].hash }
    }
}
