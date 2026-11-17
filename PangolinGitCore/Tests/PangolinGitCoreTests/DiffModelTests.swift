import XCTest
@testable import PangolinGitCore

final class DiffModelTests: XCTestCase {

    private let sampleDiff = """
    diff --git a/f.txt b/f.txt
    index 1111111..2222222 100644
    --- a/f.txt
    +++ b/f.txt
    @@ -1,4 +1,5 @@
     one
    -two
    +tw0
    +inserted
     three
    -four
    +four\r
    \\ No newline at end of file
    """

    func testPairsRemovedAndAddedLinesAsModified() {
        let rows = SideBySideDiffBuilder.rows(fromUnifiedDiff: sampleDiff)
        XCTAssertEqual(rows.map(\.kind), [.context, .modified, .added, .context, .modified])
        XCTAssertEqual(rows[1].leftNumber, 2)
        XCTAssertEqual(rows[1].rightNumber, 2)
        XCTAssertEqual(rows[2].leftNumber, nil)
        XCTAssertEqual(rows[2].rightNumber, 3)
        XCTAssertEqual(rows[3].leftNumber, 3)
        XCTAssertEqual(rows[3].rightNumber, 4)
        // CR is dropped for display.
        XCTAssertEqual(rows[4].rightText, "four")
    }

    func testInlineCharacterRanges() {
        let rows = SideBySideDiffBuilder.rows(fromUnifiedDiff: sampleDiff)
        XCTAssertEqual(rows[1].leftInline, [2..<3])
        XCTAssertEqual(rows[1].rightInline, [2..<3])
    }

    func testInlineWordRanges() {
        let ranges = InlineDiff.ranges(old: "let value = oldName + 1", new: "let value = newName + 1", mode: .word)
        XCTAssertEqual(ranges.old, [12..<19])
        XCTAssertEqual(ranges.new, [12..<19])
    }

    func testInlineOffProducesNoRanges() {
        let rows = SideBySideDiffBuilder.rows(fromUnifiedDiff: sampleDiff, inline: .off)
        XCTAssertTrue(rows[1].leftInline.isEmpty)
    }

    func testHunkHeaderRowsForLaterHunks() {
        let diff = """
        @@ -10,2 +10,2 @@
         a
        -b
        +c
        """
        let rows = SideBySideDiffBuilder.rows(fromUnifiedDiff: diff)
        XCTAssertEqual(rows.first?.kind, .header)
        XCTAssertEqual(rows[1].leftNumber, 10)
    }

    func testMultiFileDiffKeepsFileHeaders() {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -x
        +y
        diff --git a/b.txt b/b.txt
        new file mode 100644
        --- /dev/null
        +++ b/b.txt
        @@ -0,0 +1 @@
        +z
        """
        let rows = SideBySideDiffBuilder.rows(fromUnifiedDiff: diff)
        XCTAssertEqual(rows.map(\.kind), [.header, .modified, .header, .header, .added])
        XCTAssertEqual(rows[0].leftText, "a.txt")
        XCTAssertEqual(rows[4].rightNumber, 1)
    }

    func testCollapseKeepsContextAroundChanges() {
        var rows = (1...20).map { DiffRow(kind: .context, leftNumber: $0, rightNumber: $0, leftText: "\($0)", rightText: "\($0)") }
        rows[10] = DiffRow(kind: .modified, leftNumber: 11, rightNumber: 11, leftText: "a", rightText: "b")
        let collapsed = SideBySideDiffBuilder.collapse(rows, context: 2)
        XCTAssertEqual(collapsed.first?.kind, .fold)
        XCTAssertEqual(collapsed.first?.foldedCount, 8)
        XCTAssertEqual(collapsed.last?.kind, .fold)
        XCTAssertEqual(collapsed.filter { $0.kind == .context }.count, 4)
    }

    func testChangeBlocks() {
        let rows = SideBySideDiffBuilder.rows(fromUnifiedDiff: sampleDiff)
        XCTAssertEqual(SideBySideDiffBuilder.changeBlocks(rows), [1..<3, 4..<5])
    }

    func testApplyLeftBlockRestoresOldLines() {
        let rows = SideBySideDiffBuilder.rows(fromUnifiedDiff: sampleDiff)
        let working = ["one", "tw0", "inserted", "three", "four"]
        let restored = SideBySideDiffBuilder.applyLeftBlock(rows: rows, block: 1..<3, to: working)
        XCTAssertEqual(restored, ["one", "two", "three", "four"])
    }

    func testApplyLeftBlockForPureDeletionInsertsAfterPreviousLine() {
        let diff = """
        @@ -1,3 +1,2 @@
         a
        -b
         c
        """
        let rows = SideBySideDiffBuilder.rows(fromUnifiedDiff: diff)
        let restored = SideBySideDiffBuilder.applyLeftBlock(rows: rows, block: 1..<2, to: ["a\r", "c\r"], lineEnding: "\r")
        XCTAssertEqual(restored, ["a\r", "b\r", "c\r"])
    }

    func testApplyLeftBlockRefusesStaleFile() {
        let rows = SideBySideDiffBuilder.rows(fromUnifiedDiff: sampleDiff)
        XCTAssertNil(SideBySideDiffBuilder.applyLeftBlock(rows: rows, block: 1..<3, to: ["one", "changed", "x", "three"]))
    }

    // MARK: Encoding

    func testDecodeUTF8BOMRoundTrip() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + "a\r\nb\r\n".data(using: .utf8)!
        let decoded = try XCTUnwrap(TextFileEncoding.decode(data))
        XCTAssertEqual(decoded.text, "a\r\nb\r\n")
        XCTAssertEqual(decoded.encodingName, "UTF-8 BOM")
        XCTAssertEqual(decoded.lineEnding, .crlf)
        XCTAssertEqual(decoded.encode(decoded.text), data)
    }

    func testDecodeLatin1Fallback() throws {
        let data = Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) // "café\n" in Windows-1252
        let decoded = try XCTUnwrap(TextFileEncoding.decode(data))
        XCTAssertEqual(decoded.text, "café\n")
        XCTAssertEqual(decoded.encoding, .windowsCP1252)
        XCTAssertEqual(decoded.encode("caféé\n"), Data([0x63, 0x61, 0x66, 0xE9, 0xE9, 0x0A]))
    }

    func testBinaryDetection() {
        XCTAssertNil(TextFileEncoding.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
        XCTAssertNotNil(TextFileEncoding.decode(Data([0xFF, 0xFE, 0x61, 0x00])), "UTF-16 with BOM is text")
    }

    func testLineEndingDetection() {
        XCTAssertEqual(LineEndingStyle.detect(in: "a\nb\n"), .lf)
        XCTAssertEqual(LineEndingStyle.detect(in: "a\r\nb\n"), .mixed)
        XCTAssertEqual(LineEndingStyle.detect(in: "a"), .none)
    }

    // MARK: Conflict markers

    private let diff3Text = """
    top
    <<<<<<< ours
    mine
    ||||||| base
    original
    =======
    yours
    >>>>>>> theirs
    middle
    <<<<<<< HEAD
    a
    =======
    b
    >>>>>>> feature
    end
    """

    func testParsesDiff3AndMergeStyleBlocks() {
        let blocks = ConflictMarkers.blocks(in: diff3Text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].lineRange, 1..<8)
        XCTAssertEqual(blocks[0].ours, ["mine"])
        XCTAssertEqual(blocks[0].base, ["original"])
        XCTAssertEqual(blocks[0].theirs, ["yours"])
        XCTAssertNil(blocks[1].base)
        XCTAssertEqual(blocks[1].theirsLabel, "feature")
    }

    func testResolveAllWithBothOrderings() {
        XCTAssertEqual(ConflictMarkers.resolveAll(diff3Text, choice: .theirsThenOurs),
                       "top\nyours\nmine\nmiddle\nb\na\nend")
        XCTAssertEqual(ConflictMarkers.resolveAll(diff3Text, choice: .base), "top\noriginal\nmiddle\nend")
    }

    func testSidesFromMarkers() {
        let sides = ConflictMarkers.sides(of: diff3Text)
        XCTAssertEqual(sides.ours, "top\nmine\nmiddle\na\nend")
        XCTAssertEqual(sides.theirs, "top\nyours\nmiddle\nb\nend")
        XCTAssertEqual(sides.base, "top\noriginal\nmiddle\nend")
    }

    func testLocatePrefersNearestOccurrence() {
        let lines = ["x", "a", "b", "y", "a", "b"]
        XCTAssertEqual(ConflictMarkers.locate(["a", "b"], in: lines, near: 0), 1..<3)
        XCTAssertEqual(ConflictMarkers.locate(["a", "b"], in: lines, near: 5), 4..<6)
        XCTAssertNil(ConflictMarkers.locate([], in: lines, near: 0))
        XCTAssertNil(ConflictMarkers.locate(["z"], in: lines, near: 0))
    }

    func testLineChangesAgainstBase() {
        let result = ConflictMarkers.lineChanges(base: ["a", "b", "c"], side: ["a", "B", "c", "d"])
        XCTAssertEqual(result.changed, [1, 3])
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.removed, 1)
    }

    func testSubmoduleClassification() {
        XCTAssertEqual(SubmoduleChange.classify(old: nil, new: "b", mergeBase: nil, oldTime: nil, newTime: nil), .newSubmodule)
        XCTAssertEqual(SubmoduleChange.classify(old: "a", new: nil, mergeBase: nil, oldTime: nil, newTime: nil), .deletedSubmodule)
        XCTAssertEqual(SubmoduleChange.classify(old: "a", new: "a", mergeBase: nil, oldTime: nil, newTime: nil), .identical)
        XCTAssertEqual(SubmoduleChange.classify(old: "a", new: "b", mergeBase: "a", oldTime: 1, newTime: 2), .fastForward)
        XCTAssertEqual(SubmoduleChange.classify(old: "a", new: "b", mergeBase: "b", oldTime: 2, newTime: 1), .rewind)
        XCTAssertEqual(SubmoduleChange.classify(old: "a", new: "b", mergeBase: "c", oldTime: 2, newTime: 1), .olderTime)
        XCTAssertEqual(SubmoduleChange.classify(old: "a", new: "b", mergeBase: nil, oldTime: nil, newTime: 1), .unknown)
    }

    func testIgnoresLookalikeLines() {
        XCTAssertTrue(ConflictMarkers.blocks(in: "<<<<<<<< not a marker\n=======\n>>>>>>> x").isEmpty)
    }

    func testUnmergedEntriesClassification() {
        let output = "100644 aaa 1\tf.txt\0100644 bbb 2\tf.txt\0100644 ccc 3\tf.txt\0"
            + "100644 ddd 1\tgone.txt\0100644 eee 3\tgone.txt\0"
            + "160000 fff 2\tsub\0160000 ggg 3\tsub\0"
        let entries = UnmergedEntries.parse(output)
        XCTAssertEqual(UnmergedEntries.kind(of: entries["f.txt"]!), .content)
        XCTAssertEqual(UnmergedEntries.kind(of: entries["gone.txt"]!), .deleted(oursMissing: true, theirsMissing: false))
        XCTAssertEqual(UnmergedEntries.kind(of: entries["sub"]!), .submodule)
    }

    func testRebaseSwapsSides() {
        let titles = ConflictSideTitles.make(operation: .rebase, currentBranch: nil, incoming: nil, rebasedBranch: "feature", onto: "main")
        XCTAssertTrue(titles.swapsStages)
        XCTAssertEqual(titles.mine, "Branch being rebased: feature")
        let merge = ConflictSideTitles.make(operation: .merge, currentBranch: "main", incoming: "feature", rebasedBranch: nil, onto: nil)
        XCTAssertFalse(merge.swapsStages)
        XCTAssertEqual(merge.theirs, "Theirs: MERGE_HEAD (feature)")
    }

    // MARK: External tools

    func testExternalToolPlaceholders() {
        let files = ExternalToolCommand.Files(base: "/tmp/old file.txt", mine: "/repo/new.txt", baseName: "new.txt (HEAD)")
        XCTAssertEqual(ExternalToolCommand.arguments(template: "--title=%bname \"$LOCAL\" '$REMOTE'", kind: .diff, files: files),
                       ["--title=new.txt (HEAD)", "/tmp/old file.txt", "/repo/new.txt"])
        XCTAssertEqual(ExternalToolCommand.arguments(template: "-wait", kind: .diff, files: files),
                       ["-wait", "/tmp/old file.txt", "/repo/new.txt"])
    }

    func testMergeToolDefaultsAndGitVariables() {
        let files = ExternalToolCommand.Files(base: "B", mine: "M", theirs: "T", merged: "R")
        XCTAssertEqual(ExternalToolCommand.arguments(template: "", kind: .merge, files: files), ["B", "T", "M", "R"])
        XCTAssertEqual(ExternalToolCommand.arguments(template: "$LOCAL $REMOTE -ancestor $BASE -merge $MERGED", kind: .merge, files: files),
                       ["M", "T", "-ancestor", "B", "-merge", "R"])
    }

    func testSubstitutionIsSinglePass() {
        let files = ExternalToolCommand.Files(base: "/x/%mine", mine: "/y")
        XCTAssertEqual(ExternalToolCommand.arguments(template: "%base %mine", kind: .diff, files: files), ["/x/%mine", "/y"])
    }

    func testOverrideLookup() {
        let table = [".PNG": "imgdiff", ".gitignore": "special"]
        XCTAssertEqual(ExternalToolCommand.override(for: "Logo.png", in: table), "imgdiff")
        XCTAssertEqual(ExternalToolCommand.override(for: ".gitignore", in: table), "special")
        XCTAssertNil(ExternalToolCommand.override(for: "readme.md", in: table))
    }

    func testDiffOptionArguments() {
        let options = GitDiffOptions(whitespace: .ignoreAll, ignoreBlankLines: true, ignoreLineEndings: true, fullContext: true)
        XCTAssertEqual(options.arguments, ["-w", "--ignore-blank-lines", "--ignore-cr-at-eol", "--unified=1000000"])
        XCTAssertTrue(GitDiffOptions().arguments.isEmpty)
    }
}
