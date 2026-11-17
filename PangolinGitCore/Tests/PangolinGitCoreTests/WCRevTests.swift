import XCTest
@testable import PangolinGitCore

final class WCRevTests: XCTestCase {

    private func sampleInfo() -> WCRevInfo {
        var info = WCRevInfo()
        info.headHash = "0123456789abcdef0123456789abcdef01234567"
        info.headDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        info.branch = "main"
        info.logCount = 42
        info.hasModifications = true
        info.isTagged = false
        return info
    }

    func testRevisionKeywords() {
        let info = sampleInfo()
        XCTAssertEqual(WCRevTemplate.substitute("$WCREV$", info: info), info.headHash)
        XCTAssertEqual(WCRevTemplate.substitute("v$WCREV=7$!", info: info), "v0123456!")
        XCTAssertEqual(WCRevTemplate.substitute("$WCBRANCH$/$WCLOGCOUNT$", info: info), "main/42")
    }

    func testLogCountArithmetic() {
        let info = sampleInfo()
        XCTAssertEqual(WCRevTemplate.substitute("$WCLOGCOUNT+8$", info: info), "50")
        XCTAssertEqual(WCRevTemplate.substitute("$WCLOGCOUNT-2$", info: info), "40")
        XCTAssertEqual(WCRevTemplate.substitute("$WCLOGCOUNT&0x0F$", info: info), "10")
    }

    func testDates() {
        let info = sampleInfo()
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(WCRevTemplate.substitute("$WCDATEUTC$", info: info), "2023/11/14 22:13:20")
        XCTAssertEqual(WCRevTemplate.substitute("$WCDATE=%Y-%m-%d$", info: info, timeZone: utc), "2023-11-14")
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(WCRevTemplate.substitute("$WCNOWUTC=%Y$", info: info, now: now), "1970")
    }

    func testConditionalsSplitAtFirstColon() {
        let info = sampleInfo()
        XCTAssertEqual(WCRevTemplate.substitute("$WCMODS?dirty:clean$", info: info), "dirty")
        XCTAssertEqual(WCRevTemplate.substitute("$WCISTAGGED?tag:no:tag$", info: info), "no:tag")
        XCTAssertEqual(WCRevTemplate.substitute("$WCUNVER?yes:$", info: info), "")
    }

    func testUnknownAndMalformedKeywordsStay() {
        let info = sampleInfo()
        XCTAssertEqual(WCRevTemplate.substitute("cost: $5 $WCNOPE$", info: info), "cost: $5 $WCNOPE$")
        XCTAssertEqual(WCRevTemplate.substitute("$WCMODS?no-colon$", info: info), "$WCMODS?no-colon$")
    }

    func testOptionParsing() {
        let options = WCRevOptions.parse([".", "in.tmpl", "out.h", "-mqF"])
        XCTAssertEqual(options?.templatePath, "in.tmpl")
        XCTAssertEqual(options?.errorOnModifications, true)
        XCTAssertEqual(options?.quiet, true)
        XCTAssertEqual(options?.ignoreIgnoreFile, true)
        XCTAssertEqual(options?.recursive, false)
        XCTAssertEqual(WCRevOptions.parse([".", "-U"])?.recursive, true)
        XCTAssertNil(WCRevOptions.parse([]))
        XCTAssertNil(WCRevOptions.parse([".", "only-template"]))
        XCTAssertNil(WCRevOptions.parse([".", "-x"]))
    }

    func testStatusParsing() {
        var info = WCRevInfo()
        let status = [
            "1 .M N... 100644 100644 100644 abc abc file.txt",
            "1 .M SC.. 160000 160000 160000 abc abc sub",
            "? new.txt"
        ].joined(separator: "\0") + "\0"
        WCRevCollector.apply(statusOutput: status, to: &info)
        XCTAssertTrue(info.hasModifications)
        XCTAssertTrue(info.hasUnversioned)
        XCTAssertTrue(info.hasSubmodule)
        XCTAssertTrue(info.hasSubmoduleNewCommits)
        XCTAssertFalse(info.hasSubmoduleModifications)
    }

    func testCollectAgainstRealRepository() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wcrev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = PangolinPath(dir.path)
        let env = ["GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@e", "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@e"]
        try GitCLIRunner.run(arguments: ["init", "-q", "-b", "main"], workingDirectory: path)
        try "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try GitCLIRunner.run(arguments: ["add", "a.txt"], workingDirectory: path)
        try GitCLIRunner.run(arguments: ["commit", "-q", "-m", "one"], workingDirectory: path, environment: env)
        try "scratch".write(to: dir.appendingPathComponent("build.log"), atomically: true, encoding: .utf8)

        var info = try WCRevCollector.collect(path: dir.path, options: WCRevOptions())
        XCTAssertEqual(info.branch, "main")
        XCTAssertEqual(info.logCount, 1)
        XCTAssertEqual(info.headHash.count, 40)
        XCTAssertTrue(info.hasUnversioned)
        XCTAssertFalse(info.hasModifications)
        XCTAssertTrue(info.isInGit)

        // .gitwcrevignore hides build.log (and itself).
        try "build.log\n.gitwcrevignore\n".write(to: dir.appendingPathComponent(".gitwcrevignore"), atomically: true, encoding: .utf8)
        info = try WCRevCollector.collect(path: dir.path, options: WCRevOptions())
        XCTAssertFalse(info.hasUnversioned)

        XCTAssertThrowsError(try WCRevCollector.collect(path: FileManager.default.temporaryDirectory.path, options: WCRevOptions()))
    }
}
