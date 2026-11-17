import Foundation

/// Represents a merged line or conflict block in a 3-way merge.
public enum MergeChunkType: Sendable, Hashable {
    case clean(text: String)
    case conflict(ours: [String], theirs: [String], base: [String])
}

/// Result of a 3-way merge operation.
public struct MergeResult: Sendable {
    public let hasConflicts: Bool
    public let conflictCount: Int
    public let cleanChunksCount: Int
    public let chunks: [MergeChunkType]
    public let mergedText: String
}

/// 3-way merge engine computing merges between Base, Ours, and Theirs using computed Myers' diffs.
/// Equivalent to TortoiseMerge's merge conflict resolution engine (`src/TortoiseMerge/`).
public final class MergeEngine: Sendable {
    private let diffEngine: DiffEngine
    
    public init(diffEngine: DiffEngine = DiffEngine()) {
        self.diffEngine = diffEngine
    }
    
    private struct ChangeBlock: Equatable {
        var inserted: [String] = []
        var deleted: [String] = []
    }
    
    /// Performs a 3-way merge between base (common ancestor), ours (local), and theirs (remote).
    public func merge3Way(base: String, ours: String, theirs: String) -> MergeResult {
        let baseLines = base.components(separatedBy: "\n")
        let oursLines = ours.components(separatedBy: "\n")
        let theirsLines = theirs.components(separatedBy: "\n")
        
        // Fast paths for identical contents
        if ours == theirs {
            return MergeResult(
                hasConflicts: false,
                conflictCount: 0,
                cleanChunksCount: oursLines.count,
                chunks: oursLines.map { .clean(text: $0) },
                mergedText: ours
            )
        }
        
        if ours == base {
            return MergeResult(
                hasConflicts: false,
                conflictCount: 0,
                cleanChunksCount: theirsLines.count,
                chunks: theirsLines.map { .clean(text: $0) },
                mergedText: theirs
            )
        }
        
        if theirs == base {
            return MergeResult(
                hasConflicts: false,
                conflictCount: 0,
                cleanChunksCount: oursLines.count,
                chunks: oursLines.map { .clean(text: $0) },
                mergedText: ours
            )
        }
        
        // Compute Myers diffs against base
        let diffOurs = diffEngine.diff(old: baseLines, new: oursLines)
        let diffTheirs = diffEngine.diff(old: baseLines, new: theirsLines)
        
        // Group edits by base line index
        let oursEdits = mapDiffToBase(diff: diffOurs, baseCount: baseLines.count)
        let theirsEdits = mapDiffToBase(diff: diffTheirs, baseCount: baseLines.count)
        
        var chunks: [MergeChunkType] = []
        var conflictCount = 0
        var cleanCount = 0
        
        for i in 0...baseLines.count {
            let oBlock = oursEdits[i] ?? ChangeBlock()
            let tBlock = theirsEdits[i] ?? ChangeBlock()
            let baseLine = (i < baseLines.count) ? baseLines[i] : nil
            
            if oBlock == tBlock {
                // Both branches made the identical modification or no modification
                for line in oBlock.inserted {
                    chunks.append(.clean(text: line))
                    cleanCount += 1
                }
                if oBlock.deleted.isEmpty, let b = baseLine {
                    chunks.append(.clean(text: b))
                    cleanCount += 1
                }
            } else if oBlock == ChangeBlock() {
                // Only theirs modified this line / position
                for line in tBlock.inserted {
                    chunks.append(.clean(text: line))
                    cleanCount += 1
                }
                if tBlock.deleted.isEmpty, let b = baseLine {
                    chunks.append(.clean(text: b))
                    cleanCount += 1
                }
            } else if tBlock == ChangeBlock() {
                // Only ours modified this line / position
                for line in oBlock.inserted {
                    chunks.append(.clean(text: line))
                    cleanCount += 1
                }
                if oBlock.deleted.isEmpty, let b = baseLine {
                    chunks.append(.clean(text: b))
                    cleanCount += 1
                }
            } else {
                // Both branches made differing modifications -> Conflict!
                var oursConflictLines = oBlock.inserted
                var theirsConflictLines = tBlock.inserted
                if oBlock.deleted.isEmpty, let b = baseLine {
                    oursConflictLines.append(b)
                }
                if tBlock.deleted.isEmpty, let b = baseLine {
                    theirsConflictLines.append(b)
                }
                
                let baseConflict = baseLine != nil ? [baseLine!] : []
                chunks.append(.conflict(ours: oursConflictLines, theirs: theirsConflictLines, base: baseConflict))
                conflictCount += 1
            }
        }
        
        // Construct merged output string with conflict markers
        var mergedOutput = ""
        for chunk in chunks {
            switch chunk {
            case .clean(let text):
                mergedOutput += text + "\n"
            case .conflict(let oLines, let tLines, _):
                mergedOutput += "<<<<<<< HEAD (Ours)\n"
                for o in oLines { mergedOutput += o + "\n" }
                mergedOutput += "=======\n"
                for t in tLines { mergedOutput += t + "\n" }
                mergedOutput += ">>>>>>> Remote (Theirs)\n"
            }
        }
        
        // Strip trailing newline if input didn't have one
        if !base.hasSuffix("\n") && !ours.hasSuffix("\n") && !theirs.hasSuffix("\n") && mergedOutput.hasSuffix("\n") {
            mergedOutput.removeLast()
        }
        
        return MergeResult(
            hasConflicts: conflictCount > 0,
            conflictCount: conflictCount,
            cleanChunksCount: cleanCount,
            chunks: chunks,
            mergedText: mergedOutput
        )
    }
    
    private func mapDiffToBase(diff: [(operation: DiffOperation, element: String)], baseCount: Int) -> [Int: ChangeBlock] {
        var map = [Int: ChangeBlock]()
        var baseIdx = 0
        
        for op in diff {
            switch op.operation {
            case .equal:
                baseIdx += 1
            case .insert:
                var block = map[baseIdx] ?? ChangeBlock()
                block.inserted.append(op.element)
                map[baseIdx] = block
            case .delete:
                var block = map[baseIdx] ?? ChangeBlock()
                block.deleted.append(op.element)
                map[baseIdx] = block
                baseIdx += 1
            }
        }
        return map
    }
}

/// Interactive 3-way merge resolution session managing conflict states.
public final class MergeSession {
    public enum ResolutionChoice: String, CaseIterable, Sendable {
        case unresolved = "Unresolved"
        case useBase = "Use Base"
        case useOurs = "Use Ours"
        case useTheirs = "Use Theirs"
        case useBothOursThenTheirs = "Use Both (Ours -> Theirs)"
        case useBothTheirsThenOurs = "Use Both (Theirs -> Ours)"
    }
    
    public struct ConflictItem: Sendable {
        public let id: Int
        public let baseLines: [String]
        public let oursLines: [String]
        public let theirsLines: [String]
        public var choice: ResolutionChoice
        
        public var isResolved: Bool {
            return choice != .unresolved
        }
    }
    
    public let baseText: String
    public let oursText: String
    public let theirsText: String
    public private(set) var conflicts: [ConflictItem] = []
    public private(set) var rawChunks: [MergeChunkType] = []
    
    public init(base: String, ours: String, theirs: String, mergeEngine: MergeEngine = MergeEngine()) {
        self.baseText = base
        self.oursText = ours
        self.theirsText = theirs
        
        let result = mergeEngine.merge3Way(base: base, ours: ours, theirs: theirs)
        self.rawChunks = result.chunks
        
        var conflictId = 0
        for chunk in result.chunks {
            if case .conflict(let oLines, let tLines, let bLines) = chunk {
                conflicts.append(ConflictItem(
                    id: conflictId,
                    baseLines: bLines,
                    oursLines: oLines,
                    theirsLines: tLines,
                    choice: .unresolved
                ))
                conflictId += 1
            }
        }
    }
    
    public var hasUnresolvedConflicts: Bool {
        return conflicts.contains(where: { !$0.isResolved })
    }
    
    public var unresolvedCount: Int {
        return conflicts.filter({ !$0.isResolved }).count
    }
    
    public func resolveConflict(at index: Int, with choice: ResolutionChoice) {
        guard index >= 0 && index < conflicts.count else { return }
        conflicts[index].choice = choice
    }
    
    public func resolveAll(with choice: ResolutionChoice) {
        for i in 0..<conflicts.count {
            conflicts[i].choice = choice
        }
    }
    
    public func generateMergedText() -> String {
        var lines: [String] = []
        var conflictIdx = 0
        
        for chunk in rawChunks {
            switch chunk {
            case .clean(let text):
                lines.append(text)
            case .conflict(let oLines, let tLines, let bLines):
                if conflictIdx < conflicts.count {
                    let c = conflicts[conflictIdx]
                    switch c.choice {
                    case .unresolved:
                        lines.append("<<<<<<< HEAD (Ours)")
                        lines.append(contentsOf: oLines)
                        lines.append("=======")
                        lines.append(contentsOf: tLines)
                        lines.append(">>>>>>> Remote (Theirs)")
                    case .useBase:
                        lines.append(contentsOf: bLines)
                    case .useOurs:
                        lines.append(contentsOf: oLines)
                    case .useTheirs:
                        lines.append(contentsOf: tLines)
                    case .useBothOursThenTheirs:
                        lines.append(contentsOf: oLines)
                        lines.append(contentsOf: tLines)
                    case .useBothTheirsThenOurs:
                        lines.append(contentsOf: tLines)
                        lines.append(contentsOf: oLines)
                    }
                    conflictIdx += 1
                }
            }
        }
        
        var output = lines.joined(separator: "\n")
        if !baseText.hasSuffix("\n") && !oursText.hasSuffix("\n") && !theirsText.hasSuffix("\n") && output.hasSuffix("\n") {
            output.removeLast()
        }
        return output
    }
}
