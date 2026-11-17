import Foundation

/// Path handling utility mirroring TortoiseGit's `CTGitPath` (`src/Git/TGitPath.cpp`).
/// Provides robust handling for macOS APFS/HFS+ case-preserving/insensitive paths,
/// relative-to-repository path resolution, and Git administrative path queries.
public struct PangolinPath: Hashable, Codable, CustomStringConvertible, Sendable {
    public let rawPath: String
    
    public init(_ path: String) {
        self.rawPath = (path as NSString).standardizingPath
    }
    
    public init(url: URL) {
        self.rawPath = url.standardizedFileURL.path
    }
    
    public var url: URL {
        return URL(fileURLWithPath: rawPath)
    }
    
    public var description: String {
        return rawPath
    }
    
    public var filename: String {
        return (rawPath as NSString).lastPathComponent
    }
    
    public var pathExtension: String {
        return (rawPath as NSString).pathExtension
    }
    
    public var deletingLastPathComponent: PangolinPath {
        return PangolinPath((rawPath as NSString).deletingLastPathComponent)
    }
    
    public func appendingPathComponent(_ component: String) -> PangolinPath {
        return PangolinPath((rawPath as NSString).appendingPathComponent(component))
    }
    
    public func appending(_ component: String) -> PangolinPath {
        return appendingPathComponent(component)
    }
    
    public var exists: Bool {
        return FileManager.default.fileExists(atPath: rawPath)
    }
    
    public var isDirectory: Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: rawPath, isDirectory: &isDir) {
            return isDir.boolValue
        }
        return false
    }
    
    /// Normalizes path for APFS case comparisons
    public var normalizedForComparison: String {
        return rawPath.precomposedStringWithCanonicalMapping.lowercased()
    }
    
    /// Checks whether this path is equal to or a subpath of another path
    public func isSubpath(of parent: PangolinPath) -> Bool {
        let parentNorm = parent.normalizedForComparison
        let thisNorm = self.normalizedForComparison
        if thisNorm == parentNorm {
            return true
        }
        let prefix = parentNorm.hasSuffix("/") ? parentNorm : parentNorm + "/"
        return thisNorm.hasPrefix(prefix)
    }
    
    /// Calculates relative path from a given base directory
    public func relative(to base: PangolinPath) -> String? {
        let baseStandard = base.rawPath.hasSuffix("/") ? base.rawPath : base.rawPath + "/"
        if rawPath.hasPrefix(baseStandard) {
            return String(rawPath.dropFirst(baseStandard.count))
        } else if rawPath == base.rawPath {
            return ""
        }
        return nil
    }
}
