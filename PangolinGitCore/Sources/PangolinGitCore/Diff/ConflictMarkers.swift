import Foundation

/// One `<<<<<<< … >>>>>>>` region of a conflicted file. Line indexes are 0-based positions in the
/// text split on LF; `lineRange` covers the markers themselves.
public struct ConflictBlock: Sendable, Equatable {
    public let lineRange: Range<Int>
    public let ours: [String]
    /// The `|||||||` section of diff3-style markers; nil for plain merge-style markers.
    public let base: [String]?
    public let theirs: [String]
    public let oursLabel: String
    public let theirsLabel: String

    public init(lineRange: Range<Int>, ours: [String], base: [String]?, theirs: [String], oursLabel: String, theirsLabel: String) {
        self.lineRange = lineRange
        self.ours = ours
        self.base = base
        self.theirs = theirs
        self.oursLabel = oursLabel
        self.theirsLabel = theirsLabel
    }
}

/// How a conflict block is resolved — TortoiseMerge's *Use this text block*, *Use theirs/mine
/// text block*, and the two *Use both* orderings (`ID_EDIT_USEMINETHENTHEIRBLOCK` and friends).
public enum ConflictChoice: String, CaseIterable, Sendable {
    case ours
    case theirs
    case base
    case oursThenTheirs
    case theirsThenOurs
}

/// Parses and resolves conflict markers in text. The merge editor treats the merged text as the
/// single source of truth, so manual edits and per-block resolutions mix freely and undo works.
public enum ConflictMarkers {

    public static func blocks(in text: String) -> [ConflictBlock] {
        blocks(inLines: text.components(separatedBy: "\n"))
    }

    public static func blocks(inLines lines: [String]) -> [ConflictBlock] {
        enum Section { case outside, ours, base, theirs }
        var result: [ConflictBlock] = []
        var section = Section.outside
        var start = 0
        var ours: [String] = [], base: [String]? = nil, theirs: [String] = []
        var oursLabel = "", theirsLabel = ""

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            switch section {
            case .outside:
                if let label = marker("<<<<<<<", in: line) {
                    section = .ours
                    start = index
                    ours = []; base = nil; theirs = []
                    oursLabel = label
                }
            case .ours, .base:
                if marker("|||||||", in: line) != nil, section == .ours {
                    section = .base
                    base = []
                } else if line == "=======" {
                    section = .theirs
                } else if section == .ours {
                    ours.append(rawLine)
                } else {
                    base?.append(rawLine)
                }
            case .theirs:
                if let label = marker(">>>>>>>", in: line) {
                    theirsLabel = label
                    result.append(ConflictBlock(lineRange: start..<(index + 1), ours: ours, base: base, theirs: theirs,
                                                oursLabel: oursLabel, theirsLabel: theirsLabel))
                    section = .outside
                } else {
                    theirs.append(rawLine)
                }
            }
        }
        return result
    }

    /// The lines that replace `block` for `choice`. `.base` falls back to nothing when the markers
    /// carry no base section (merge style), matching TortoiseMerge's empty base block.
    public static func lines(for block: ConflictBlock, choice: ConflictChoice) -> [String] {
        switch choice {
        case .ours: return block.ours
        case .theirs: return block.theirs
        case .base: return block.base ?? []
        case .oursThenTheirs: return block.ours + block.theirs
        case .theirsThenOurs: return block.theirs + block.ours
        }
    }

    /// Resolves every block in `text` with `choice` (TortoiseMerge's *Use theirs/mine whole file* for conflicts).
    public static func resolveAll(_ text: String, choice: ConflictChoice) -> String {
        var lines = text.components(separatedBy: "\n")
        for block in blocks(inLines: lines).reversed() {
            lines.replaceSubrange(block.lineRange, with: Self.lines(for: block, choice: choice))
        }
        return lines.joined(separator: "\n")
    }

    /// Rebuilds the three sides from a conflicted file (used when the index has no stages, e.g. a
    /// file whose conflict was staged by mistake). Base falls back to ours outside diff3 blocks.
    public static func sides(of text: String) -> (base: String, ours: String, theirs: String) {
        let lines = text.components(separatedBy: "\n")
        var base: [String] = [], ours: [String] = [], theirs: [String] = []
        var next = 0
        for block in blocks(inLines: lines) {
            let common = lines[next..<block.lineRange.lowerBound]
            base += common; ours += common; theirs += common
            ours += block.ours
            theirs += block.theirs
            base += block.base ?? []
            next = block.lineRange.upperBound
        }
        let tail = lines[next...]
        base += tail; ours += tail; theirs += tail
        return (base.joined(separator: "\n"), ours.joined(separator: "\n"), theirs.joined(separator: "\n"))
    }

    /// Finds `needle` in `lines`, preferring the occurrence closest to `hint` — used to highlight a
    /// conflict's lines in the full Mine/Theirs/Base panes, whose line numbers differ from the merged text.
    public static func locate(_ needle: [String], in lines: [String], near hint: Int) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= lines.count else { return nil }
        var best: Int?
        for start in 0...(lines.count - needle.count) where lines[start] == needle[0] {
            guard lines[start..<(start + needle.count)].elementsEqual(needle) else { continue }
            if best == nil || abs(start - hint) < abs(best! - hint) { best = start }
        }
        return best.map { $0..<($0 + needle.count) }
    }

    /// Lines of `side` that differ from `base`, plus added/removed counts — the colouring and the
    /// status-bar counters of TortoiseMerge's Theirs/Mine views. The common prefix and suffix are
    /// skipped; a differing middle larger than `limit` lines is counted as wholly changed instead of
    /// diffed (the Myers engine keeps every step's frontier, which grows quadratically).
    public static func lineChanges(base: [String], side: [String], limit: Int = 4000) -> (changed: Set<Int>, added: Int, removed: Int) {
        var prefix = 0
        while prefix < base.count, prefix < side.count, base[prefix] == side[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < base.count - prefix, suffix < side.count - prefix,
              base[base.count - 1 - suffix] == side[side.count - 1 - suffix] { suffix += 1 }
        let baseMiddle = Array(base[prefix..<(base.count - suffix)])
        let sideMiddle = Array(side[prefix..<(side.count - suffix)])
        if baseMiddle.count + sideMiddle.count > limit {
            return (Set(prefix..<(prefix + sideMiddle.count)), sideMiddle.count, baseMiddle.count)
        }
        var changed = Set<Int>()
        var added = 0, removed = 0
        var sideIndex = prefix
        for step in DiffEngine().diff(old: baseMiddle, new: sideMiddle) {
            switch step.operation {
            case .equal:
                sideIndex += 1
            case .insert:
                changed.insert(sideIndex)
                added += 1
                sideIndex += 1
            case .delete:
                removed += 1
            }
        }
        return (changed, added, removed)
    }

    /// `<<<<<<< label` → "label"; a marker must be exactly seven characters followed by a space or nothing.
    private static func marker(_ prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        if rest.isEmpty { return "" }
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }
}

/// What kind of unmerged entry a path is — TortoiseGit's `ConflictEdit` branches into the text
/// merge, the *Delete conflict* dialog and the *Submodule conflict* dialog on the same facts.
public enum ConflictKind: Equatable, Sendable {
    /// Both sides have content; a text (or binary) three-way merge.
    case content
    /// One side deleted the file, the other modified it (or a side is missing for another reason).
    case deleted(oursMissing: Bool, theirsMissing: Bool)
    /// A gitlink (mode 160000) on at least one side.
    case submodule
    /// A symbolic link (mode 120000) on at least one side.
    case symlink
}

/// One line of `git ls-files -u` (`<mode> <object> <stage>\t<path>`).
public struct UnmergedStage: Equatable, Sendable {
    public let mode: String
    public let object: String
    public let stage: Int
    public let path: String
}

public enum UnmergedEntries {
    /// Parses `git ls-files -u -z` output, grouped by path then stage.
    public static func parse(_ output: String) -> [String: [Int: UnmergedStage]] {
        var result: [String: [Int: UnmergedStage]] = [:]
        for record in output.split(whereSeparator: { $0 == "\0" || $0 == "\n" }) {
            let parts = record.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let fields = parts[0].split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]) else { continue }
            let entry = UnmergedStage(mode: String(fields[0]), object: String(fields[1]), stage: stage, path: String(parts[1]))
            result[entry.path, default: [:]][stage] = entry
        }
        return result
    }

    public static func kind(of stages: [Int: UnmergedStage]) -> ConflictKind {
        if stages.values.contains(where: { $0.mode == "160000" }) { return .submodule }
        let oursMissing = stages[2] == nil
        let theirsMissing = stages[3] == nil
        if oursMissing || theirsMissing { return .deleted(oursMissing: oursMissing, theirsMissing: theirsMissing) }
        if stages.values.contains(where: { $0.mode == "120000" }) { return .symlink }
        return .content
    }
}

/// The operation that left the conflict, read from the files git writes into the admin directory.
public enum ConflictOperation: Equatable, Sendable {
    case merge
    case rebase
    case cherryPick
    case revert
    /// No operation in progress (e.g. `git stash pop` or `git apply --3way`).
    case other
}

/// Titles for the "mine" and "theirs" panes. During a rebase git's stage 2 is the branch being
/// rebased onto and stage 3 is your commit, so TortoiseGit swaps the panes
/// (`CAppUtils::GetConflictTitles`, `ConflictEdit` with `isRebase`).
public struct ConflictSideTitles: Equatable, Sendable {
    public let mine: String
    public let theirs: String
    public let operation: ConflictOperation
    /// True when "mine" shows stage 3 and "theirs" stage 2.
    public let swapsStages: Bool

    public static func make(operation: ConflictOperation, currentBranch: String?, incoming: String?,
                            rebasedBranch: String?, onto: String?) -> ConflictSideTitles {
        switch operation {
        case .rebase:
            return ConflictSideTitles(mine: "Branch being rebased" + (rebasedBranch.map { ": \($0)" } ?? ""),
                                      theirs: "Branch being rebased onto" + (onto.map { ": \($0)" } ?? ""),
                                      operation: operation, swapsStages: true)
        case .merge:
            return ConflictSideTitles(mine: "Mine: " + (currentBranch ?? "HEAD"),
                                      theirs: "Theirs: MERGE_HEAD" + (incoming.map { " (\($0))" } ?? ""),
                                      operation: operation, swapsStages: false)
        case .cherryPick:
            return ConflictSideTitles(mine: "Mine: " + (currentBranch ?? "HEAD"),
                                      theirs: "Theirs: CHERRY_PICK_HEAD" + (incoming.map { " (\($0))" } ?? ""),
                                      operation: operation, swapsStages: false)
        case .revert:
            return ConflictSideTitles(mine: "Mine: " + (currentBranch ?? "HEAD"),
                                      theirs: "Theirs: reverting REVERT_HEAD" + (incoming.map { " (\($0))" } ?? ""),
                                      operation: operation, swapsStages: false)
        case .other:
            return ConflictSideTitles(mine: "Mine: " + (currentBranch ?? "HEAD"), theirs: "Theirs: ref to be merged",
                                      operation: operation, swapsStages: false)
        }
    }

    /// Detects the operation from the admin directory (`.git`, or the worktree's git dir).
    public static func operation(gitDirectory: URL) -> ConflictOperation {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: gitDirectory.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply/rebasing") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return .other
    }

    /// `refs/heads/feature` → `feature` from `rebase-merge/head-name` or `rebase-apply/head-name`.
    public static func rebasedBranch(gitDirectory: URL) -> String? {
        for file in ["rebase-merge/head-name", "rebase-apply/head-name"] {
            if let raw = try? String(contentsOf: gitDirectory.appendingPathComponent(file), encoding: .utf8) {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
            }
        }
        return nil
    }
}
