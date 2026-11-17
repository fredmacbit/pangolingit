import XCTest
import Cocoa
@testable import PangolinGitCore
@testable import PangolinGit

/// Smoke tests for the integrations / platform dialogs (P9/P10).
final class IntegrationDialogTests: XCTestCase {

    @MainActor
    func testDaemonCloneURLs() {
        let urls = DaemonWindowController.cloneURLs(port: 9418)
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(urls.allSatisfy { $0.hasPrefix("git://") && $0.hasSuffix("/") })
        XCTAssertFalse(urls.contains { $0.contains(":9418") }, "the default port is implied")
        XCTAssertTrue(DaemonWindowController.cloneURLs(port: 9000).allSatisfy { $0.hasSuffix(":9000/") })
    }

    @MainActor
    func testSettingsPanesLoad() {
        let panes: [NSViewController] = [RepositorySettingsViewController(), IssueTrackerSettingsViewController(),
                                         HooksSettingsViewController(), AdvancedSettingsViewController(),
                                         SavedDataSettingsViewController()]
        for pane in panes {
            XCTAssertGreaterThan(pane.view.subviews.count, 0, "\(type(of: pane)) has no content")
        }
    }

    @MainActor
    func testAboutAndSSHWindowsBuild() {
        let about = AboutWindowController()
        XCTAssertEqual(about.window?.title, "About PangolinGit")
        let ssh = SSHKeyWindowController()
        XCTAssertEqual(ssh.window?.title, "SSH Keys")
        let known = KnownHostsWindowController()
        XCTAssertNotNil(known.window?.contentView)
    }

    @MainActor
    func testUpdateWindowShowsRelease() {
        let release = ReleaseInfo(version: "9.9.9", name: "v9.9.9", notes: "* **New** things", pageURL: nil,
                                  publishedAt: nil, isPrerelease: false, assets: [])
        let window = UpdateWindowController(release: release, currentVersion: "1.0.0")
        XCTAssertEqual(window.window?.title, "Software Update")
    }

    @MainActor
    func testRecentRepositoriesMenus() {
        let dock = RecentRepositoriesMenu.shared.dockMenu()
        XCTAssertEqual(dock.items.last?.title, "Clone Repository…")
        let commands = RecentRepositoriesMenu.shared.commandMenu(for: "/tmp")
        XCTAssertTrue(commands.items.contains { $0.title == "Show Log" })
    }
}
