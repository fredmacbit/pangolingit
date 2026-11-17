import XCTest
@testable import PangolinGitCore

/// The state-dependent Finder menu: rule semantics, layout, settings and state evaluation (SH-01/02/03/14/15).
final class ShellMenuTests: XCTestCase {

    // MARK: - Rules and layout

    func testRuleSemanticsMatchTortoiseGit() {
        XCTAssertFalse(ShellMenuRule([], []).matches([.inGit]), "an empty rule never matches")
        XCTAssertTrue(ShellMenuRule(.inGit).matches([.inGit, .folder]))
        XCTAssertFalse(ShellMenuRule(.inGit, .folder).matches([.inGit, .folder]))
        XCTAssertTrue(ShellMenuRule([], .folder).matches([.inGit]))
        XCTAssertFalse(ShellMenuRule([.inGit, .conflicted]).matches([.inGit]))
    }

    private func commands(_ state: ShellItemState, settings: FinderSettings = FinderSettings()) -> [String] {
        ShellMenuCatalog.layout(for: state, settings: settings).commands
    }

    func testConflictedFileOffersConflictCommands() {
        let state: ShellItemState = [.onlyOne, .inGit, .inVersionedFolder, .conflicted, .mergeActive]
        let offered = commands(state)
        XCTAssertTrue(offered.contains("merge"))
        XCTAssertTrue(offered.contains("resolve"))
        XCTAssertTrue(offered.contains("abortmerge"))
        XCTAssertTrue(offered.contains("blame"))
        XCTAssertFalse(offered.contains("add"))
        XCTAssertFalse(offered.contains("pull"), "folder-only command on a file")
    }

    func testCleanFolderHidesConflictAndFileCommands() {
        let state: ShellItemState = [.onlyOne, .folder, .folderInGit, .inGit, .inVersionedFolder, .normal]
        let offered = commands(state)
        XCTAssertFalse(offered.contains("merge"))
        XCTAssertFalse(offered.contains("resolve"))
        XCTAssertFalse(offered.contains("abortmerge"))
        XCTAssertFalse(offered.contains("blame"))
        XCTAssertFalse(offered.contains("stashpop"), "no stash")
        XCTAssertFalse(offered.contains("createrepo"))
        XCTAssertTrue(offered.contains("pull"))
        XCTAssertTrue(offered.contains("switch"))
        XCTAssertTrue(offered.contains("cleanup"))
        XCTAssertTrue(offered.contains("log"))
    }

    func testStashEntriesNeedStashAndApplyNeedsShift() {
        let base: ShellItemState = [.onlyOne, .folder, .folderInGit, .inGit, .inVersionedFolder, .stash]
        XCTAssertTrue(commands(base).contains("stashpop"))
        XCTAssertFalse(commands(base).contains("stashapply"), "Stash Apply is an extended entry by default")
        XCTAssertTrue(commands(base.union(.extended)).contains("stashapply"))
    }

    func testUnversionedFolderOutsideRepository() {
        let offered = commands([.onlyOne, .folder])
        XCTAssertEqual(Set(ShellMenuCatalog.layout(for: [.onlyOne, .folder], settings: FinderSettings()).topLevel.map(\.command)),
                       ["clone", "createrepo"])
        XCTAssertFalse(offered.contains("commit"))
        XCTAssertTrue(offered.contains("settings"))
    }

    func testUnversionedFileInsideRepositoryOffersAddAndIgnore() {
        let offered = commands([.onlyOne, .inVersionedFolder])
        XCTAssertTrue(offered.contains("add"))
        XCTAssertTrue(offered.contains("ignore"))
        XCTAssertFalse(offered.contains("revert"))
        XCTAssertFalse(offered.contains("remove"))
    }

    func testTwoFilesOfferDiff() {
        XCTAssertTrue(commands([.two, .inGit, .inVersionedFolder]).contains("diff"))
        XCTAssertFalse(commands([.two, .folder, .folderInGit, .inGit]).contains("diff"))
    }

    func testBareRepositoryOffersSubset() {
        let offered = Set(commands([.onlyOne, .folder, .bareRepo]))
        XCTAssertTrue(offered.isSuperset(of: ["fetch", "push", "log", "reflog", "browserefs", "repobrowser", "export", "worktree"]))
        XCTAssertFalse(offered.contains("commit"))
        XCTAssertFalse(offered.contains("clone"))
    }

    func testPlacementAndSeparators() {
        var settings = FinderSettings()
        settings.placements["log"] = .submenu
        settings.placements["commit"] = .hidden
        settings.placements["stats"] = .topLevel
        let layout = ShellMenuCatalog.layout(for: [.onlyOne, .folder, .folderInGit, .inGit, .inVersionedFolder], settings: settings)
        XCTAssertFalse(layout.commands.contains("commit"))
        XCTAssertTrue(layout.topLevel.map(\.command).contains("stats"))
        XCTAssertTrue(layout.submenu.compactMap { $0?.command }.contains("log"))
        XCTAssertNotNil(layout.submenu.first ?? nil, "no leading separator")
        XCTAssertNotNil(layout.submenu.last ?? nil, "no trailing separator")
        for (a, b) in zip(layout.submenu, layout.submenu.dropFirst()) {
            XCTAssertFalse(a == nil && b == nil, "no doubled separators")
        }
    }

    func testEveryCommandIsUniqueAndLowercase() {
        let commands = ShellMenuCatalog.entries.map(\.command)
        XCTAssertEqual(commands.count, Set(commands).count)
        XCTAssertTrue(commands.allSatisfy { $0 == $0.lowercased() })
    }

    // MARK: - Settings

    func testExclusionPatterns() {
        let settings = FinderSettings(menuExcludedPaths: ["/Users/me/Secret", "/opt/*", "  "])
        XCTAssertFalse(settings.isMenuAllowed(for: "/Users/me/Secret"))
        XCTAssertFalse(settings.isMenuAllowed(for: "/users/ME/secret"), "case-insensitive like APFS")
        XCTAssertTrue(settings.isMenuAllowed(for: "/Users/me/Secret/sub"), "no * means exact path only")
        XCTAssertFalse(settings.isMenuAllowed(for: "/opt/src/repo"))
        XCTAssertTrue(settings.isMenuAllowed(for: "/Users/me/Other"))
    }

    func testHideOutsideRepositoriesUnlessShift() {
        let settings = FinderSettings(hideMenusOutsideRepositories: true)
        XCTAssertNil(settings.layout(paths: ["/tmp/x"], state: [.onlyOne, .folder], isAdminDirectory: false))
        XCTAssertNotNil(settings.layout(paths: ["/tmp/x"], state: [.onlyOne, .folder, .extended], isAdminDirectory: false))
        XCTAssertNotNil(settings.layout(paths: ["/r/a"], state: [.onlyOne, .inGit, .inVersionedFolder], isAdminDirectory: false))
        XCTAssertNil(FinderSettings().layout(paths: ["/r/.git/x"], state: [.onlyOne], isAdminDirectory: true))
    }

    func testSettingsRoundTripThroughJSON() {
        var settings = FinderSettings(extendedCommands: ["cleanup"], watchedRoots: ["/a"])
        settings.placements["log"] = .hidden
        XCTAssertEqual(FinderSettings.decode(settings.encoded()), settings)
    }

    func testConfigPlacementFallsBackToLegacyToggles() {
        let suite = "test.suite.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let config = ConfigManager(suiteName: suite)
        XCTAssertEqual(config.contextMenuPlacement(for: "commit"), .topLevel)
        XCTAssertEqual(config.contextMenuPlacement(for: "browserefs"), .submenu)
        config.setContextMenuEnabled(false, for: "browseRefs")
        XCTAssertEqual(config.contextMenuPlacement(for: "browserefs"), .hidden, "legacy camel-cased key")
        config.setContextMenuPlacement(.topLevel, for: "browserefs")
        XCTAssertEqual(config.contextMenuPlacement(for: "browserefs"), .topLevel)
        XCTAssertTrue(config.isContextMenuEnabled(for: "browserefs"))
        config.resetContextMenu()
        XCTAssertEqual(config.contextMenuPlacement(for: "browserefs"), .submenu)
        XCTAssertEqual(config.contextMenuExtendedCommands, ShellMenuCatalog.defaultExtended)
    }

    // MARK: - State evaluation on real repositories

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("shellmenu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeRepository(_ name: String) throws -> PangolinPath {
        let path = PangolinPath(tempDirectory.appendingPathComponent(name).path)
        try FileManager.default.createDirectory(atPath: path.rawPath, withIntermediateDirectories: true)
        try GitCLIRunner.run(arguments: ["init", "-q"], workingDirectory: path)
        return path
    }

    func testEvaluateWorkingTreeRootAndRepositoryFlags() throws {
        let repo = try makeRepository("repo")
        let gitDir = repo.appendingPathComponent(".git")
        FileManager.default.createFile(atPath: gitDir.appendingPathComponent("MERGE_HEAD").rawPath, contents: Data("x\n".utf8))
        try "0000 refs/stash\n".write(toFile: gitDir.appendingPathComponent("packed-refs").rawPath, atomically: true, encoding: .utf8)
        try "*.bin filter=lfs diff=lfs merge=lfs -text\n".write(toFile: repo.appendingPathComponent(".gitattributes").rawPath, atomically: true, encoding: .utf8)

        let result = ShellItemStateEvaluator.evaluate(paths: [repo.rawPath]) { _, _ in .clean }
        XCTAssertEqual(PangolinPath(result.root), repo)
        XCTAssertTrue(result.state.isSuperset(of: [.onlyOne, .folder, .folderInGit, .wcRoot, .inGit, .normal,
                                                   .mergeActive, .stash, .lfs]))
        XCTAssertFalse(result.state.contains(.submodule))
        XCTAssertFalse(result.state.contains(.bisect))
    }

    func testEvaluateUnversionedAndPatchFiles() throws {
        let repo = try makeRepository("repo")
        let file = repo.appendingPathComponent("fix.patch")
        FileManager.default.createFile(atPath: file.rawPath, contents: Data())
        let result = ShellItemStateEvaluator.evaluate(paths: [file.rawPath]) { _, _ in .untracked }
        XCTAssertTrue(result.state.contains(.inVersionedFolder))
        XCTAssertTrue(result.state.contains(.patchFile))
        XCTAssertFalse(result.state.contains(.inGit))
        XCTAssertFalse(result.state.contains(.folder))
    }

    func testEvaluateOutsideRepositoryAndAdminDirectory() throws {
        let plain = tempDirectory.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let outside = ShellItemStateEvaluator.evaluate(paths: [plain, plain + "/x"]) { _, _ in nil }
        XCTAssertEqual(outside.root, "")
        XCTAssertTrue(outside.state.contains(.two))
        XCTAssertTrue(outside.state.isDisjoint(with: .gitRelated))

        let repo = try makeRepository("repo")
        let admin = ShellItemStateEvaluator.evaluate(paths: [repo.appendingPathComponent(".git/hooks").rawPath]) { _, _ in nil }
        XCTAssertTrue(admin.isAdminDirectory)
    }

    func testEvaluateBareRepository() throws {
        let bare = PangolinPath(tempDirectory.appendingPathComponent("bare.git").path)
        try GitCLIRunner.run(arguments: ["init", "-q", "--bare", bare.rawPath])
        let result = ShellItemStateEvaluator.evaluate(paths: [bare.rawPath]) { _, _ in nil }
        XCTAssertTrue(result.state.contains(.bareRepo))
        XCTAssertFalse(result.state.contains(.inGit))
        let objects = ShellItemStateEvaluator.evaluate(paths: [bare.appendingPathComponent("objects").rawPath]) { _, _ in nil }
        XCTAssertFalse(objects.state.contains(.bareRepo))
    }

    func testRegisteredSubmoduleDetection() throws {
        let outer = try makeRepository("outer")
        let inner = try makeRepository("outer/libs/inner")
        try "[submodule \"inner\"]\n\tpath = libs/inner\n\turl = ../inner\n"
            .write(toFile: outer.appendingPathComponent(".gitmodules").rawPath, atomically: true, encoding: .utf8)
        let result = ShellItemStateEvaluator.evaluate(paths: [inner.rawPath]) { _, _ in .clean }
        XCTAssertTrue(result.state.isSuperset(of: [.wcRoot, .submodule]))
        let outerResult = ShellItemStateEvaluator.evaluate(paths: [outer.rawPath]) { _, _ in .clean }
        XCTAssertTrue(outerResult.state.contains(.submoduleContainer))
    }

    func testInaccessibleFolder() throws {
        let folder = tempDirectory.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A `.git` file without a usable gitdir line: Git cannot open this working tree.
        try "garbage\n".write(to: folder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let result = ShellItemStateEvaluator.evaluate(paths: [folder.path]) { _, _ in nil }
        XCTAssertTrue(result.state.contains(.inaccessible))
        XCTAssertEqual(ShellMenuCatalog.layout(for: result.state, settings: FinderSettings()).submenu.first??.command, "inaccessible")
    }
}

/// Index flags and snapshot aggregation options (SH-05, SH-06).
final class OverlayOptionsTests: XCTestCase {

    func testIndexFlagsParsing() {
        let output = ["H tracked.txt", "S skipped/config.json", "h assumed.txt", "s both.txt", "M merged.txt"].joined(separator: "\0") + "\0"
        let flags = GitIndexFlags.parse(output)
        XCTAssertEqual(flags["skipped/config.json"], .locked)
        XCTAssertEqual(flags["both.txt"], .locked)
        XCTAssertEqual(flags["assumed.txt"], .needsLock)
        XCTAssertNil(flags["tracked.txt"])
        XCTAssertNil(flags["merged.txt"])
    }

    private let output = [
        "? docs/notes.txt",
        "? scratch/",
        "1 .M S.M. 160000 160000 160000 aaaa bbbb libs/sub"
    ].joined(separator: "\0") + "\0"

    func testDefaultAggregationIgnoresUnversionedButBubblesSubmodules() {
        let snapshot = RepositoryStatusSnapshot(root: PangolinPath("/r"), items: GitRepository.parsePorcelainV2(output: output))
        XCTAssertEqual(snapshot.lookup(relativePath: "docs", isDirectory: true).badge, .normal)
        XCTAssertEqual(snapshot.lookup(relativePath: "libs", isDirectory: true).badge, .modified)
    }

    func testOptionsChangeAggregation() {
        let options = RepositoryStatusSnapshot.Options(unversionedMarksParentModified: true, submoduleStatusInParent: false,
                                                       flaggedFiles: ["config.json": .locked])
        let snapshot = RepositoryStatusSnapshot(root: PangolinPath("/r"), items: GitRepository.parsePorcelainV2(output: output), options: options)
        XCTAssertEqual(snapshot.lookup(relativePath: "docs", isDirectory: true).badge, .modified)
        XCTAssertEqual(snapshot.lookup(relativePath: "", isDirectory: true).badge, .modified, "scratch/ bubbles to the root")
        XCTAssertEqual(snapshot.lookup(relativePath: "libs", isDirectory: true).badge, .normal)
        XCTAssertEqual(snapshot.lookup(relativePath: "config.json", isDirectory: false).badge, .locked)
    }
}

final class FinderMenuFallbackTests: XCTestCase {
    /// Without the status agent a folder could be inside a repository or not; Clone and Create
    /// Repository must still be offered (TortoiseGit shows them on any unversioned folder).
    func testUnknownRepositoryOffersCloneAndCreateRepository() throws {
        let layout = try XCTUnwrap(FinderSettings().layoutForUnknownRepository(paths: ["/tmp/empty"], state: [.onlyOne, .folder]))
        let commands = layout.commands
        for command in ["clone", "createrepo", "commit", "log", "sync"] {
            XCTAssertTrue(commands.contains(command), "\(command) missing from \(commands)")
        }
        XCTAssertEqual(commands.count, Set(commands).count, "no entry twice")
    }

    func testPlainFolderOffersCloneAndCreateRepository() {
        func commands(_ state: ShellItemState) -> [String] {
            ShellMenuCatalog.layout(for: state, settings: FinderSettings()).commands
        }
        let plain = commands([.onlyOne, .folder])
        XCTAssertTrue(plain.contains("clone"))
        XCTAssertTrue(plain.contains("createrepo"))
        XCTAssertFalse(commands([.onlyOne, .folder, .inGit, .folderInGit]).contains("clone"))
    }
}
