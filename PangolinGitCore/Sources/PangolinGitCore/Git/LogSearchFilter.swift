import Foundation

/// The Log's search box: a port of TortoiseGit's `CFilterHelper` (`src/TortoiseProc/FilterHelper.cpp`)
/// and `CLogDlgFilter`.
///
/// Syntax (when not in regex mode): space-separated terms must all be present; `-term` must be
/// absent; `+term` starts an alternative group ("or"); `"quoted text"` keeps spaces (`""` is a
/// literal quote); a leading `!` inverts the whole result.
public struct LogSearchFilter: Sendable {

    /// The fields searched (the magnifier menu of TortoiseGit's filter box).
    public struct Fields: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let subject = Fields(rawValue: 1 << 0)
        public static let messages = Fields(rawValue: 1 << 1)
        public static let paths = Fields(rawValue: 1 << 2)
        public static let authors = Fields(rawValue: 1 << 3)
        public static let emails = Fields(rawValue: 1 << 4)
        public static let revisions = Fields(rawValue: 1 << 5)
        public static let refNames = Fields(rawValue: 1 << 6)
        public static let notes = Fields(rawValue: 1 << 7)

        /// TortoiseGit's default selection.
        public static let standard: Fields = [.messages, .paths, .authors, .revisions, .refNames]
        public static let all: Fields = [.subject, .messages, .paths, .authors, .emails, .revisions, .refNames, .notes]

        public static let titled: [(Fields, String)] = [
            (.subject, "Subject"), (.messages, "Messages"), (.paths, "Paths"), (.authors, "Authors"),
            (.emails, "Emails"), (.revisions, "SHA-1"), (.refNames, "Ref Names"), (.notes, "Notes")
        ]
    }

    enum Prefix: Equatable { case and, andNot, or }

    struct Condition: Equatable {
        let text: String
        let prefix: Prefix
        /// Index of the next `+` condition, 0 if none (where to continue after a failed group).
        var nextOrIndex: Int
    }

    public let fields: Fields
    public let caseSensitive: Bool
    public let negate: Bool
    private(set) var conditions: [Condition] = []
    private let regex: NSRegularExpression?
    /// True when regex mode was asked for but the pattern does not compile.
    public let isInvalidRegex: Bool

    public init(_ filter: String, fields: Fields = .standard, useRegex: Bool = false, caseSensitive: Bool = false) {
        self.fields = fields
        self.caseSensitive = caseSensitive
        var text = Substring(filter)
        var negate = false
        if text.first == "!" {
            negate = true
            text = text.dropFirst()
        }
        self.negate = negate
        if useRegex, !text.isEmpty {
            let compiled = try? NSRegularExpression(pattern: String(text), options: caseSensitive ? [] : [.caseInsensitive])
            regex = compiled
            isInvalidRegex = compiled == nil
            return
        }
        regex = nil
        isInvalidRegex = false
        parse(Array(text))
    }

    /// Whether the filter restricts anything (an empty box shows every commit).
    public var isActive: Bool { regex != nil || !conditions.isEmpty || isInvalidRegex }

    private mutating func parse(_ chars: [Character]) {
        var pos = 0
        let length = chars.count
        while pos < length {
            while pos < length, chars[pos] == " " { pos += 1 }
            guard pos < length else { break }
            var prefix = Prefix.and
            if chars[pos] == "-" { prefix = .andNot; pos += 1 }
            else if chars[pos] == "+" { prefix = .or; pos += 1 }

            if pos < length, chars[pos] == "\"" {
                var sub = ""
                pos += 1
                while pos < length {
                    if chars[pos] == "\"" {
                        pos += 1
                        if pos < length, chars[pos] == "\"" {
                            sub.append("\"")       // "" inside quotes is one quote
                            pos += 1
                        } else if pos >= length || chars[pos] == " " {
                            break                  // end of the quoted term
                        } else {
                            sub.append("\"")
                            sub.append(chars[pos])
                            pos += 1
                        }
                    } else {
                        sub.append(chars[pos])
                        pos += 1
                    }
                }
                add(sub, prefix)
                continue
            }
            var word = ""
            while pos < length, chars[pos] != " " {
                word.append(chars[pos])
                pos += 1
            }
            add(word, prefix)
        }
    }

    private mutating func add(_ token: String, _ prefix: Prefix) {
        guard !token.isEmpty else { return }
        conditions.append(Condition(text: caseSensitive ? token : token.lowercased(), prefix: prefix, nextOrIndex: 0))
        let newPos = conditions.count - 1
        if prefix == .or {
            // Earlier conditions of the previous group continue at this alternative when they fail.
            var i = newPos
            while i > 0 {
                if conditions[i - 1].nextOrIndex > 0 { break }
                conditions[i - 1].nextOrIndex = newPos
                i -= 1
            }
        }
    }

    /// Matches the searchable text of one commit (see `searchableText`).
    public func matches(_ text: String) -> Bool {
        guard isActive else { return true }
        return match(text) != negate
    }

    private func match(_ original: String) -> Bool {
        if isInvalidRegex { return false }
        if original.isEmpty { return false }
        if let regex {
            return regex.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)) != nil
        }
        let text = caseSensitive ? original : original.lowercased()
        var current = true
        var i = 0
        while i < conditions.count {
            let condition = conditions[i]
            var found = text.contains(condition.text)
            switch condition.prefix {
            case .andNot, .and:
                if condition.prefix == .andNot { found.toggle() }
                if !found {
                    if condition.nextOrIndex == 0 { return false }
                    current = false
                    i = condition.nextOrIndex
                    continue
                }
            case .or:
                current = current || found
                if !current {
                    if condition.nextOrIndex == 0 { return false }
                    i = condition.nextOrIndex
                    continue
                }
            }
            i += 1
        }
        return true
    }

    /// Builds the text searched for one commit from the selected fields.
    /// - Parameters:
    ///   - refNames: names of the refs pointing at the commit.
    ///   - paths: files the commit changed, if known.
    public func searchableText(for entry: GitLogEntry, refNames: [String], paths: [String]?) -> String {
        let revision = entry.revision
        var parts: [String] = []
        if !fields.isDisjoint(with: [.subject, .messages]) { parts.append(revision.subject) }
        if fields.contains(.messages) { parts.append(revision.body) }
        if fields.contains(.authors) { parts.append(revision.author.name); parts.append(revision.committer.name) }
        if fields.contains(.emails) { parts.append(revision.author.email); parts.append(revision.committer.email) }
        if fields.contains(.revisions) { parts.append(revision.hash.string) }
        if fields.contains(.notes) { parts.append(entry.notes) }
        if fields.contains(.refNames) { parts.append(contentsOf: refNames) }
        if fields.contains(.paths), let paths { parts.append(contentsOf: paths) }
        return parts.joined(separator: "\n")
    }
}
