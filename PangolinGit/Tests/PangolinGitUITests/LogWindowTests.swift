import XCTest
import Cocoa
@testable import PangolinGitCore

#if canImport(PangolinGit)
@testable import PangolinGit

/// Loads a real repository into the Log window and exercises filtering, menus and statistics.
final class LogWindowTests: XCTestCase {
    private var directory: URL!
    private var root: PangolinPath!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: GitCLIRunner.resolveGitExecutable()) else {
            throw XCTSkip("git CLI is not installed")
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pangolin-logui-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = PangolinPath(directory.path)
        for args in [["init", "-b", "main"], ["config", "user.name", "UI Test"], ["config", "user.email", "ui@test.local"],
                     ["config", "commit.gpgsign", "false"]] {
            try GitCLIRunner.run(arguments: args, workingDirectory: root)
        }
        for (index, name) in ["first", "second", "third"].enumerated() {
            try "\(index)\n".write(to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            try GitCLIRunner.run(arguments: ["add", "."], workingDirectory: root)
            try GitCLIRunner.run(arguments: ["commit", "-m", "Commit \(name)"], workingDirectory: root)
        }
        try GitCLIRunner.run(arguments: ["tag", "v1"], workingDirectory: root)
        // An uncommitted change for the "Working tree changes" row.
        try "changed\n".write(to: directory.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Waits for the initial load and for reloads triggered by the setup's own git commands.
    @MainActor
    private func settle(_ log: LogWindowController) {
        waitFor { !log.entries.isEmpty && !log.isLoading }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        waitFor { !log.isLoading }
    }

    @MainActor
    func testLoadsFiltersAndBuildsMenus() throws {
        let log = LogWindowController(repositoryPath: root)
        settle(log)
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.refMap.currentBranch, "main")

        let rows = log.numberOfRows(in: log.tableView)
        let workingTreeRow = log.showsWorkingTreeRow
        XCTAssertEqual(rows, 3 + (workingTreeRow ? 1 : 0))

        // Every visible cell can be produced (reused cells, label chips).
        for row in 0..<rows {
            for column in log.tableView.tableColumns {
                _ = log.tableView(log.tableView, viewFor: column, row: row)
            }
        }
        let firstCommitRow = workingTreeRow ? 1 : 0
        let message = log.tableView(log.tableView, viewFor: log.tableView.tableColumns.first { $0.identifier.rawValue == "Subject" },
                                    row: firstCommitRow) as? LogMessageCellView
        XCTAssertEqual(message?.message, "Commit third")
        if ConfigManager.shared.logShowRefLabels {
            XCTAssertEqual(Set(message?.chips.map(\.text) ?? []), ["main", "v1"])
        }

        // Search syntax filters in memory.
        log.searchField.stringValue = "second +third"
        _ = log.searchField.sendAction(log.searchField.action, to: log.searchField.target)
        XCTAssertEqual(log.numberOfRows(in: log.tableView), 2)
        log.searchField.stringValue = ""
        _ = log.searchField.sendAction(log.searchField.action, to: log.searchField.target)

        // Context menus for one and two selected commits build without touching the repository.
        log.tableView.selectRowIndexes(IndexSet(integer: firstCommitRow), byExtendingSelection: false)
        let menu = NSMenu()
        log.buildCommitMenu(menu)
        XCTAssertTrue(menu.items.contains { $0.title == "Compare with Previous Revision" })
        XCTAssertTrue(menu.items.contains { $0.title == "Cherry-Pick This Commit" })
        log.tableView.selectRowIndexes(IndexSet([firstCommitRow, firstCommitRow + 1]), byExtendingSelection: false)
        log.buildCommitMenu(menu)
        XCTAssertTrue(menu.items.contains { $0.title == "Compare Revisions" })
        XCTAssertTrue(menu.items.contains { $0.title == "Combine to One Commit…" })

        // Changed files of the selected commit.
        log.tableView.selectRowIndexes(IndexSet(integer: firstCommitRow), byExtendingSelection: false)
        waitFor { !log.changedFiles.isEmpty }
        XCTAssertEqual(log.changedFiles.map(\.path), ["third.txt"])

        // Navigation: first parent of "third" is "second".
        log.navigate(.firstParent)
        XCTAssertEqual(log.selectedEntries.first?.revision.subject, "Commit second")
        log.navigate(.back)
        XCTAssertEqual(log.selectedEntries.first?.revision.subject, "Commit third")
        log.close()
    }

    @MainActor
    func testPathFilteredLog() throws {
        let log = LogWindowController(repositoryPath: root, path: "second.txt")
        settle(log)
        XCTAssertEqual(log.entries.map(\.revision.subject), ["Commit second"])
        log.close()
    }

    @MainActor
    func testStatisticsPages() throws {
        let revisions = try GitRepository(rootPath: root).log(limit: 10)
        let statistics = StatisticsWindowController(repositoryPath: root, revisions: revisions)
        for index in 0..<statistics.pagePopup.numberOfItems {
            statistics.pagePopup.selectItem(at: index)
            _ = statistics.pagePopup.sendAction(statistics.pagePopup.action, to: statistics.pagePopup.target)
        }
        XCTAssertNotNil(statistics.window)
        statistics.close()
    }
}
#endif
