import Foundation

/// Git repository discovery and admin directory (`.git`) resolver.
/// Equivalent to TortoiseGit's `GitAdminDir.cpp`.
public enum GitAdminDir {
    
    public struct RepoLocations: Sendable {
        public let workingTreeRoot: PangolinPath
        public let gitDirectory: PangolinPath
        public let commonDirectory: PangolinPath
        public let isBare: Bool
        public let isWorktree: Bool
    }
    
    /// Returns true when `path` lies inside a non-bare working tree.
    public static func isInsideRepository(path: PangolinPath) -> Bool {
        guard let locations = findRepository(startingAt: path) else { return false }
        return !locations.isBare
    }
    
    /// Traverses directory hierarchy upwards to locate the enclosing Git repository.
    public static func findRepository(startingAt path: PangolinPath) -> RepoLocations? {
        var current = path.isDirectory ? path : path.deletingLastPathComponent
        
        while true {
            let dotGit = current.appendingPathComponent(".git")
            if dotGit.exists {
                if dotGit.isDirectory {
                    // Standard Git repository
                    return RepoLocations(
                        workingTreeRoot: current,
                        gitDirectory: dotGit,
                        commonDirectory: dotGit,
                        isBare: false,
                        isWorktree: false
                    )
                } else {
                    // .git is a file — could be a submodule or worktree pointer (e.g. "gitdir: /path/to/.git")
                    if let content = try? String(contentsOfFile: dotGit.rawPath, encoding: .utf8) {
                        let lines = content.components(separatedBy: .newlines)
                        for line in lines {
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            if trimmed.hasPrefix("gitdir:") {
                                let gitDirPath = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)
                                let resolvedGitDir: PangolinPath
                                if (gitDirPath as NSString).isAbsolutePath {
                                    resolvedGitDir = PangolinPath(gitDirPath)
                                } else {
                                    resolvedGitDir = current.appendingPathComponent(gitDirPath)
                                }
                                
                                // Check if commondir exists (for linked worktrees)
                                let commondirFile = resolvedGitDir.appendingPathComponent("commondir")
                                var commonDir = resolvedGitDir
                                if commondirFile.exists,
                                   let cContent = try? String(contentsOfFile: commondirFile.rawPath, encoding: .utf8) {
                                    let cTrimmed = cContent.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if (cTrimmed as NSString).isAbsolutePath {
                                        commonDir = PangolinPath(cTrimmed)
                                    } else {
                                        commonDir = resolvedGitDir.appendingPathComponent(cTrimmed)
                                    }
                                }
                                
                                return RepoLocations(
                                    workingTreeRoot: current,
                                    gitDirectory: resolvedGitDir,
                                    commonDirectory: commonDir,
                                    isBare: false,
                                    isWorktree: true
                                )
                            }
                        }
                    }
                }
            }
            
            // Check if current is itself a bare repository (has HEAD and objects and refs)
            let headFile = current.appendingPathComponent("HEAD")
            let objectsDir = current.appendingPathComponent("objects")
            let refsDir = current.appendingPathComponent("refs")
            if headFile.exists && objectsDir.isDirectory && refsDir.isDirectory {
                return RepoLocations(
                    workingTreeRoot: current,
                    gitDirectory: current,
                    commonDirectory: current,
                    isBare: true,
                    isWorktree: false
                )
            }
            
            let parent = current.deletingLastPathComponent
            if parent.rawPath == current.rawPath || parent.rawPath.isEmpty {
                break
            }
            current = parent
        }
        
        return nil
    }
}
