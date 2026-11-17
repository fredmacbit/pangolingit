import XCTest
import Cocoa
@testable import PangolinGitCore

#if canImport(PangolinGit)
@testable import PangolinGit

/// App-side pieces of the Finder integration: Create Repository (CR-01), index flags (SH-05),
/// dialog shortcuts (SH-19) and the router's command list (SH-16, SH-21).
@MainActor
final class FinderIntegrationTests: XCTestCase {

    func testCreateRepositoryArguments() {
        let folder = PangolinPath("/tmp/new project")
        XCTAssertEqual(CreateRepoWindowController.initArguments(folder: folder, bare: false), ["init", "--", "/tmp/new project"])
        XCTAssertEqual(CreateRepoWindowController.initArguments(folder: folder, bare: true), ["init", "--bare", "--", "/tmp/new project"])
    }

    func testSpecialFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(CreateRepoWindowController.isSpecialFolder(PangolinPath("/")))
        XCTAssertTrue(CreateRepoWindowController.isSpecialFolder(PangolinPath(home)))
        XCTAssertTrue(CreateRepoWindowController.isSpecialFolder(PangolinPath(home + "/Documents")))
        XCTAssertTrue(CreateRepoWindowController.isSpecialFolder(PangolinPath("/Volumes/External")))
        XCTAssertFalse(CreateRepoWindowController.isSpecialFolder(PangolinPath(home + "/Documents/project")))
        XCTAssertFalse(CreateRepoWindowController.isSpecialFolder(PangolinPath("/Volumes/External/project")))
    }

    func testEveryFinderCommandHasARouteOrIsPending() {
        // "inaccessible" is the disabled hint shown for unreadable repositories, not a command.
        let pending: Set<String> = ["inaccessible"]
        for entry in ShellMenuCatalog.entries where PangolinCommand(rawValue: entry.command) == nil {
            XCTAssertTrue(pending.contains(entry.command), "\(entry.command) has no PangolinCommand")
        }
        XCTAssertTrue(PangolinCommand.createRepo.worksOutsideRepository)
        XCTAssertTrue(PangolinCommand.log.worksOnBareRepository)
        XCTAssertFalse(PangolinCommand.commit.worksOnBareRepository)
    }

    func testTableCopyUsesVisibleCellText() {
        final class Source: NSObject, NSTableViewDataSource, NSTableViewDelegate {
            func numberOfRows(in tableView: NSTableView) -> Int { 2 }
            func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
                if tableColumn?.identifier.rawValue == "check" { return NSButton(checkboxWithTitle: "", target: nil, action: nil) }
                return NSTextField(labelWithString: "\(tableColumn?.identifier.rawValue ?? "")\(row)")
            }
        }
        let source = Source()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        for id in ["check", "status", "path"] {
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)))
        }
        table.dataSource = source
        table.delegate = source
        table.reloadData()
        XCTAssertEqual(DialogShortcuts.text(ofRows: IndexSet([0, 1]), in: table), "status0\tpath0\nstatus1\tpath1")
    }

    func testFindsSearchField() {
        let root = NSView()
        let inner = NSView()
        let field = NSSearchField()
        inner.addSubview(NSTextField())
        inner.addSubview(field)
        root.addSubview(inner)
        XCTAssertTrue(DialogShortcuts.firstSearchField(in: root) === field)
    }
}
#endif
