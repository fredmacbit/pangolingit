import Cocoa
import PangolinGitCore

/// General settings view controller.
public final class GeneralSettingsViewController: NSViewController {
    private let gitPathField = NSTextField()
    private let unversionedCheckbox = NSButton(checkboxWithTitle: "Show badges for unversioned / untracked files", target: nil, action: nil)
    private let ignoredCheckbox = NSButton(checkboxWithTitle: "Show badges for ignored files", target: nil, action: nil)
    private let depthField = NSTextField()
    
    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 380))
        setupUI()
        loadData()
        // SE-03: git version, extra PATH, wizard, update check, language (GeneralSettingsExtras.swift).
        installExtras(below: depthField)
    }
    
    private func setupUI() {
        let labelGit = NSTextField(labelWithString: "Git Executable Path:")
        labelGit.translatesAutoresizingMaskIntoConstraints = false
        gitPathField.translatesAutoresizingMaskIntoConstraints = false
        
        let browseButton = NSButton(title: "Browse...", target: self, action: #selector(onBrowseClicked))
        browseButton.bezelStyle = .rounded
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        
        unversionedCheckbox.translatesAutoresizingMaskIntoConstraints = false
        ignoredCheckbox.translatesAutoresizingMaskIntoConstraints = false
        for checkbox in [unversionedCheckbox, ignoredCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(onCheckboxChanged)
        }
        
        let labelDepth = NSTextField(labelWithString: "Folder Status Scan Depth:")
        labelDepth.translatesAutoresizingMaskIntoConstraints = false
        depthField.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(labelGit)
        view.addSubview(gitPathField)
        view.addSubview(browseButton)
        view.addSubview(unversionedCheckbox)
        view.addSubview(ignoredCheckbox)
        view.addSubview(labelDepth)
        view.addSubview(depthField)
        
        NSLayoutConstraint.activate([
            labelGit.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            labelGit.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            gitPathField.topAnchor.constraint(equalTo: labelGit.bottomAnchor, constant: 6),
            gitPathField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            gitPathField.trailingAnchor.constraint(equalTo: browseButton.leadingAnchor, constant: -8),
            
            browseButton.centerYAnchor.constraint(equalTo: gitPathField.centerYAnchor),
            browseButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            unversionedCheckbox.topAnchor.constraint(equalTo: gitPathField.bottomAnchor, constant: 18),
            unversionedCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            ignoredCheckbox.topAnchor.constraint(equalTo: unversionedCheckbox.bottomAnchor, constant: 10),
            ignoredCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            labelDepth.topAnchor.constraint(equalTo: ignoredCheckbox.bottomAnchor, constant: 18),
            labelDepth.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            depthField.leadingAnchor.constraint(equalTo: labelDepth.trailingAnchor, constant: 8),
            depthField.centerYAnchor.constraint(equalTo: labelDepth.centerYAnchor),
            depthField.widthAnchor.constraint(equalToConstant: 60)
        ])
    }
    
    public func loadData() {
        let config = ConfigManager.shared
        gitPathField.stringValue = config.gitExecutablePath
        unversionedCheckbox.state = config.showUnversionedOverlay ? .on : .off
        ignoredCheckbox.state = config.showIgnoredOverlay ? .on : .off
        depthField.stringValue = "\(config.recursiveStatusDepth)"
    }
    
    public func save() {
        let config = ConfigManager.shared
        config.gitExecutablePath = gitPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.showUnversionedOverlay = (unversionedCheckbox.state == .on)
        config.showIgnoredOverlay = (ignoredCheckbox.state == .on)
        if let depth = Int(depthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            config.recursiveStatusDepth = depth
        }
        saveExtras()
    }
    
    @objc private func onCheckboxChanged() {
        save()
    }
    
    @objc private func onBrowseClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            gitPathField.stringValue = url.path
            save()
        }
    }
}

/// Settings dialog window controller mirroring TortoiseGit's Settings (`src/TortoiseProc/Settings/`).
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    
    private let tabViewController = SavingTabViewController()
    
    private let generalVC = GeneralSettingsViewController()
    private let contextMenuVC = ContextMenuSettingsViewController()
    private let dialogsVC = DialogSettingsViewController()
    private let colorsVC = ColorsSettingsViewController()
    private let externalToolsVC = ExternalToolsSettingsViewController()
    private let networkVC = NetworkProxySettingsViewController()
    private let hooksVC = HooksSettingsViewController()
    private let advancedVC = AdvancedSettingsViewController()
    private let savedDataVC = SavedDataSettingsViewController()
    private let blameVC = BlameSettingsViewController()
    private let credentialsVC = GitCredentialViewController()
    private let logVC = LogSettingsViewController()
    private let gitConfigVC = GitConfigSettingsViewController()
    private let remotesVC = RemoteSettingsViewController()
    private let overlaysVC = OverlaysSettingsViewController()
    private let repositoryVC = RepositorySettingsViewController()
    private let issueTrackerVC = IssueTrackerSettingsViewController()
    /// Set after importing settings so closing the window does not write the old control values back.
    var suppressSave = false

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 680, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PangolinGit Settings"
        super.init(window: window)
        
        setupTabs()
        window.delegate = self
        // Text fields have no individual actions; persist whenever any field finishes editing.
        NotificationCenter.default.addObserver(self, selector: #selector(textDidEndEditing(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: nil)
        tabViewController.willLeavePane = { [weak self] in self?.saveAll() }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupTabs() {
        tabViewController.tabStyle = .toolbar
        
        let panes: [(vc: NSViewController, title: String, icon: String)] = [
            (generalVC, "General", "gearshape"),
            (contextMenuVC, "Context Menu", "list.bullet.rectangle"),
            (overlaysVC, "Overlays", "app.badge"),
            (dialogsVC, "Dialogs", "macwindow"),
            (colorsVC, "Colors", "paintpalette"),
            (externalToolsVC, "Tools", "hammer"),
            (networkVC, "Network", "network"),
            (credentialsVC, "Credentials", "key"),
            (hooksVC, "Hooks", "terminal"),
            (blameVC, "Blame", "clock.arrow.circlepath"),
            (savedDataVC, "Saved Data", "cylinder"),
            (advancedVC, "Advanced", "slider.horizontal.3"),
            (logVC, "Log", "clock.arrow.circlepath"),
            (gitConfigVC, "Git", "chevron.left.forwardslash.chevron.right"),
            (remotesVC, "Remote", "server.rack"),
            (repositoryVC, "Repository", "folder.badge.gearshape"),
            (issueTrackerVC, "Issue Tracker", "ladybug")
        ]
        
        for pane in panes {
            let tabItem = NSTabViewItem(viewController: pane.vc)
            tabItem.label = pane.title
            tabItem.image = NSImage(systemSymbolName: pane.icon, accessibilityDescription: pane.title)
            tabViewController.addTabViewItem(tabItem)
        }
        
        window?.contentViewController = tabViewController
    }
    
    @objc private func textDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSView, field.window === window else { return }
        saveAll()
    }
    
    public func windowWillClose(_ notification: Notification) {
        saveAll()
    }
    
    /// Saves every pane the user has opened. Panes whose view never loaded are skipped: their
    /// controls are empty and would overwrite the stored values.
    public func saveAll() {
        guard !suppressSave else { return }
        if generalVC.isViewLoaded { generalVC.save() }
        if contextMenuVC.isViewLoaded { contextMenuVC.save() }
        if dialogsVC.isViewLoaded { dialogsVC.save() }
        if colorsVC.isViewLoaded { colorsVC.save() }
        if externalToolsVC.isViewLoaded { externalToolsVC.save() }
        if networkVC.isViewLoaded { networkVC.save() }
        if credentialsVC.isViewLoaded { credentialsVC.save() }
        if hooksVC.isViewLoaded { hooksVC.save() }
        if blameVC.isViewLoaded { blameVC.save() }
        if advancedVC.isViewLoaded { advancedVC.save() }
        if logVC.isViewLoaded { logVC.save() }
        if overlaysVC.isViewLoaded { overlaysVC.save() }
        if repositoryVC.isViewLoaded { repositoryVC.save() }
        if issueTrackerVC.isViewLoaded { issueTrackerVC.save() }
    }

    /// Selects a pane by id (`pangolingit://settings?page=hooks`, TortoiseGit's `/page:`): the pane
    /// title in lower case without spaces, or its position (0-based).
    public static func showPage(_ page: String) {
        guard let controller = NSApp.windows.compactMap({ $0.windowController as? SettingsWindowController }).first,
              let tabs = controller.window?.contentViewController as? NSTabViewController else { return }
        let wanted = page.lowercased().replacingOccurrences(of: " ", with: "")
        let index = Int(wanted) ?? tabs.tabViewItems.firstIndex {
            $0.label.lowercased().replacingOccurrences(of: " ", with: "") == wanted
        }
        if let index, index >= 0, index < tabs.tabViewItems.count {
            tabs.selectedTabViewItemIndex = index
        }
    }
}

/// Tab controller that reports when the user leaves a pane, so its edits are saved.
private final class SavingTabViewController: NSTabViewController {
    var willLeavePane: (() -> Void)?
    
    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        willLeavePane?()
        super.tabView(tabView, willSelect: tabViewItem)
    }
}
