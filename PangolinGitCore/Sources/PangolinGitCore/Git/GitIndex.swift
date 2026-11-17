import Foundation

/// Git index (.git/index) reader and staging inspector.
/// Equivalent to TortoiseGit's `CGitIndex` (`src/Git/GitIndex.cpp`).
public struct GitIndexEntry: Sendable {
    public let path: String
    public let hash: GitHash
    public let stage: Int // 0: normal, 1: ancestor, 2: ours, 3: theirs
    public let fileSize: UInt32
    public let modificationTime: Date
}

public final class GitIndex: Sendable {
    public let repositoryPath: PangolinPath
    
    public init(repositoryPath: PangolinPath) {
        self.repositoryPath = repositoryPath
    }
    
    /// Queries staged entries from the repository index using CLI git ls-files.
    public func readEntries(cliRunner: GitCLIRunner = GitCLIRunner()) async throws -> [GitIndexEntry] {
        let result = try await cliRunner.run(
            arguments: ["ls-files", "--stage"],
            workingDirectory: repositoryPath
        )
        guard result.isSuccess else {
            throw GitCLIError.commandFailed(
                exitCode: result.exitCode,
                stderr: result.standardError,
                command: "git ls-files --stage"
            )
        }
        
        var entries: [GitIndexEntry] = []
        let lines = result.standardOutput.components(separatedBy: .newlines)
        
        for line in lines {
            // Format: <mode> <object> <stage>\t<file>
            let tabParts = line.components(separatedBy: "\t")
            guard tabParts.count >= 2 else { continue }
            
            let filePath = tabParts[1].trimmingCharacters(in: .whitespaces)
            let metaParts = tabParts[0].split(separator: " ")
            guard metaParts.count >= 3 else { continue }
            
            let hashHex = String(metaParts[1])
            let stageNum = Int(metaParts[2]) ?? 0
            
            guard let hash = GitHash(hex: hashHex) else { continue }
            
            entries.append(GitIndexEntry(
                path: filePath,
                hash: hash,
                stage: stageNum,
                fileSize: 0,
                modificationTime: Date()
            ))
        }
        
        return entries
    }
}
