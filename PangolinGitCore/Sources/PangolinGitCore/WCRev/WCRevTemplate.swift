import Foundation

/// Working-tree facts that `pangolin-wcrev` substitutes into a template
/// (TortoiseGit's `GitWCRev_t`, `src/GitWCRev/status.h`).
public struct WCRevInfo: Equatable, Sendable, Codable {
    /// Full HEAD commit id; forty zeros on an unborn branch.
    public var headHash: String = String(repeating: "0", count: 40)
    /// Author date of HEAD (nil on an unborn branch).
    public var headDate: Date?
    public var headAuthor: String = ""
    public var headEmail: String = ""
    /// Current branch, or the commit id when HEAD is detached.
    public var branch: String = ""
    public var remoteURL: String = ""
    /// Number of first-parent commits reachable from HEAD.
    public var logCount: Int = 0
    public var isUnborn = false
    public var isTagged = false
    /// Whether the given path is versioned (the working-tree root always is).
    public var isInGit = false
    public var hasModifications = false
    public var hasUnversioned = false
    public var hasSubmodule = false
    /// A submodule's checked-out commit differs from the one recorded in the superproject.
    public var hasSubmoduleNewCommits = false
    public var hasSubmoduleModifications = false
    public var hasSubmoduleUnversioned = false

    public init() {}
}

/// Command-line options of `pangolin-wcrev`, matching `GitWCRev.exe`
/// (`GitWCRev Path [SrcVersionFile DstVersionFile] [-mMuUdqsF]`).
public struct WCRevOptions: Equatable, Sendable {
    public var workingTreePath = ""
    public var templatePath: String?
    public var outputPath: String?
    /// -m / -M: fail with `ERR_GIT_MODS` when there are modifications (-M: also in submodules).
    public var errorOnModifications = false
    /// -u / -U: fail with `ERR_GIT_UNVER` when there are unversioned files.
    public var errorOnUnversioned = false
    /// Set by the uppercase forms: submodule state counts too.
    public var recursive = false
    /// -d: do nothing (exit 9) when the output file already exists.
    public var failIfOutputExists = false
    /// -q: no status on stdout.
    public var quiet = false
    /// -s: do not look into submodules.
    public var noSubmodules = false
    /// -F: ignore `.gitwcrevignore`.
    public var ignoreIgnoreFile = false
    /// -f: write the output even when it is unchanged (PangolinGit addition; GitWCRev never rewrites an identical file).
    public var force = false
    /// --json: print the collected facts as JSON (macOS replacement for GitWCRev's COM object).
    public var json = false

    public init() {}

    /// Parses `argv` without the program name. Returns nil for a syntax error (exit code 1).
    /// As in GitWCRev, switches are given in one argument (`-mq`), but separate ones are accepted too.
    public static func parse(_ arguments: [String]) -> WCRevOptions? {
        var options = WCRevOptions()
        var positional: [String] = []
        for argument in arguments {
            if argument == "--json" {
                options.json = true
            } else if argument.hasPrefix("-"), argument.count > 1 {
                for flag in argument.dropFirst() {
                    switch flag {
                    case "m": options.errorOnModifications = true
                    case "M": options.errorOnModifications = true; options.recursive = true
                    case "u": options.errorOnUnversioned = true
                    case "U": options.errorOnUnversioned = true; options.recursive = true
                    case "d": options.failIfOutputExists = true
                    case "q": options.quiet = true
                    case "s": options.noSubmodules = true
                    case "F": options.ignoreIgnoreFile = true
                    case "f": options.force = true
                    case "e": break // console encoding switch; UTF-8 always on macOS
                    default: return nil
                    }
                }
            } else {
                positional.append(argument)
            }
        }
        switch positional.count {
        case 1:
            break
        case 3:
            options.templatePath = positional[1]
            options.outputPath = positional[2]
        default:
            return nil
        }
        options.workingTreePath = positional[0]
        return options
    }
}

/// GitWCRev's documented exit codes (`src/GitWCRev/status.h`).
public enum WCRevExitCode: Int32, Sendable {
    case ok = 0
    case syntax = 1
    case fileNotFound = 2
    case openFailed = 3
    case readWriteFailed = 5
    case gitError = 6
    case modificationsFound = 7
    case outputExists = 9
    case notAWorkingTree = 10
    case unversionedFound = 11
}

/// Keyword substitution of `$WCxxx$` placeholders, mirroring `GitWCRev.cpp`.
public enum WCRevTemplate {

    /// Replaces every keyword in `template`. `now` and `timeZone` are injectable for tests.
    public static func substitute(_ template: String, info: WCRevInfo, now: Date = Date(),
                                  timeZone: TimeZone = .current) -> String {
        var output = ""
        var rest = Substring(template)
        while let dollar = rest.firstIndex(of: "$") {
            output += rest[..<dollar]
            let candidate = rest[dollar...]
            if let (replacement, consumed) = expand(candidate, info: info, now: now, timeZone: timeZone) {
                output += replacement
                rest = candidate[consumed...]
            } else {
                output.append("$")
                rest = candidate.dropFirst()
            }
        }
        output += rest
        return output
    }

    /// Expands one keyword at the start of `text` (which begins with `$`). Returns the replacement
    /// and the index just past the keyword, or nil when `text` does not start with a known keyword.
    private static func expand(_ text: Substring, info: WCRevInfo, now: Date,
                               timeZone: TimeZone) -> (String, Substring.Index)? {
        let utc = TimeZone(identifier: "UTC")!

        // Plain keywords: $NAME$
        let simple: [(String, () -> String)] = [
            ("$WCREV$", { info.headHash }),
            ("$WCHASH$", { info.headHash }),
            ("$WCDATE$", { defaultDate(info.headDate, timeZone) }),
            ("$WCDATEUTC$", { defaultDate(info.headDate, utc) }),
            ("$WCNOW$", { defaultDate(now, timeZone) }),
            ("$WCNOWUTC$", { defaultDate(now, utc) }),
            ("$WCLOGCOUNT$", { String(info.logCount) }),
            ("$WCBRANCH$", { info.branch }),
            ("$WCURL$", { info.remoteURL }),
            ("$WCAUTHOR$", { info.headAuthor }),
            ("$WCEMAIL$", { info.headEmail })
        ]
        for (keyword, value) in simple where text.hasPrefix(keyword) {
            return (value(), text.index(text.startIndex, offsetBy: keyword.count))
        }

        // Parameterised keywords: $NAME<sep>argument$
        func argument(after prefix: String) -> (String, Substring.Index)? {
            guard text.hasPrefix(prefix) else { return nil }
            let start = text.index(text.startIndex, offsetBy: prefix.count)
            guard let end = text[start...].firstIndex(of: "$") else { return nil }
            return (String(text[start..<end]), text.index(after: end))
        }

        if let (length, end) = argument(after: "$WCREV=") {
            let count = parseNumber(length) ?? info.headHash.count
            return (String(info.headHash.prefix(count)), end)
        }
        for (prefix, date, zone) in [("$WCDATE=", info.headDate, timeZone), ("$WCDATEUTC=", info.headDate, utc),
                                     ("$WCNOW=", Optional(now), timeZone), ("$WCNOWUTC=", Optional(now), utc)] {
            if let (format, end) = argument(after: prefix) {
                return (strftime(format, date: date ?? Date(timeIntervalSince1970: 0), timeZone: zone), end)
            }
        }
        for (prefix, operation) in [("$WCLOGCOUNT&", { (a: Int, b: Int) in a & b }),
                                    ("$WCLOGCOUNT+", { (a: Int, b: Int) in a + b }),
                                    ("$WCLOGCOUNT-", { (a: Int, b: Int) in a - b })] {
            if let (operand, end) = argument(after: prefix) {
                return (String(operation(info.logCount, parseNumber(operand) ?? 0)), end)
            }
        }

        // Conditionals: $NAME?TrueText:FalseText$ — split at the first ':' like GitWCRev.
        let conditions: [(String, Bool)] = [
            ("$WCMODS?", info.hasModifications || info.hasSubmoduleNewCommits),
            ("$WCFILEMODS?", info.hasModifications),
            ("$WCUNVER?", info.hasUnversioned),
            ("$WCISTAGGED?", info.isTagged),
            ("$WCINGIT?", info.isInGit),
            ("$WCSUBMODULE?", info.hasSubmodule),
            ("$WCSUBMODULEUP2DATE?", !info.hasSubmoduleNewCommits),
            ("$WCMODSINSUBMODULE?", info.hasSubmoduleModifications),
            ("$WCUNVERINSUBMODULE?", info.hasSubmoduleUnversioned),
            ("$WCUNVERFULL?", info.hasUnversioned || info.hasSubmoduleUnversioned),
            ("$WCMODSFULL?", info.hasModifications || info.hasSubmoduleModifications || info.hasSubmoduleUnversioned)
        ]
        for (prefix, value) in conditions {
            guard let (body, end) = argument(after: prefix), let colon = body.firstIndex(of: ":") else { continue }
            let replacement = value ? body[..<colon] : body[body.index(after: colon)...]
            return (String(replacement), end)
        }
        return nil
    }

    /// GitWCRev's default date format: `yyyy/mm/dd hh:mm:ss`.
    static func defaultDate(_ date: Date?, _ zone: TimeZone) -> String {
        guard let date else { return "0000/00/00 00:00:00" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// C `strftime`, as GitWCRev uses for `$WCDATE=fmt$`.
    static func strftime(_ format: String, date: Date, timeZone: TimeZone) -> String {
        guard !format.isEmpty else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        var tmValue = tm()
        tmValue.tm_year = Int32((parts.year ?? 1970) - 1900)
        tmValue.tm_mon = Int32((parts.month ?? 1) - 1)
        tmValue.tm_mday = Int32(parts.day ?? 1)
        tmValue.tm_hour = Int32(parts.hour ?? 0)
        tmValue.tm_min = Int32(parts.minute ?? 0)
        tmValue.tm_sec = Int32(parts.second ?? 0)
        tmValue.tm_wday = Int32((parts.weekday ?? 1) - 1)
        tmValue.tm_yday = Int32((calendar.ordinality(of: .day, in: .year, for: date) ?? 1) - 1)
        tmValue.tm_gmtoff = timeZone.secondsFromGMT(for: date)
        var buffer = [CChar](repeating: 0, count: 1024)
        let written = Darwin.strftime(&buffer, buffer.count, format, &tmValue)
        guard written > 0 else { return "Invalid Time Format Specified" }
        return String(cString: buffer)
    }

    /// `strtoul(…, 0)`: decimal, `0x` hex or leading-zero octal.
    static func parseNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") { return Int(trimmed.dropFirst(2), radix: 16) }
        if trimmed.count > 1, trimmed.hasPrefix("0") { return Int(trimmed.dropFirst(), radix: 8) }
        return Int(trimmed)
    }
}

/// Collects `WCRevInfo` with the git command line (GitWCRev uses libgit2; `status.cpp`).
public enum WCRevCollector {

    public enum Failure: Error, Equatable {
        case notAWorkingTree
        case gitFailed(String)
    }

    /// Reads the working tree containing `path`.
    public static func collect(path: String, options: WCRevOptions, runner: GitCLIRunner = GitCLIRunner()) throws -> WCRevInfo {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
        let directory = PangolinPath(isDirectory.boolValue ? target.path : target.deletingLastPathComponent().path)

        func git(_ arguments: [String]) throws -> String {
            let result = try runner.runSync(arguments: arguments, workingDirectory: directory)
            guard result.isSuccess else {
                throw Failure.gitFailed(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return result.standardOutput
        }
        func gitOptional(_ arguments: [String]) -> String? {
            guard let result = try? runner.runSync(arguments: arguments, workingDirectory: directory), result.isSuccess else { return nil }
            return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard gitOptional(["rev-parse", "--is-inside-work-tree"]) == "true",
              let root = gitOptional(["rev-parse", "--show-toplevel"]) else {
            throw Failure.notAWorkingTree
        }

        var info = WCRevInfo()
        if let head = gitOptional(["rev-parse", "--verify", "-q", "HEAD"]), !head.isEmpty {
            info.headHash = head
            let meta = try git(["log", "-1", "--format=%at%n%aN%n%aE"]).components(separatedBy: "\n")
            if let seconds = TimeInterval(meta.first ?? "") { info.headDate = Date(timeIntervalSince1970: seconds) }
            info.headAuthor = meta.count > 1 ? meta[1] : ""
            info.headEmail = meta.count > 2 ? meta[2] : ""
            info.logCount = Int(try git(["rev-list", "--first-parent", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            info.isTagged = !(gitOptional(["tag", "--points-at", "HEAD"]) ?? "").isEmpty
            info.branch = gitOptional(["symbolic-ref", "--short", "-q", "HEAD"]).flatMap { $0.isEmpty ? nil : $0 } ?? head
        } else {
            info.isUnborn = true
            info.branch = gitOptional(["symbolic-ref", "--short", "-q", "HEAD"]) ?? ""
        }
        let upstreamRemote = gitOptional(["config", "--get", "branch.\(info.branch).remote"]).flatMap { $0.isEmpty ? nil : $0 } ?? "origin"
        info.remoteURL = gitOptional(["config", "--get", "remote.\(upstreamRemote).url"]) ?? ""

        // Status of the path (or the whole tree), minus `.gitwcrevignore` patterns.
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let relative = relativePath(of: target, inside: rootURL)
        var status = ["status", "--porcelain=v2", "-z", "--untracked-files=all"]
        status.append(options.noSubmodules ? "--ignore-submodules=all" : "--ignore-submodules=none")
        var pathspec: [String] = []
        if !relative.isEmpty { pathspec.append(":(top)" + relative) }
        if !options.ignoreIgnoreFile {
            let patterns = ignorePatterns(fileAt: rootURL.appendingPathComponent(".gitwcrevignore"))
            if !patterns.isEmpty {
                if pathspec.isEmpty { pathspec.append(":(top)*") }
                pathspec += patterns.map { ":(top,exclude)" + $0 }
            }
        }
        if !pathspec.isEmpty { status += ["--"] + pathspec }
        let entries = try git(status)
        apply(statusOutput: entries, to: &info)

        if relative.isEmpty {
            info.isInGit = true
        } else if isDirectory.boolValue {
            info.isInGit = false // directories are not versioned in git
        } else {
            info.isInGit = !(gitOptional(["ls-files", "--error-unmatch", "--", ":(top)" + relative]) ?? "").isEmpty
                && !(entries.split(separator: "\0").contains { $0.hasPrefix("? ") || $0.hasPrefix("1 A") })
        }
        return info
    }

    /// Path of `url` relative to `root`, empty for the root itself.
    static func relativePath(of url: URL, inside root: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else { return "" }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Non-empty lines of `.gitwcrevignore`, each a pathspec relative to the working-tree root.
    static func ignorePatterns(fileAt url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Folds `git status --porcelain=v2 -z` records into the modification / submodule flags.
    public static func apply(statusOutput: String, to info: inout WCRevInfo) {
        var records = statusOutput.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let record = records.next() {
            let fields = record.split(separator: " ", omittingEmptySubsequences: false)
            guard let kind = fields.first else { continue }
            switch kind {
            case "?":
                info.hasUnversioned = true
            case "1", "2", "u":
                if kind == "2" { _ = records.next() } // rename records carry the original path next
                let submoduleField = fields.count > 2 ? fields[2] : "N..."
                if submoduleField.hasPrefix("S") {
                    let flags = Array(submoduleField)
                    info.hasSubmodule = true
                    if flags.count == 4 {
                        if flags[1] == "C" { info.hasSubmoduleNewCommits = true }
                        else if flags[2] == "M" { info.hasSubmoduleModifications = true }
                        else if flags[3] == "U" { info.hasSubmoduleUnversioned = true }
                    }
                    continue
                }
                let xy = fields.count > 1 ? Array(fields[1]) : []
                // A newly added file counts as unversioned, like GIT_STATUS_INDEX_NEW in GitWCRev.
                if xy.count == 2, xy[0] == "A", xy[1] == "." {
                    info.hasUnversioned = true
                } else {
                    info.hasModifications = true
                }
            default:
                continue
            }
        }
    }
}
