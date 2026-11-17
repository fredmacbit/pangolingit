import Cocoa

/// Constructs the standard macOS main application menu bar programmatically (Phase 4.6).
enum MainMenuBuilder {
    
    @MainActor
    static func setupMenu() {
        let mainMenu = NSMenu()
        
        // 1. Application Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = "PangolinGit"
        
        let aboutItem = NSMenuItem(title: "About \(appName)", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(aboutItem)
        
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(checkUpdatesItem)
        
        appMenu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.openPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(prefsItem)
        
        appMenu.addItem(NSMenuItem.separator())
        
        let hideItem = NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)
        
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        
        let showAllItem = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(showAllItem)
        
        appMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        // 2. File Menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        
        let cloneItem = NSMenuItem(title: "Clone Repository...", action: #selector(AppDelegate.menuClone(_:)), keyEquivalent: "C")
        cloneItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(cloneItem)
        
        let openRepoItem = NSMenuItem(title: "Open Repository...", action: #selector(AppDelegate.menuOpenRepository(_:)), keyEquivalent: "o")
        fileMenu.addItem(openRepoItem)
        fileMenu.addItem(RecentRepositoriesMenu.shared.openRecentMenuItem())
        
        fileMenu.addItem(NSMenuItem.separator())
        
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(closeItem)
        
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        
        // 3. Edit Menu (Standard text editing shortcuts)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 3b. View Menu: dialog shortcuts handled through the responder chain (`DialogShortcuts.swift`, SH-19)
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Refresh", action: #selector(NSWindow.pangolinRefresh(_:)), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Find…", action: #selector(NSWindow.pangolinFocusSearchField(_:)), keyEquivalent: "f")
        viewMenu.addItem(withTitle: "Confirm Dialog", action: #selector(NSWindow.pangolinPerformDefaultAction(_:)), keyEquivalent: "\r")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 4. Repository Menu
        let repoMenuItem = NSMenuItem()
        let repoMenu = NSMenu(title: "Repository")
        
        let commitItem = NSMenuItem(title: "Commit...", action: #selector(AppDelegate.menuCommit(_:)), keyEquivalent: "k")
        repoMenu.addItem(commitItem)
        
        let pullItem = NSMenuItem(title: "Pull...", action: #selector(AppDelegate.menuPull(_:)), keyEquivalent: "P")
        pullItem.keyEquivalentModifierMask = [.command, .shift]
        repoMenu.addItem(pullItem)
        
        let pushItem = NSMenuItem(title: "Push...", action: #selector(AppDelegate.menuPush(_:)), keyEquivalent: "p")
        repoMenu.addItem(pushItem)
        
        let syncItem = NSMenuItem(title: "Sync...", action: #selector(AppDelegate.menuSync(_:)), keyEquivalent: "s")
        syncItem.keyEquivalentModifierMask = [.command, .shift]
        repoMenu.addItem(syncItem)
        
        repoMenu.addItem(NSMenuItem.separator())
        
        let logItem = NSMenuItem(title: "Show Log...", action: #selector(AppDelegate.menuLog(_:)), keyEquivalent: "l")
        repoMenu.addItem(logItem)
        
        let changedItem = NSMenuItem(title: "Check for Modifications...", action: #selector(AppDelegate.menuChanged(_:)), keyEquivalent: "M")
        changedItem.keyEquivalentModifierMask = [.command, .shift]
        repoMenu.addItem(changedItem)
        
        let branchItem = NSMenuItem(title: "Switch / Checkout...", action: #selector(AppDelegate.menuBranch(_:)), keyEquivalent: "b")
        repoMenu.addItem(branchItem)
        
        let stashItem = NSMenuItem(title: "Stash Changes...", action: #selector(AppDelegate.menuStash(_:)), keyEquivalent: "y")
        repoMenu.addItem(stashItem)
        
        repoMenuItem.submenu = repoMenu
        mainMenu.addItem(repoMenuItem)
        
        // 5. Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Repositories", action: #selector(AppDelegate.showLauncher(_:)), keyEquivalent: "0")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        
        // 6. Help Menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        
        helpMenu.addItem(withTitle: "PangolinGit Documentation", action: #selector(AppDelegate.menuHelpDocs(_:)), keyEquivalent: "?")
        helpMenu.addItem(withTitle: "Report an Issue...", action: #selector(AppDelegate.menuReportIssue(_:)), keyEquivalent: "")
        
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }
}
