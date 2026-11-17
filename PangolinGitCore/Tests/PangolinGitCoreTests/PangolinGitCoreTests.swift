import XCTest
@testable import PangolinGitCore

final class PangolinGitCoreTests: XCTestCase {
    
    // MARK: - GitHash Tests
    
    func testGitHashValid() {
        let hex = "a1b2c3d4e5f67890123456789abcdef012345678"
        let hash = GitHash(hex: hex)
        XCTAssertNotNil(hash)
        XCTAssertEqual(hash?.string, hex)
        XCTAssertEqual(hash?.short, "a1b2c3d4")
        XCTAssertFalse(hash!.isZero)
    }
    
    func testGitHashZero() {
        let zero = GitHash.zero
        XCTAssertTrue(zero.isZero)
        XCTAssertEqual(zero.string.count, 40)
    }
    
    func testGitHashInvalid() {
        XCTAssertNil(GitHash(hex: "not-a-hash"))
        XCTAssertNil(GitHash(hex: "1234")) // Too short
    }
    
    // MARK: - PangolinPath Tests
    
    func testPathNormalizationAndRelative() {
        let base = PangolinPath("/Users/developer/MyProject")
        let sub = PangolinPath("/Users/developer/MyProject/Sources/App.swift")
        
        XCTAssertTrue(sub.isSubpath(of: base))
        XCTAssertFalse(base.isSubpath(of: sub))
        
        let relative = sub.relative(to: base)
        XCTAssertEqual(relative, "Sources/App.swift")
    }
    
    // MARK: - GitStatus and Badge Tests
    
    func testBadgeMapping() {
        let normal = GitItemStatusInfo(path: "clean.txt", status: .clean)
        XCTAssertEqual(normal.badgeKind, .normal)
        
        let modified = GitItemStatusInfo(path: "mod.txt", status: .modified)
        XCTAssertEqual(modified.badgeKind, .modified)
        
        let conflicted = GitItemStatusInfo(path: "conf.txt", status: .conflicted, isConflicted: true)
        XCTAssertEqual(conflicted.badgeKind, .conflicted)
        
        let untracked = GitItemStatusInfo(path: "new.txt", status: .untracked)
        XCTAssertEqual(untracked.badgeKind, .unversioned)
    }
    
    // MARK: - GitFolderStatus Aggregation Tests
    
    func testFolderStatusAggregation() {
        let cleanItem = GitItemStatusInfo(path: "a.txt", status: .clean)
        let modItem = GitItemStatusInfo(path: "b.txt", status: .modified)
        let confItem = GitItemStatusInfo(path: "c.txt", status: .conflicted, isConflicted: true)
        
        // Clean folder
        XCTAssertEqual(GitFolderStatus.aggregate(items: [cleanItem]), .normal)
        
        // Modified folder
        XCTAssertEqual(GitFolderStatus.aggregate(items: [cleanItem, modItem]), .modified)
        
        // Conflicted overrides modified
        XCTAssertEqual(GitFolderStatus.aggregate(items: [cleanItem, modItem, confItem]), .conflicted)
    }
    
    // MARK: - GitRevision Tests
    
    func testGitRevision() {
        let hash = GitHash(uncheckedHex: "1111222233334444555566667777888899990000")
        let author = GitAuthor(name: "John Doe", email: "john@example.com")
        let rev = GitRevision(
            hash: hash,
            parentHashes: [GitHash.zero],
            author: author,
            committer: author,
            subject: "Initial commit",
            body: "Detailed description."
        )
        
        XCTAssertEqual(rev.subject, "Initial commit")
        XCTAssertEqual(rev.fullMessage, "Initial commit\n\nDetailed description.")
        XCTAssertFalse(rev.isMergeCommit)
    }
    
    // MARK: - DiffEngine Tests
    
    func testMyersDiffEngine() {
        let engine = DiffEngine()
        let oldText = "Line 1\nLine 2\nLine 3"
        let newText = "Line 1\nLine 2 modified\nLine 3\nLine 4"
        
        let lines = engine.computeLineDiff(oldText: oldText, newText: newText)
        XCTAssertFalse(lines.isEmpty)
        
        // Should contain deletions and additions
        XCTAssertTrue(lines.contains(where: { $0.operation == .delete && $0.text == "Line 2" }))
        XCTAssertTrue(lines.contains(where: { $0.operation == .insert && $0.text == "Line 2 modified" }))
        XCTAssertTrue(lines.contains(where: { $0.operation == .insert && $0.text == "Line 4" }))
    }
    
    // MARK: - MergeEngine Tests
    
    func testMerge3WayCleanAndConflict() {
        let engine = MergeEngine()
        
        // Clean merge test
        let base = "Line A\nLine B"
        let ours = "Line A\nLine B modified"
        let theirs = "Line A\nLine B"
        
        let cleanResult = engine.merge3Way(base: base, ours: ours, theirs: theirs)
        XCTAssertFalse(cleanResult.hasConflicts)
        XCTAssertEqual(cleanResult.conflictCount, 0)
        
        // Conflicting merge test
        let oursConflict = "Line A\nOurs modification"
        let theirsConflict = "Line A\nTheirs modification"
        
        let conflictResult = engine.merge3Way(base: base, ours: oursConflict, theirs: theirsConflict)
        XCTAssertTrue(conflictResult.hasConflicts)
        XCTAssertGreaterThan(conflictResult.conflictCount, 0)
        XCTAssertTrue(conflictResult.mergedText.contains("<<<<<<< HEAD"))
        XCTAssertTrue(conflictResult.mergedText.contains(">>>>>>> Remote"))
    }
    
    // MARK: - CommitGraphLaneEngine Tests
    
    func testCommitGraphLaneEngine() {
        let engine = CommitGraphLaneEngine()
        let author = GitAuthor(name: "Tester", email: "test@example.com")
        
        let h1 = GitHash(uncheckedHex: "1000000000000000000000000000000000000001")
        let h2 = GitHash(uncheckedHex: "2000000000000000000000000000000000000002")
        let h3 = GitHash(uncheckedHex: "3000000000000000000000000000000000000003")
        
        // Linear history: h3 -> h2 -> h1
        let rev1 = GitRevision(hash: h1, parentHashes: [], author: author, committer: author, subject: "C1")
        let rev2 = GitRevision(hash: h2, parentHashes: [h1], author: author, committer: author, subject: "C2")
        let rev3 = GitRevision(hash: h3, parentHashes: [h2], author: author, committer: author, subject: "C3")
        
        let lanes = engine.computeLanes(revisions: [rev3, rev2, rev1])
        XCTAssertEqual(lanes.count, 3)
        XCTAssertEqual(lanes[0].nodeLane, 0)
        XCTAssertEqual(lanes[1].nodeLane, 0)
        XCTAssertEqual(lanes[2].nodeLane, 0)
    }
    
    // MARK: - AskPassHelper Tests
    
    func testAskPassHelper() {
        XCTAssertEqual(AskPassHelper.classify(prompt: "Username for 'https://github.com': "), .username)
        XCTAssertEqual(AskPassHelper.classify(prompt: "Password for 'https://user@github.com': "), .password)
        XCTAssertEqual(AskPassHelper.classify(prompt: "Enter passphrase for key '/Users/me/.ssh/id_ed25519': "), .passphrase)
        XCTAssertEqual(AskPassHelper.classify(prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])? "), .confirmation)
        
        let env = AskPassHelper.askPassEnvironment(helperPath: "/usr/local/bin/pangolin-askpass")
        XCTAssertEqual(env["GIT_ASKPASS"], "/usr/local/bin/pangolin-askpass")
        XCTAssertEqual(env["SSH_ASKPASS_REQUIRE"], "force")
    }
}


