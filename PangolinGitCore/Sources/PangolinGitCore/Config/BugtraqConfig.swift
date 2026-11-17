import Foundation

/// Issue-tracker integration settings (`bugtraq.*` in git config or `.tgitconfig`), and the rules
/// TortoiseGit applies with them: assembling the Bug-ID line of a commit message and finding issue
/// references in log messages (`src/TortoiseProc/ProjectProperties.cpp`).
public struct BugtraqConfig: Equatable, Sendable {
    /// `bugtraq.url`: issue URL with `%BUGID%` placeholder.
    public var url = ""
    /// `bugtraq.message`: line added to the commit message, with `%BUGID%`.
    public var message = ""
    /// `bugtraq.label`: label of the Bug-ID field in the commit dialog.
    public var label = ""
    /// `bugtraq.number`: the Bug-ID field accepts digits (and commas) only.
    public var numericOnly = true
    /// `bugtraq.append`: add the message line at the end (true) or at the top.
    public var append = true
    /// `bugtraq.warnifnoissue`: warn when committing without an issue number.
    public var warnIfNoIssue = false
    /// `bugtraq.logregex`: one regex (group 1 = issue id) or two lines: the "find the reference"
    /// regex, then the regex that extracts the ids from that match.
    public var logRegex = ""

    public init() {}

    /// Git config keys in the order the settings page shows them.
    public enum Key: String, CaseIterable, Sendable {
        case url = "bugtraq.url"
        case message = "bugtraq.message"
        case label = "bugtraq.label"
        case number = "bugtraq.number"
        case append = "bugtraq.append"
        case warnIfNoIssue = "bugtraq.warnifnoissue"
        case logRegex = "bugtraq.logregex"
    }

    /// Builds the config from git-config style values (missing keys keep TortoiseGit's defaults).
    public init(values: [String: String]) {
        url = values[Key.url.rawValue] ?? ""
        message = values[Key.message.rawValue] ?? ""
        label = values[Key.label.rawValue] ?? ""
        numericOnly = values[Key.number.rawValue].map(Self.parseBool) ?? true
        append = values[Key.append.rawValue].map(Self.parseBool) ?? true
        warnIfNoIssue = values[Key.warnIfNoIssue.rawValue].map(Self.parseBool) ?? false
        logRegex = values[Key.logRegex.rawValue] ?? ""
    }

    /// Whether any issue-tracker integration is configured.
    public var isActive: Bool { !message.isEmpty || !logRegex.isEmpty }

    /// Label for the commit dialog's field (TortoiseGit default "Bug-ID / Issue-Nr:").
    public var displayLabel: String { label.isEmpty ? "Bug-ID / Issue-Nr:" : label }

    public static func parseBool(_ value: String) -> Bool {
        ["true", "yes", "on", "1"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }

    // MARK: - Commit message

    /// Whether `bugID` is acceptable for the Bug-ID field (`bugtraq.number`: digits and commas).
    public func isValidBugID(_ bugID: String) -> Bool {
        guard numericOnly else { return true }
        return bugID.allSatisfy { $0.isNumber || $0 == "," || $0 == " " }
    }

    /// Adds the `bugtraq.message` line for `bugID` to `commitMessage`, at the end or the top.
    /// Several comma-separated ids are kept in one line, like TortoiseGit.
    public func messageWithBugID(_ commitMessage: String, bugID: String) -> String {
        let id = bugID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, message.contains("%BUGID%") else { return commitMessage }
        let line = message.replacingOccurrences(of: "%BUGID%", with: id)
        let body = commitMessage.trimmingCharacters(in: .newlines)
        if body.isEmpty { return line }
        return append ? body + "\n" + line : line + "\n" + body
    }

    /// Splits a message produced by `messageWithBugID` back into the message and the Bug-ID
    /// (`ProjectProperties::GetBugIDFromLog`).
    public func bugID(fromMessage commitMessage: String) -> (message: String, bugID: String)? {
        guard let range = message.range(of: "%BUGID%") else { return nil }
        let prefix = String(message[..<range.lowerBound])
        let suffix = String(message[range.upperBound...])
        var lines = commitMessage.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        let candidates = append ? [lines.count - 1, 0] : [0, lines.count - 1]
        for index in candidates {
            let line = lines[index]
            guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count >= prefix.count + suffix.count else { continue }
            let id = String(line.dropFirst(prefix.count).dropLast(suffix.count))
            guard !id.isEmpty else { continue }
            lines.remove(at: index)
            return (lines.joined(separator: "\n").trimmingCharacters(in: .newlines), id)
        }
        return nil
    }

    // MARK: - Log messages

    /// One issue reference found in a log message.
    public struct IssueReference: Equatable, Sendable {
        public let range: Range<String.Index>
        public let id: String
        public let url: URL?
    }

    /// Issue references in `text` (`ProjectProperties::FindBugIDPositions`): the regex rules when
    /// `bugtraq.logregex` is set, otherwise the `bugtraq.message` line.
    public func issueReferences(in text: String) -> [IssueReference] {
        let ranges: [Range<String.Index>]
        let regexLines = logRegex.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let check = regexLines.first {
            ranges = Self.regexRanges(in: text, check: check, bugID: regexLines.count > 1 ? regexLines[1] : nil)
        } else {
            ranges = messageLineRanges(in: text)
        }
        return ranges.map { range in
            let id = String(text[range])
            return IssueReference(range: range, id: id, url: issueURL(for: id))
        }
    }

    /// `bugtraq.url` with the id filled in.
    public func issueURL(for id: String) -> URL? {
        guard !url.isEmpty else { return nil }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return URL(string: url.replacingOccurrences(of: "%BUGID%", with: encoded))
    }

    /// With one regex, group 1 (or the whole match) is the id; with two, the second regex is applied
    /// inside each match of the first and every match of it is an id.
    static func regexRanges(in text: String, check: String, bugID: String?) -> [Range<String.Index>] {
        guard let checkRegex = try? NSRegularExpression(pattern: check) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var result: [Range<String.Index>] = []
        for match in checkRegex.matches(in: text, range: whole) {
            if let bugID, let idRegex = try? NSRegularExpression(pattern: bugID) {
                for inner in idRegex.matches(in: text, range: match.range) {
                    if let range = Range(inner.range, in: text) { result.append(range) }
                }
            } else {
                let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
                if let range = Range(group, in: text) { result.append(range) }
            }
        }
        return result
    }

    /// Ids in a `bugtraq.message` line at the configured end of the message (comma-separated).
    func messageLineRanges(in text: String) -> [Range<String.Index>] {
        guard let marker = message.range(of: "%BUGID%") else { return [] }
        let prefix = String(message[..<marker.lowerBound])
        let suffix = String(message[marker.upperBound...])
        let lineRanges = lineRangesOf(text)
        guard let first = lineRanges.first, let last = lineRanges.last else { return [] }
        for lineRange in (append ? [last, first] : [first, last]) {
            let line = text[lineRange]
            guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else { continue }
            let idsStart = text.index(lineRange.lowerBound, offsetBy: prefix.count)
            let idsEnd = text.index(lineRange.upperBound, offsetBy: -suffix.count)
            var ranges: [Range<String.Index>] = []
            var start = idsStart
            var index = idsStart
            while index <= idsEnd {
                if index == idsEnd || text[index] == "," {
                    var lower = start
                    var upper = index
                    while lower < upper, text[lower] == " " { lower = text.index(after: lower) }
                    while upper > lower, text[text.index(before: upper)] == " " { upper = text.index(before: upper) }
                    if lower < upper { ranges.append(lower..<upper) }
                    if index == idsEnd { break }
                    start = text.index(after: index)
                }
                index = text.index(after: index)
            }
            return ranges
        }
        return []
    }

    /// Non-empty line ranges of `text`.
    private func lineRangesOf(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            if !range.isEmpty { ranges.append(range) }
        }
        return ranges
    }
}
