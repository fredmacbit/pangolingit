import Cocoa
import PangolinGitCore

/// The parts of TortoiseGit's General settings page (`SetMainPage.cpp`) beyond git path and badges:
/// git version check, extra PATH, environment display, update check, first-start wizard and language.
/// Kept in an extension so the pane's original layout code stays untouched.
extension GeneralSettingsViewController {

    private enum ID {
        static let gitVersion = NSUserInterfaceItemIdentifier("general.gitVersion")
        static let extraPath = NSUserInterfaceItemIdentifier("general.extraPath")
        static let autoUpdate = NSUserInterfaceItemIdentifier("general.autoUpdate")
        static let prereleases = NSUserInterfaceItemIdentifier("general.prereleases")
        static let language = NSUserInterfaceItemIdentifier("general.language")
    }

    private func control<T: NSView>(_ identifier: NSUserInterfaceItemIdentifier) -> T? {
        view.subviews.lazy.compactMap { Self.find(identifier, in: $0) as? T }.first
    }

    private static func find(_ identifier: NSUserInterfaceItemIdentifier, in view: NSView) -> NSView? {
        if view.identifier == identifier { return view }
        for subview in view.subviews {
            if let match = find(identifier, in: subview) { return match }
        }
        return nil
    }

    /// Adds the extra controls under `anchor` (the last row of the original layout).
    func installExtras(below anchor: NSView) {
        let config = ConfigManager.shared

        let versionLabel = NSTextField(labelWithString: "Git version: …")
        versionLabel.identifier = ID.gitVersion
        versionLabel.textColor = .secondaryLabelColor
        let checkGit = button("Check Now", #selector(checkGitVersion), tip: "Run git --version with the configured git.")
        let environment = button("Show Environment…", #selector(showEnvironment),
                                 tip: "Show the environment variables git runs with (PATH, proxy, askpass, …).")
        let versionRow = row([versionLabel, checkGit, environment])

        let pathLabel = NSTextField(labelWithString: "Extra PATH:")
        let pathField = NSTextField(string: config.extraPath)
        pathField.identifier = ID.extraPath
        pathField.placeholderString = "/opt/tools/bin:/usr/local/opt/git-lfs/bin"
        pathField.toolTip = "Folders added in front of PATH for every git run, e.g. where git-lfs or a credential helper is installed."
        let pathRow = row([pathLabel, pathField])

        let autoUpdate = NSButton(checkboxWithTitle: "Check for updates automatically every week", target: self, action: #selector(extrasChanged))
        autoUpdate.identifier = ID.autoUpdate
        autoUpdate.state = config.automaticUpdateCheck ? .on : .off
        autoUpdate.toolTip = "Look for a newer PangolinGit once a week at launch."
        let prereleases = NSButton(checkboxWithTitle: "Include preview releases", target: self, action: #selector(extrasChanged))
        prereleases.identifier = ID.prereleases
        prereleases.state = config.updateIncludesPrereleases ? .on : .off
        prereleases.toolTip = "Also offer pre-releases (TortoiseGit's preview channel)."
        let checkUpdates = button("Check Now", #selector(checkForUpdatesNow), tip: "Check for a newer version now.")
        let updateRow = row([autoUpdate, prereleases, checkUpdates])

        let languageLabel = NSTextField(labelWithString: "Language:")
        let language = NSPopUpButton()
        language.identifier = ID.language
        language.toolTip = "User-interface language; takes effect after PangolinGit restarts."
        language.addItem(withTitle: "System default")
        let current = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first
        let explicit = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil
        for code in Bundle.main.localizations.filter({ $0 != "Base" }).sorted() {
            language.addItem(withTitle: Locale.current.localizedString(forIdentifier: code) ?? code)
            language.lastItem?.representedObject = code
            if explicit, code == current { language.select(language.lastItem) }
        }
        language.target = self
        language.action = #selector(languageChanged(_:))
        let wizard = button("Run First-Start Wizard…", #selector(runWizard), tip: "Go through git path, identity, authentication and Finder setup again.")
        let languageRow = row([languageLabel, language, NSView(), wizard])

        let stack = NSStackView(views: [versionRow, pathRow, updateRow, languageRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            languageRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        checkGitVersion()
    }

    func saveExtras() {
        guard isViewLoaded else { return }
        let config = ConfigManager.shared
        if let field: NSTextField = control(ID.extraPath) {
            config.extraPath = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let box: NSButton = control(ID.autoUpdate) { config.automaticUpdateCheck = box.state == .on }
        if let box: NSButton = control(ID.prereleases) { config.updateIncludesPrereleases = box.state == .on }
    }

    private func button(_ title: String, _ action: Selector, tip: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.toolTip = tip
        return button
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        return stack
    }

    @objc private func extrasChanged() {
        save()
    }

    /// `git --version` with the configured executable; reports a missing or broken git.
    @objc private func checkGitVersion() {
        save()
        guard let label: NSTextField = control(ID.gitVersion) else { return }
        label.stringValue = "Git version: checking…"
        Task { @MainActor in
            let runner = GitCLIRunner()
            let result = try? await runner.run(arguments: ["--version"])
            if let result, result.isSuccess {
                label.stringValue = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) + " (\(runner.executablePath))"
                label.textColor = .secondaryLabelColor
            } else {
                label.stringValue = "Git not found or not working at \(runner.executablePath)"
                label.textColor = .systemRed
            }
        }
    }

    @objc private func showEnvironment() {
        save()
        let environment = GitCLIRunner.makeEnvironment(overrides: nil)
        let text = environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Environment of git commands"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.runModal()
    }

    @objc private func checkForUpdatesNow() {
        save()
        UpdateChecker.shared.checkForUpdates(userInitiated: true)
    }

    @objc private func runWizard() {
        CommandRouter.shared.execute(command: .firstRun, paths: [])
    }

    /// Stores the app's `AppleLanguages` override (cleared for "System default").
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        if let code = sender.selectedItem?.representedObject as? String {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        let alert = NSAlert()
        alert.messageText = "Restart PangolinGit to change the language"
        alert.runModal()
    }
}
