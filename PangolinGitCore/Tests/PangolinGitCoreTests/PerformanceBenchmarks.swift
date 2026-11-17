import XCTest
@testable import PangolinGitCore

/// Performance benchmarks for core Git operations, status calculation, and path resolution (Phase 13.4).
final class PerformanceBenchmarks: XCTestCase {
    
    func testPangolinPathResolutionPerformance() {
        let basePath = "/Users/developer/Projects/SwiftApp/Sources/Core/Subfolder/File.swift"
        let rootPath = "/Users/developer/Projects/SwiftApp"
        
        measure {
            for _ in 0..<10_000 {
                let path = PangolinPath(basePath)
                let root = PangolinPath(rootPath)
                _ = path.relative(to: root)
            }
        }
    }
    
    func testGitHashCreationAndComparisonPerformance() {
        let sampleHash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        
        measure {
            for _ in 0..<20_000 {
                let h1 = GitHash(hex: sampleHash)
                let h2 = GitHash(hex: "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
                _ = (h1 == h2)
            }
        }
    }
    
    func testGitBadgeStatusMappingPerformance() {
        let statuses: [GitItemStatusInfo] = [
            .clean, .modified, .conflicted, .added, .deleted, .ignored, .untracked
        ].map { GitItemStatusInfo(path: "file.txt", status: $0) }
        
        measure {
            for _ in 0..<50_000 {
                for status in statuses {
                    _ = status.badgeKind
                }
            }
        }
    }
    
    func testConfigManagerLookupPerformance() {
        let config = ConfigManager.shared
        
        measure {
            for _ in 0..<10_000 {
                _ = config.gitExecutablePath
                _ = config.recursiveStatusDepth
                _ = config.isContextMenuEnabled(for: "commit")
            }
        }
    }
}
