import Foundation

/// Represents a Git SHA-1 or SHA-256 object hash.
/// Equivalent to TortoiseGit's `CGitHash` (`src/Git/GitHash.h`).
public struct GitHash: Hashable, Codable, CustomStringConvertible, Comparable, Sendable {
    public let string: String
    
    public init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (trimmed.count == 40 || trimmed.count == 64),
              trimmed.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        self.string = trimmed
    }
    
    /// Unchecked initializer for trusted internal representations
    public init(uncheckedHex: String) {
        self.string = uncheckedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    public var description: String {
        return string
    }
    
    public var short: String {
        return String(string.prefix(8))
    }
    
    public var isZero: Bool {
        return string.allSatisfy { $0 == "0" }
    }
    
    public static let zero = GitHash(uncheckedHex: String(repeating: "0", count: 40))
    
    public static func < (lhs: GitHash, rhs: GitHash) -> Bool {
        return lhs.string < rhs.string
    }
}
