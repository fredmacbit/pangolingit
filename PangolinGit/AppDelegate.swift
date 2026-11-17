import Cocoa
import PangolinGitCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var launcher: LauncherWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        PangolinLog.general.info("PangolinGit application launched.")
        MainMenuBuilder.setupMenu()

        // Usually Finder starts PangolinGit in the background for a context-menu command; the first
        // one also brings up the first-run wizard, the way TortoiseGit's First Start Wizard does.
        if !ConfigManager.shared.hasCompletedFirstRun {
            CommandRouter.shared.execute(command: .firstRun, paths: [])
        } else {
            ExtensionHelper.shared.promptIfNeeded()
            // False when launched to open a `pangolingit://` URL from the Finder extension.
            let isDefaultLaunch = aNotification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
            if isDefaultLaunch {
                openedDirectly()
            }
        }
        UpdateChecker.shared.checkAutomaticallyIfDue()
    }

    /// Recent repositories with their everyday commands (PR-09).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        RecentRepositoriesMenu.shared.dockMenu()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openedDirectly() }
        return true
    }

    /// Opening PangolinGit from Launchpad or /Applications shows Settings, like TortoiseGit's
    /// Start-menu entry; everything else is reached from the Finder context menu.
    private func openedDirectly() {
        CommandRouter.shared.execute(command: .settings, paths: [])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay resident in the background (AppPresence hides the Dock icon): Finder sends a URL per
        // context-menu action and a warm process opens dialogs instantly.
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - URL Scheme

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        CommandRouter.shared.handleURL(url)
    }

    // MARK: - Documents

    /// `.patch` / `.diff` files opened from Finder (*Open With ▸ PangolinGit*) show in the patch
    /// viewer, as TortoiseGit opens them in TortoiseGitUDiff. `pangolingit://` URLs keep going
    /// through `handleGetURL`, whose Apple-event handler takes precedence.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            PatchViewerWindowController.present(url)
        }
    }

    // MARK: - Launcher

    @objc func showLauncher(_ sender: Any? = nil) {
        if launcher == nil {
            launcher = LauncherWindowController()
        }
        launcher?.reload()
        launcher?.showWindow(nil)
        launcher?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu Actions

    @IBAction func openPreferences(_ sender: Any?) {
        CommandRouter.shared.execute(command: .settings, paths: [])
    }

    @IBAction func showAbout(_ sender: Any?) {
        CommandRouter.shared.execute(command: .about, paths: [])
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        UpdateChecker.shared.checkForUpdates(userInitiated: true)
    }

    @IBAction func menuClone(_ sender: Any?) {
        CommandRouter.shared.execute(command: .clone, paths: [])
    }

    @IBAction func menuOpenRepository(_ sender: Any?) {
        showLauncher()
        launcher?.openRepository(sender)
    }

    /// Runs a repository command against the frontmost dialog's repository, else asks for one.
    private func runForCurrentRepository(_ command: PangolinCommand) {
        if let repo = WindowRegistry.shared.currentRepository {
            CommandRouter.shared.execute(command: command, targetPath: repo.rawPath)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose a Git working tree"
        if let recent = ConfigManager.shared.recentRepositories.first {
            panel.directoryURL = URL(fileURLWithPath: recent)
        }
        if panel.runModal() == .OK, let url = panel.url {
            CommandRouter.shared.execute(command: command, targetPath: url.path)
        }
    }

    @IBAction func menuCommit(_ sender: Any?) { runForCurrentRepository(.commit) }
    @IBAction func menuPull(_ sender: Any?) { runForCurrentRepository(.pull) }
    @IBAction func menuPush(_ sender: Any?) { runForCurrentRepository(.push) }
    @IBAction func menuSync(_ sender: Any?) { runForCurrentRepository(.sync) }
    @IBAction func menuLog(_ sender: Any?) { runForCurrentRepository(.log) }
    @IBAction func menuChanged(_ sender: Any?) { runForCurrentRepository(.changed) }
    @IBAction func menuBranch(_ sender: Any?) { runForCurrentRepository(.switch) }
    @IBAction func menuStash(_ sender: Any?) { runForCurrentRepository(.stash) }

    @IBAction func menuHelpDocs(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/fredmacbit/pangolingit/wiki")!)
    }

    @IBAction func menuReportIssue(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/fredmacbit/pangolingit/issues")!)
    }
}
