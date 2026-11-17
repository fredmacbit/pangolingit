import XCTest
@testable import PangolinGitCore

final class MergeEngineTests: XCTestCase {
    
    private var engine: MergeEngine!
    
    override func setUp() {
        super.setUp()
        engine = MergeEngine()
    }
    
    func testCleanMergeNoConflicts() {
        let base = "Line 1\nLine 2\nLine 3"
        let ours = "Line 1 (ours modified)\nLine 2\nLine 3"
        let theirs = "Line 1\nLine 2\nLine 3 (theirs modified)"
        
        let result = engine.merge3Way(base: base, ours: ours, theirs: theirs)
        
        XCTAssertFalse(result.hasConflicts)
        XCTAssertEqual(result.conflictCount, 0)
        XCTAssertTrue(result.mergedText.contains("Line 1 (ours modified)"))
        XCTAssertTrue(result.mergedText.contains("Line 3 (theirs modified)"))
    }
    
    func testConflictDetection() {
        let base = "Line 1\nLine 2\nLine 3"
        let ours = "Line 1\nLine 2 modified by ours\nLine 3"
        let theirs = "Line 1\nLine 2 modified by theirs\nLine 3"
        
        let result = engine.merge3Way(base: base, ours: ours, theirs: theirs)
        
        XCTAssertTrue(result.hasConflicts)
        XCTAssertEqual(result.conflictCount, 1)
        XCTAssertTrue(result.mergedText.contains("<<<<<<< HEAD"))
        XCTAssertTrue(result.mergedText.contains("Line 2 modified by ours"))
        XCTAssertTrue(result.mergedText.contains("======="))
        XCTAssertTrue(result.mergedText.contains("Line 2 modified by theirs"))
        XCTAssertTrue(result.mergedText.contains(">>>>>>> Remote"))
    }
    
    func testIdenticalChangesInBothBranches() {
        let base = "Line 1\nLine 2\nLine 3"
        let ours = "Line 1\nLine 2 identical change\nLine 3"
        let theirs = "Line 1\nLine 2 identical change\nLine 3"
        
        let result = engine.merge3Way(base: base, ours: ours, theirs: theirs)
        
        XCTAssertFalse(result.hasConflicts)
        XCTAssertEqual(result.conflictCount, 0)
        XCTAssertTrue(result.mergedText.contains("Line 2 identical change"))
    }
    
    func testMergeSessionInteractiveResolution() {
        let base = "Line 1\nTarget\nLine 3"
        let ours = "Line 1\nOurs Choice\nLine 3"
        let theirs = "Line 1\nTheirs Choice\nLine 3"
        
        let session = MergeSession(base: base, ours: ours, theirs: theirs, mergeEngine: engine)
        XCTAssertTrue(session.hasUnresolvedConflicts)
        XCTAssertEqual(session.unresolvedCount, 1)
        
        // Resolve choosing Ours
        session.resolveConflict(at: 0, with: .useOurs)
        XCTAssertFalse(session.hasUnresolvedConflicts)
        XCTAssertEqual(session.unresolvedCount, 0)
        
        let mergedOurs = session.generateMergedText()
        XCTAssertTrue(mergedOurs.contains("Ours Choice"))
        XCTAssertFalse(mergedOurs.contains("<<<<<<<"))
        
        // Resolve choosing Theirs
        session.resolveConflict(at: 0, with: .useTheirs)
        let mergedTheirs = session.generateMergedText()
        XCTAssertTrue(mergedTheirs.contains("Theirs Choice"))
        XCTAssertFalse(mergedTheirs.contains("Ours Choice"))
    }
}
