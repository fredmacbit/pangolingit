import Foundation

/// One aligned row of a side-by-side diff — TortoiseMerge's per-line `DiffState` in `ViewData.h`.
/// Texts carry no line terminator; `leftNumber`/`rightNumber` are 1-based and nil where the side
/// has no line (the placeholder TortoiseMerge draws as an empty grey line).
public struct DiffRow: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case context
        case added
        case deleted
        /// A removed line paired with the added line that replaced it (TortoiseMerge's "edited").
        case modified
        /// File or hunk header, or an informational line such as "Binary files differ".
        case header
        /// Collapsed run of unchanged lines (TortoiseMerge's *Collapse unchanged sections*).
        case fold
    }

    public var kind: Kind
    public var leftNumber: Int?
    public var rightNumber: Int?
    public var leftText: String
    public var rightText: String
    /// UTF-16 ranges that differ inside a modified pair (intra-line highlighting).
    public var leftInline: [Range<Int>] = []
    public var rightInline: [Range<Int>] = []
    /// Number of unchanged lines hidden behind a `.fold` row.
    public var foldedCount: Int = 0

    public init(kind: Kind, leftNumber: Int? = nil, rightNumber: Int? = nil, leftText: String = "", rightText: String = "",
                leftInline: [Range<Int>] = [], rightInline: [Range<Int>] = [], foldedCount: Int = 0) {
        self.kind = kind
        self.leftNumber = leftNumber
        self.rightNumber = rightNumber
        self.leftText = leftText
        self.rightText = rightText
        self.leftInline = leftInline
        self.rightInline = rightInline
        self.foldedCount = foldedCount
    }

    public var isChange: Bool { kind == .added || kind == .deleted || kind == .modified }
}

/// Granularity of intra-line highlighting (TortoiseMerge's *Inline diff word-wise* setting).
public enum InlineDiffMode: String, CaseIterable, Sendable {
    case off
    case character
    case word
}

/// Builds aligned rows from `git diff` output. TortoiseMerge diffs the two files itself
/// (`DiffData.cpp`); PangolinGit lets git compute the line diff so whitespace options, rename
/// detection and textconv behave exactly like the command line, then aligns and refines the hunks.
public enum SideBySideDiffBuilder {

    /// Lines longer than this get no intra-line marks (TortoiseMerge's *Max line length for inline diffs*).
    public static let defaultMaxInlineLength = 3000

    public static func rows(fromUnifiedDiff diff: String, inline: InlineDiffMode = .character,
                            maxInlineLength: Int = defaultMaxInlineLength) -> [DiffRow] {
        var rows: [DiffRow] = []
        var leftNumber = 1
        var rightNumber = 1
        var oldRemaining = 0
        var newRemaining = 0
        var pendingDeleted: [(Int, String)] = []
        var pendingAdded: [(Int, String)] = []
        var fileHeaderRows: [Int] = []

        func flushChanges() {
            let paired = min(pendingDeleted.count, pendingAdded.count)
            for index in 0..<paired {
                let (oldNumber, oldText) = pendingDeleted[index]
                let (newNumber, newText) = pendingAdded[index]
                var row = DiffRow(kind: .modified, leftNumber: oldNumber, rightNumber: newNumber, leftText: oldText, rightText: newText)
                if inline != .off, oldText.utf16.count <= maxInlineLength, newText.utf16.count <= maxInlineLength {
                    let ranges = InlineDiff.ranges(old: oldText, new: newText, mode: inline)
                    row.leftInline = ranges.old
                    row.rightInline = ranges.new
                }
                rows.append(row)
            }
            for (number, text) in pendingDeleted.dropFirst(paired) {
                rows.append(DiffRow(kind: .deleted, leftNumber: number, leftText: text))
            }
            for (number, text) in pendingAdded.dropFirst(paired) {
                rows.append(DiffRow(kind: .added, rightNumber: number, rightText: text))
            }
            pendingDeleted.removeAll()
            pendingAdded.removeAll()
        }

        // Split on LF only so a CR stays with its line, then drop it for display.
        for rawLine in diff.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if oldRemaining > 0 || newRemaining > 0 {
                if line.hasPrefix("\\") { continue } // "\ No newline at end of file"
                if line.hasPrefix("+") {
                    pendingAdded.append((rightNumber, String(line.dropFirst())))
                    rightNumber += 1
                    newRemaining -= 1
                } else if line.hasPrefix("-") {
                    pendingDeleted.append((leftNumber, String(line.dropFirst())))
                    leftNumber += 1
                    oldRemaining -= 1
                } else {
                    flushChanges()
                    let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                    rows.append(DiffRow(kind: .context, leftNumber: leftNumber, rightNumber: rightNumber, leftText: text, rightText: text))
                    leftNumber += 1
                    rightNumber += 1
                    oldRemaining -= 1
                    newRemaining -= 1
                }
                oldRemaining = max(oldRemaining, 0)
                newRemaining = max(newRemaining, 0)
                if oldRemaining == 0 && newRemaining == 0 { flushChanges() }
                continue
            }
            if line.hasPrefix("\\") { continue }
            if line.hasPrefix("@@"), let range = parseHunkHeader(line) {
                leftNumber = range.oldStart == 0 ? 1 : range.oldStart
                rightNumber = range.newStart == 0 ? 1 : range.newStart
                oldRemaining = range.oldCount
                newRemaining = range.newCount
                // A hunk starting at the top of both files (always the case with full context) needs no header row.
                if range.oldStart > 1 || range.newStart > 1 {
                    rows.append(DiffRow(kind: .header, leftText: line, rightText: line))
                }
                continue
            }
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") {
                fileHeaderRows.append(rows.count)
                let name = fileName(fromDiffLine: line)
                rows.append(DiffRow(kind: .header, leftText: name, rightText: name))
                continue
            }
            if line.isEmpty || line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ")
                || line.hasPrefix("similarity index") || line.hasPrefix("dissimilarity index") {
                continue
            }
            // new file mode, deleted file mode, rename from/to, Binary files … differ
            rows.append(DiffRow(kind: .header, leftText: line, rightText: line))
        }
        flushChanges()
        // A single-file diff does not need its file header.
        if fileHeaderRows == [0] {
            rows.remove(at: 0)
        }
        return rows
    }

    /// Hides runs of unchanged rows, keeping `context` rows next to each change.
    public static func collapse(_ rows: [DiffRow], context: Int = 3) -> [DiffRow] {
        var result: [DiffRow] = []
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .context else {
                result.append(rows[index])
                index += 1
                continue
            }
            var end = index
            while end < rows.count && rows[end].kind == .context { end += 1 }
            let runLength = end - index
            let keepBefore = index == 0 ? 0 : context
            let keepAfter = end == rows.count ? 0 : context
            if runLength > keepBefore + keepAfter + 1 {
                result.append(contentsOf: rows[index..<(index + keepBefore)])
                let hidden = runLength - keepBefore - keepAfter
                let text = "⋯ \(hidden) unchanged line\(hidden == 1 ? "" : "s") ⋯"
                result.append(DiffRow(kind: .fold, leftText: text, rightText: text, foldedCount: hidden))
                result.append(contentsOf: rows[(end - keepAfter)..<end])
            } else {
                result.append(contentsOf: rows[index..<end])
            }
            index = end
        }
        return result
    }

    /// Maximal runs of changed rows — the "differences" F7 / Shift-F7 step through.
    public static func changeBlocks(_ rows: [DiffRow]) -> [Range<Int>] {
        var blocks: [Range<Int>] = []
        var start: Int?
        for (index, row) in rows.enumerated() {
            if row.isChange {
                if start == nil { start = index }
            } else if let blockStart = start {
                blocks.append(blockStart..<index)
                start = nil
            }
        }
        if let start { blocks.append(start..<rows.count) }
        return blocks
    }

    /// Replaces the right-hand lines of `block` in `lines` (the right file split on LF) with the
    /// block's left-hand lines — TortoiseMerge's *Use left block* on a working-tree diff.
    /// Returns nil when `lines` no longer matches the diff (the file changed since it was loaded).
    /// - Parameter lineEnding: terminator for inserted lines, e.g. "\r" for a CRLF file (LF is the separator).
    public static func applyLeftBlock(rows: [DiffRow], block: Range<Int>, to lines: [String], lineEnding: String = "") -> [String]? {
        let blockRows = rows[block]
        let rightRows = blockRows.filter { $0.rightNumber != nil }
        let leftLines = blockRows.filter { $0.leftNumber != nil }.map { $0.leftText + lineEnding }
        let start: Int
        if let first = rightRows.first?.rightNumber {
            start = first - 1
        } else if let previous = rows[..<block.lowerBound].last(where: { $0.rightNumber != nil })?.rightNumber {
            start = previous
        } else if let next = rows[block.upperBound...].first(where: { $0.rightNumber != nil })?.rightNumber {
            start = next - 1
        } else {
            start = 0
        }
        let end = start + rightRows.count
        guard start >= 0, end <= lines.count else { return nil }
        for (offset, row) in rightRows.enumerated() {
            let current = lines[start + offset]
            let trimmed = current.hasSuffix("\r") ? String(current.dropLast()) : current
            guard trimmed == row.rightText else { return nil }
        }
        var result = lines
        result.replaceSubrange(start..<end, with: leftLines)
        return result
    }

    /// Parses `@@ -a[,b] +c[,d] @@`; omitted counts default to 1.
    public static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let tokens = line.split(separator: " ")
        guard tokens.count >= 3, tokens[0] == "@@", tokens[1].hasPrefix("-"), tokens[2].hasPrefix("+") else { return nil }
        func range(_ token: Substring) -> (Int, Int)? {
            let parts = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]) else { return nil }
            guard let count = parts.count > 1 ? Int(parts[1]) : 1 else { return nil }
            return (start, count)
        }
        guard let old = range(tokens[1]), let new = range(tokens[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// `diff --git a/x b/y` → `y` (or `a/x → b/y` style for renames).
    private static func fileName(fromDiffLine line: String) -> String {
        let body = line.hasPrefix("diff --git ") ? String(line.dropFirst("diff --git ".count)) : String(line.dropFirst("diff --cc ".count))
        if let range = body.range(of: " b/") {
            let old = String(body[..<range.lowerBound]).replacingOccurrences(of: "a/", with: "", options: .anchored)
            let new = String(body[range.upperBound...])
            return old == new ? new : "\(old) → \(new)"
        }
        return body
    }
}

/// Second-level diff of a changed line pair (TortoiseMerge's inline diff in `BaseView::GetInlineDiffPositions`).
public enum InlineDiff {
    /// Above this many tokens in the differing middle part the whole middle is marked instead.
    static let maxTokens = 400

    public static func ranges(old: String, new: String, mode: InlineDiffMode) -> (old: [Range<Int>], new: [Range<Int>]) {
        guard mode != .off, old != new else { return ([], []) }
        let oldTokens = tokenize(old, mode: mode)
        let newTokens = tokenize(new, mode: mode)

        // Trim the common prefix and suffix first; most edits touch a small part of the line.
        var prefix = 0
        while prefix < oldTokens.count, prefix < newTokens.count, oldTokens[prefix].text == newTokens[prefix].text { prefix += 1 }
        var suffix = 0
        while suffix < oldTokens.count - prefix, suffix < newTokens.count - prefix,
              oldTokens[oldTokens.count - 1 - suffix].text == newTokens[newTokens.count - 1 - suffix].text { suffix += 1 }
        let oldMiddle = Array(oldTokens[prefix..<(oldTokens.count - suffix)])
        let newMiddle = Array(newTokens[prefix..<(newTokens.count - suffix)])

        if oldMiddle.count > maxTokens || newMiddle.count > maxTokens || oldMiddle.isEmpty || newMiddle.isEmpty {
            return (merged(oldMiddle.map(\.range)), merged(newMiddle.map(\.range)))
        }

        let script = DiffEngine().diff(old: oldMiddle.map(\.text), new: newMiddle.map(\.text))
        var oldRanges: [Range<Int>] = []
        var newRanges: [Range<Int>] = []
        var oldIndex = 0
        var newIndex = 0
        for step in script {
            switch step.operation {
            case .equal:
                oldIndex += 1
                newIndex += 1
            case .delete:
                oldRanges.append(oldMiddle[oldIndex].range)
                oldIndex += 1
            case .insert:
                newRanges.append(newMiddle[newIndex].range)
                newIndex += 1
            }
        }
        return (merged(oldRanges), merged(newRanges))
    }

    struct Token {
        let text: String
        let range: Range<Int>
    }

    /// Characters, or words (runs of letters/digits/underscore, runs of whitespace, single symbols).
    static func tokenize(_ text: String, mode: InlineDiffMode) -> [Token] {
        var tokens: [Token] = []
        var offset = 0
        if mode == .character {
            for character in text {
                let length = character.utf16.count
                tokens.append(Token(text: String(character), range: offset..<(offset + length)))
                offset += length
            }
            return tokens
        }
        enum Class { case word, space, symbol }
        func classify(_ character: Character) -> Class {
            if character.isLetter || character.isNumber || character == "_" { return .word }
            if character.isWhitespace { return .space }
            return .symbol
        }
        var current = ""
        var currentClass: Class?
        var start = 0
        for character in text {
            let kind = classify(character)
            if kind == currentClass, kind != .symbol {
                current.append(character)
            } else {
                if !current.isEmpty {
                    tokens.append(Token(text: current, range: start..<offset))
                }
                current = String(character)
                currentClass = kind
                start = offset
            }
            offset += character.utf16.count
        }
        if !current.isEmpty {
            tokens.append(Token(text: current, range: start..<offset))
        }
        return tokens
    }

    /// Joins touching ranges so a changed word is one highlight, not one per character.
    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges where !range.isEmpty {
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
