import Foundation

/// Git commit author or committer metadata.
public struct GitAuthor: Codable, Hashable, Sendable {
    public let name: String
    public let email: String
    public let date: Date
    
    public init(name: String, email: String, date: Date = Date()) {
        self.name = name
        self.email = email
        self.date = date
    }
}

/// A changed file in a revision or working-tree diff.
public struct GitDiffDelta: Codable, Hashable, Sendable {
    public let oldPath: String?
    public let newPath: String
    public let status: GitItemStatus
    public let additions: Int
    public let deletions: Int
    
    public init(
        oldPath: String? = nil,
        newPath: String,
        status: GitItemStatus,
        additions: Int = 0,
        deletions: Int = 0
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

/// A Git commit representation mirroring TortoiseGit's `GitRev` (`src/Git/GitRev.cpp`).
public struct GitRevision: Codable, Hashable, Identifiable, Sendable {
    public var id: String { hash.string }
    
    public let hash: GitHash
    public let parentHashes: [GitHash]
    public let treeHash: GitHash?
    public let author: GitAuthor
    public let committer: GitAuthor
    public let subject: String
    public let body: String
    public let refs: [String]          // Branch names, tag names pointing to this commit
    public let filesChanged: [GitDiffDelta]?
    
    public init(
        hash: GitHash,
        parentHashes: [GitHash] = [],
        treeHash: GitHash? = nil,
        author: GitAuthor,
        committer: GitAuthor,
        subject: String,
        body: String = "",
        refs: [String] = [],
        filesChanged: [GitDiffDelta]? = nil
    ) {
        self.hash = hash
        self.parentHashes = parentHashes
        self.treeHash = treeHash
        self.author = author
        self.committer = committer
        self.subject = subject
        self.body = body
        self.refs = refs
        self.filesChanged = filesChanged
    }
    
    public var fullMessage: String {
        if body.isEmpty {
            return subject
        }
        return "\(subject)\n\n\(body)"
    }
    
    public var isMergeCommit: Bool {
        return parentHashes.count > 1
    }
}
