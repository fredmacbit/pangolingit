import Foundation

/// Commit-message helpers of TortoiseGit's commit dialog (`CommitDlg.cpp`, `ProjectProperties.cpp`):
/// sign-off trailers, cleanup, template comparison, conflict hints and the `*bold*` markup.
public enum CommitMessage {

    // MARK: - Identity and Signed-off-by

    /// Parses `git var GIT_COMMITTER_IDENT` output (`Name <mail> 1700000000 +0100`) into name and email.
    public static func identity(fromIdent ident: String) -> (name: String, email: String)? {
        let line = ident.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = line.firstIndex(of: "<"), let close = line[open...].firstIndex(of: ">") else { return nil }
        let name = line[..<open].trimmingCharacters(in: .whitespaces)
        let email = String(line[line.index(after: open)..<close])
        return (name, email)
    }

    /// `Signed-off-by: Name <email>` (`CCommitDlg::GetSignedOffByLine`).
    public static func signOffLine(name: String, email: String) -> String {
        "Signed-off-by: \(name) <\(email)>"
    }

    /// Appends `line` like `CCommitDlg::OnBnClickedSignOff`: nothing when it is already present;
    /// directly below an existing `…-by:` trailer block, otherwise separated by a blank line.
    public static func appendingSignOff(_ message: String, line: String) -> String {
        guard !message.contains(line) else { return message }
        let trimmed = trimmingTrailingWhitespace(message)
        guard !trimmed.isEmpty else { return line + "\n" }
        let lastLine = trimmed.components(separatedBy: "\n").last ?? ""
        let followsTrailer = lastLine.range(of: "^[A-Za-z0-9-]+-by: ", options: .regularExpression) != nil
        return trimmed + (followsTrailer ? "\n" : "\n\n") + line + "\n"
    }

    // MARK: - Cleanup

    /// What gets committed: comment lines (`<commentChar>` alone or followed by a space, so `#123`
    /// issue references survive) are dropped, trailing whitespace is removed from every line, runs
    /// of blank lines collapse to one and leading/trailing blank lines go. TortoiseGit's
    /// `StripCommentedLines` plus git's `--cleanup=whitespace`.
    public static func cleanup(_ message: String, commentChar: Character = "#") -> String {
        let normalised = message.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = []
        for raw in normalised.components(separatedBy: "\n") {
            if raw.first == commentChar, raw.count == 1 || raw.dropFirst().first == " " {
                continue
            }
            let line = trimmingTrailingWhitespace(raw)
            if line.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// True when the user left `commit.template` untouched (TortoiseGit's "did not edit template" warning).
    public static func isUnchangedTemplate(message: String, template: String, commentChar: Character = "#") -> Bool {
        let template = cleanup(template, commentChar: commentChar)
        return !template.isEmpty && cleanup(message, commentChar: commentChar) == template
    }

    /// Lines that look like unresolved merge conflict markers (`<<<<<<< ` … `>>>>>>> `).
    public static func containsConflictMarkers(_ text: String) -> Bool {
        var sawStart = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("<<<<<<< ") || line == "<<<<<<<" {
                sawStart = true
            } else if sawStart, line.hasPrefix(">>>>>>> ") || line == ">>>>>>>" {
                return true
            }
        }
        return false
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return String(result)
    }

    // MARK: - Markup

    public enum Style: Equatable {
        case bold, italic, underline
    }

    /// `*bold*`, `^italic^` and `_underline_` spans (TortoiseGit's `CSciEdit::MarkEnclosedText`):
    /// the marker must open at a word start, close at a word end and stay on one line.
    /// Ranges are UTF-16 based for `NSTextStorage`.
    public static func markupRanges(in text: String) -> [(range: NSRange, style: Style)] {
        var result: [(NSRange, Style)] = []
        let markers: [(Character, Style)] = [("*", .bold), ("^", .italic), ("_", .underline)]
        let ns = text as NSString
        for (marker, style) in markers {
            let escaped = NSRegularExpression.escapedPattern(for: String(marker))
            // (?<!\w) start, no space after the opener, no space before the closer, (?!\w) end.
            let pattern = "(?<![\\w\(escaped)])\(escaped)(?=[^\\s\(escaped)])[^\(escaped)\\n]*(?<=[^\\s\(escaped)])\(escaped)(?![\\w\(escaped)])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result.append((match.range, style))
            }
        }
        return result
    }
}

/// Issue-tracker settings (`bugtraq.*` from git config or `.tgitconfig`), the commit-dialog half of
/// TortoiseGit's `ProjectProperties`: a Bug-ID field whose value is put into the message.
public struct BugtraqSettings: Equatable, Sendable {
    /// Line added to the message; `%BUGID%` is replaced by the entered id(s).
    public let message: String
    /// Field label (default "Bug-ID / Issue-Nr:").
    public let label: String
    /// Only digits (and commas) allowed.
    public let numbersOnly: Bool
    /// Add the line at the end (true) or at the top.
    public let append: Bool
    /// Ask before committing without an issue id.
    public let warnIfNoIssue: Bool

    /// nil when no `bugtraq.message` containing `%BUGID%` is configured.
    public init?(config: [String: String]) {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            guard let value = config[key]?.lowercased() else { return fallback }
            return ["true", "yes", "on", "1"].contains(value)
        }
        guard let message = config["bugtraq.message"], message.contains("%BUGID%") else { return nil }
        self.message = message
        self.label = config["bugtraq.label"].flatMap { $0.isEmpty ? nil : $0 } ?? "Bug-ID / Issue-Nr:"
        self.numbersOnly = bool("bugtraq.number", true)
        self.append = bool("bugtraq.append", true)
        self.warnIfNoIssue = bool("bugtraq.warnifnoissue", false)
    }

    /// `ProjectProperties::CheckBugID`: digits and commas only when `bugtraq.number` is set.
    public func isValid(id: String) -> Bool {
        guard numbersOnly else { return true }
        return id.allSatisfy { $0.isNumber || $0 == "," || $0 == " " }
    }

    /// The configured line with the normalised id list (`1, 2` → `1,2`).
    public func line(for id: String) -> String {
        let ids = id.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return message.replacingOccurrences(of: "%BUGID%", with: ids.joined(separator: ","))
    }

    /// The message with the issue line added; unchanged when the id is empty or the line is already there.
    public func apply(id: String, to commitMessage: String) -> String {
        let trimmedID = id.trimmingCharacters(in: .whitespaces)
        guard !trimmedID.isEmpty else { return commitMessage }
        let bugLine = line(for: trimmedID)
        guard !commitMessage.contains(bugLine) else { return commitMessage }
        let body = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return bugLine }
        return append ? body + "\n" + bugLine : bugLine + "\n" + body
    }
}

/// Word completion for the message box (TortoiseGit's `autolist.txt` + `snippet.txt`): names of the
/// changed files plus identifiers declared in them.
public enum CommitAutoCompletion {

    /// Declaration patterns per file extension (a compact take on TortoiseGit's `autolist.txt`);
    /// capture group 1 is the identifier.
    static let patterns: [String: [String]] = {
        let cLike = [
            "\\b(?:class|struct|enum|union|interface|namespace)\\s+([A-Za-z_][A-Za-z0-9_]*)",
            "^[\\w:<>,\\*&\\s]+?[\\s\\*&]([A-Za-z_][A-Za-z0-9_:]*)\\s*\\([^;]*$"
        ]
        let swift = ["\\b(?:class|struct|enum|protocol|extension|actor|func|var|let|case|typealias)\\s+([A-Za-z_][A-Za-z0-9_]*)"]
        let script = ["\\b(?:class|function|def|const|let|var|interface|type|enum)\\s+([A-Za-z_$][A-Za-z0-9_$]*)"]
        var table: [String: [String]] = [:]
        for ext in ["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "java", "cs", "kt", "scala"] { table[ext] = cLike }
        table["swift"] = swift
        for ext in ["js", "jsx", "ts", "tsx", "py", "rb", "php"] { table[ext] = script }
        table["go"] = ["\\b(?:func|type|var|const)\\s+(?:\\([^)]*\\)\\s*)?([A-Za-z_][A-Za-z0-9_]*)"]
        table["rs"] = ["\\b(?:fn|struct|enum|trait|type|mod|const|static|impl)\\s+([A-Za-z_][A-Za-z0-9_]*)"]
        return table
    }()

    /// Identifiers declared in `text` for a file with the given extension (none for unknown types).
    public static func identifiers(in text: String, fileExtension: String) -> Set<String> {
        guard let patterns = patterns[fileExtension.lowercased()] else { return [] }
        var found = Set<String>()
        let range = NSRange(location: 0, length: (text as NSString).length)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                let r = match.range(at: 1)
                guard r.location != NSNotFound else { continue }
                found.insert((text as NSString).substring(with: r))
            }
        }
        return found
    }

    /// Parses `snippet.txt`: `name=expansion` per line, `#` comments, `\n` and `\t` escapes.
    public static func parseSnippets(_ text: String) -> [String: String] {
        var snippets: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = String(line[line.index(after: eq)...])
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
            snippets[key] = value
        }
        return snippets
    }

    /// Candidates for the word being typed, case-insensitive prefix match, shortest first.
    public static func completions(for partial: String, in words: Set<String>, limit: Int = 50) -> [String] {
        guard !partial.isEmpty else { return [] }
        let lower = partial.lowercased()
        return words
            .filter { $0.count > partial.count && $0.lowercased().hasPrefix(lower) }
            .sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
            .prefix(limit)
            .map { $0 }
    }
}

/// One file's diff split into hunks that can be staged or unstaged on their own
/// (TortoiseGit's partial staging, `git apply --cached` of the chosen hunk).
public struct FileHunkPatch: Sendable {
    /// `diff --git`, `index`, `---`, `+++` lines.
    public let header: [String]
    public let hunks: [GitPatchHunk]

    /// nil for an empty diff, a binary diff or a diff of more than one file.
    public init?(unifiedDiff: String) {
        let lines = unifiedDiff.components(separatedBy: "\n")
        guard let firstHunk = lines.firstIndex(where: { $0.hasPrefix("@@ ") }) else { return nil }
        let header = Array(lines[..<firstHunk])
        guard header.filter({ $0.hasPrefix("diff --git ") }).count <= 1 else { return nil }
        let files = GitPatch.parse(unifiedDiff: unifiedDiff)
        guard files.count == 1, !files[0].hunks.isEmpty else { return nil }
        self.header = header
        self.hunks = files[0].hunks
    }

    /// A patch containing only hunk `index`, applicable to the side the diff was taken from.
    public func patch(forHunk index: Int) -> String {
        let hunk = hunks[index]
        return (header + [hunk.header] + hunk.lines).joined(separator: "\n") + "\n"
    }
}
