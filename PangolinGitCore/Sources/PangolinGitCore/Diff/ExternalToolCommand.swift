import Foundation

/// Command line for an external diff or merge program. TortoiseGit stores one command line per tool
/// with `%base %mine %theirs %merged %bname %yname %tname %mname %bpath %ypath %brev %yrev %wtroot`
/// placeholders (`CAppUtils::StartExtDiff` / `StartExtMerge`); git's difftool/mergetool use
/// `$LOCAL $REMOTE $BASE $MERGED`. Both spellings are accepted here.
public enum ExternalToolCommand {

    /// Values for one launch. Diff: `base` is the old file, `mine` the new one.
    /// Merge: `base`, `mine` (ours), `theirs`, `merged` (the working file).
    public struct Files: Sendable {
        public var base: String
        public var mine: String
        public var theirs: String
        public var merged: String
        public var baseName: String
        public var mineName: String
        public var theirsName: String
        public var mergedName: String
        public var baseRevision: String
        public var mineRevision: String
        public var workingTreeRoot: String

        public init(base: String = "", mine: String = "", theirs: String = "", merged: String = "",
                    baseName: String? = nil, mineName: String? = nil, theirsName: String? = nil, mergedName: String? = nil,
                    baseRevision: String = "", mineRevision: String = "", workingTreeRoot: String = "") {
            self.base = base
            self.mine = mine
            self.theirs = theirs
            self.merged = merged
            self.baseName = baseName ?? (base as NSString).lastPathComponent
            self.mineName = mineName ?? (mine as NSString).lastPathComponent
            self.theirsName = theirsName ?? (theirs as NSString).lastPathComponent
            self.mergedName = mergedName ?? (merged as NSString).lastPathComponent
            self.baseRevision = baseRevision
            self.mineRevision = mineRevision
            self.workingTreeRoot = workingTreeRoot
        }
    }

    public enum Kind: Sendable {
        case diff
        case merge
    }

    /// Splits `arguments` like a shell (single and double quotes, backslash escapes) and substitutes
    /// placeholders inside each word, so a path with spaces stays one argument. When the template names
    /// no file placeholder at all, the files are appended the way TortoiseGit does (`%base %mine` for
    /// a diff, `%base %theirs %mine %merged` for a merge).
    public static func arguments(template: String, kind: Kind, files: Files) -> [String] {
        let fileTokens = ["%base", "%mine", "%theirs", "%merged", "$LOCAL", "$REMOTE", "$BASE", "$MERGED"]
        var effective = template
        if !fileTokens.contains(where: { template.contains($0) }) {
            effective += kind == .diff ? " %base %mine" : " %base %theirs %mine %merged"
        }
        return split(effective).map { substitute($0, kind: kind, files: files) }
    }

    /// Shell-like word splitting (no globbing or variable expansion).
    public static func split(_ commandLine: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaping = false
        for character in commandLine {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaping = true
                inWord = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(character)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    static func substitute(_ word: String, kind: Kind, files: Files) -> String {
        // No token is a prefix of another, so the order only matters for readability.
        var pairs: [(String, String)] = [
            ("%wtroot", files.workingTreeRoot),
            ("%merged", files.merged), ("%theirs", files.theirs),
            ("%bname", files.baseName), ("%yname", files.mineName), ("%tname", files.theirsName), ("%mname", files.mergedName),
            ("%bpath", files.baseName), ("%ypath", files.mineName),
            ("%brev", files.baseRevision), ("%yrev", files.mineRevision),
            ("%base", files.base), ("%mine", files.mine),
        ]
        switch kind {
        case .diff:
            pairs += [("$LOCAL", files.base), ("$REMOTE", files.mine), ("$MERGED", files.mine), ("$BASE", files.base)]
        case .merge:
            pairs += [("$MERGED", files.merged), ("$LOCAL", files.mine), ("$REMOTE", files.theirs), ("$BASE", files.base)]
        }
        // One left-to-right pass, so a substituted path that happens to contain "%mine" stays intact.
        var result = ""
        var rest = Substring(word)
        while !rest.isEmpty {
            if let (token, value) = pairs.first(where: { rest.hasPrefix($0.0) }) {
                result += value
                rest = rest.dropFirst(token.count)
            } else {
                result.append(rest.removeFirst())
            }
        }
        return result
    }

    /// Per-extension override lookup (TortoiseGit's *Advanced* tables): an exact file-name key such as
    /// `.gitignore` wins over an extension key such as `.png`; keys are case-insensitive.
    public static func override(for fileName: String, in table: [String: String]) -> String? {
        let lowered = table.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        let name = fileName.lowercased()
        if let exact = lowered["." + name] ?? lowered[name], !exact.isEmpty { return exact }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        if let byExtension = lowered["." + ext] ?? lowered[ext], !byExtension.isEmpty { return byExtension }
        return nil
    }
}

/// Whitespace and context options for `git diff` (TortoiseMerge's *Ignore whitespace* radios and
/// Compare Revisions' *Diff Options* menu).
public struct GitDiffOptions: Equatable, Sendable {
    public enum Whitespace: String, CaseIterable, Sendable {
        /// Compare whitespace (default).
        case compare
        /// Ignore changes in amount of whitespace (`-b`).
        case ignoreChanges
        /// Ignore all whitespace (`-w`).
        case ignoreAll
        /// Ignore whitespace at line end only (`--ignore-space-at-eol`).
        case ignoreAtEOL
    }

    public var whitespace: Whitespace = .compare
    public var ignoreBlankLines = false
    /// `--ignore-cr-at-eol`: CRLF and LF lines compare equal (TortoiseMerge's *Ignore line endings*).
    public var ignoreLineEndings = false
    /// Show whole files instead of hunks with three lines of context.
    public var fullContext = false

    public init(whitespace: Whitespace = .compare, ignoreBlankLines: Bool = false, ignoreLineEndings: Bool = false, fullContext: Bool = false) {
        self.whitespace = whitespace
        self.ignoreBlankLines = ignoreBlankLines
        self.ignoreLineEndings = ignoreLineEndings
        self.fullContext = fullContext
    }

    public var arguments: [String] {
        var args: [String] = []
        switch whitespace {
        case .compare: break
        case .ignoreChanges: args.append("-b")
        case .ignoreAll: args.append("-w")
        case .ignoreAtEOL: args.append("--ignore-space-at-eol")
        }
        if ignoreBlankLines { args.append("--ignore-blank-lines") }
        if ignoreLineEndings { args.append("--ignore-cr-at-eol") }
        // A context larger than any file makes git emit one hunk spanning the whole file.
        if fullContext { args.append("--unified=1000000") }
        return args
    }

    public var isDefault: Bool { whitespace == .compare && !ignoreBlankLines && !ignoreLineEndings }
}
