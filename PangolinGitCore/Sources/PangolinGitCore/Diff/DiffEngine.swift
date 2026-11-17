import Foundation

/// Type of line difference.
public enum DiffOperation: Sendable, Hashable {
    case equal
    case insert
    case delete
}

/// A single line entry in a computed diff.
public struct DiffLine: Sendable, Hashable {
    public let operation: DiffOperation
    public let text: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    
    public init(operation: DiffOperation, text: String, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.operation = operation
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// A hunk containing contiguous diff lines with context.
public struct DiffHunk: Sendable, Hashable {
    public let oldStart: Int
    public let oldLength: Int
    public let newStart: Int
    public let newLength: Int
    public let lines: [DiffLine]
    
    public init(oldStart: Int, oldLength: Int, newStart: Int, newLength: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldLength = oldLength
        self.newStart = newStart
        self.newLength = newLength
        self.lines = lines
    }
    
    public var header: String {
        return "@@ -\(oldStart),\(oldLength) +\(newStart),\(newLength) @@"
    }
}

/// Myers O(ND) difference calculation engine.
/// Equivalent to TortoiseGit / TortoiseMerge's `DiffData.cpp` and `MovedBlocks.cpp`.
public final class DiffEngine: Sendable {
    
    public init() {}
    
    /// Computes Myers' diff between two collections of elements (e.g. lines).
    public func diff<T: Equatable>(old: [T], new: [T]) -> [(operation: DiffOperation, element: T)] {
        let n = old.count
        let m = new.count
        let maxD = n + m
        if maxD == 0 { return [] }
        
        var v = [Int: Int]()
        v[1] = 0
        var trace = [[Int: Int]]()
        
        for d in 0...maxD {
            trace.append(v)
            var found = false
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0)) {
                    x = v[k + 1] ?? 0
                } else {
                    x = (v[k - 1] ?? 0) + 1
                }
                var y = x - k
                
                while x < n && y < m && old[x] == new[y] {
                    x += 1
                    y += 1
                }
                v[k] = x
                
                if x >= n && y >= m {
                    found = true
                    break
                }
            }
            if found { break }
        }
        
        // Backtrack through trace to build script
        var result: [(operation: DiffOperation, element: T)] = []
        var x = n
        var y = m
        
        for d in stride(from: trace.count - 1, through: 1, by: -1) {
            let prevV = trace[d]
            let k = x - y
            
            let prevK: Int
            if k == -d + 1 || (k != d - 1 && (prevV[k - 1] ?? 0) < (prevV[k + 1] ?? 0)) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            
            let prevX = prevV[prevK] ?? 0
            let prevY = prevX - prevK
            
            while x > prevX && y > prevY {
                result.append((.equal, old[x - 1]))
                x -= 1
                y -= 1
            }
            
            if d > 0 {
                if x == prevX {
                    result.append((.insert, new[y - 1]))
                    y -= 1
                } else if y == prevY {
                    result.append((.delete, old[x - 1]))
                    x -= 1
                }
            }
        }
        
        while x > 0 && y > 0 {
            result.append((.equal, old[x - 1]))
            x -= 1
            y -= 1
        }
        
        return result.reversed()
    }
    
    /// Computes line-by-line diff between two multi-line text strings.
    public func computeLineDiff(oldText: String, newText: String) -> [DiffLine] {
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")
        let rawOps = diff(old: oldLines, new: newLines)
        
        var lines: [DiffLine] = []
        var oldIdx = 1
        var newIdx = 1
        
        for item in rawOps {
            switch item.operation {
            case .equal:
                lines.append(DiffLine(operation: .equal, text: item.element, oldLineNumber: oldIdx, newLineNumber: newIdx))
                oldIdx += 1
                newIdx += 1
            case .delete:
                lines.append(DiffLine(operation: .delete, text: item.element, oldLineNumber: oldIdx, newLineNumber: nil))
                oldIdx += 1
            case .insert:
                lines.append(DiffLine(operation: .insert, text: item.element, oldLineNumber: nil, newLineNumber: newIdx))
                newIdx += 1
            }
        }
        
        return lines
    }
    
    /// Generates unified diff output string complete with standard @@ headers.
    public func computeUnifiedDiff(oldText: String, newText: String, contextLines: Int = 3) -> String {
        let diffLines = computeLineDiff(oldText: oldText, newText: newText)
        if diffLines.allSatisfy({ $0.operation == .equal }) {
            return ""
        }
        
        var output = "--- a\n+++ b\n"
        
        // Group changes into hunks, keeping `contextLines` of equal lines around each change and
        // merging hunks whose context would overlap.
        let changeIndices = diffLines.indices.filter { diffLines[$0].operation != .equal }
        var ranges: [ClosedRange<Int>] = []
        for idx in changeIndices {
            let lower = max(0, idx - contextLines)
            let upper = min(diffLines.count - 1, idx + contextLines)
            if let last = ranges.last, lower <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else {
                ranges.append(lower...upper)
            }
        }
        
        for range in ranges {
            let hunk = diffLines[range]
            let oldCount = hunk.filter { $0.operation != .insert }.count
            let newCount = hunk.filter { $0.operation != .delete }.count
            // Line numbers of the first line in the hunk; for a pure insertion/deletion git uses the preceding line.
            let oldStart = hunk.first(where: { $0.oldLineNumber != nil })?.oldLineNumber ?? 0
            let newStart = hunk.first(where: { $0.newLineNumber != nil })?.newLineNumber ?? 0
            output += "@@ -\(oldCount == 0 ? max(0, oldStart - 1) : oldStart),\(oldCount) +\(newCount == 0 ? max(0, newStart - 1) : newStart),\(newCount) @@\n"
            
            for line in hunk {
                switch line.operation {
                case .equal:
                    output += " " + line.text + "\n"
                case .insert:
                    output += "+" + line.text + "\n"
                case .delete:
                    output += "-" + line.text + "\n"
                }
            }
        }
        
        return output
    }
}
