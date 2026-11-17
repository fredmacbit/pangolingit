import Cocoa
import PangolinGitCore

/// *Submodule Add…* (TortoiseGit's `SubmoduleAddDlg.cpp`): repository URL, path (with Browse),
/// optional branch (`-b`) and *Force* (`--force`).
@MainActor
final class SubmoduleAddWindowController: NSWindowController, NSComboBoxDelegate {

    private let repositoryPath: PangolinPath
    private let urlCombo = NSComboBox()
    private let pathField = NSTextField()
    private let branchCheck = NSButton(checkboxWithTitle: "Branch:", target: nil, action: nil)
    private let branchField = NSTextField()
    private let forceCheck = NSButton(checkboxWithTitle: "Force (--force)", target: nil, action: nil)
    /// Whether the path still follows the URL (stops once the user edits it).
    private var pathIsAutomatic = true
    /// Folder the submodule is added into (the clicked folder).
    private let baseFolder: String

    /// - Parameter folder: repository-relative folder the submodule goes into (the clicked folder).
    init(repositoryPath: PangolinPath, folder: String = "") {
        self.repositoryPath = repositoryPath
        self.baseFolder = folder
        super.init(window: ToolDialog.window(title: "Add Submodule", repository: repositoryPath, width: 560, height: 220, resizable: false))
        setupUI(folder: folder)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(folder: String) {
        guard let content = window?.contentView else { return }
        urlCombo.placeholderString = "https://example.com/library.git"
        urlCombo.addItems(withObjectValues: ConfigManager.shared.recentUrls)
        urlCombo.completes = true
        urlCombo.delegate = self
        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           GitURL.looksLikeRemoteURL(clip) {
            urlCombo.stringValue = clip
        }
        pathField.placeholderString = "Path inside the repository, e.g. vendor/library"
        pathField.stringValue = folder
        pathField.delegate = self
        let browse = ClosureButton(title: "Browse…") { [weak self] in self?.browsePath() }
        browse.bezelStyle = .rounded
        let pathRow = NSStackView(views: [pathField, browse])
        pathRow.spacing = 6
        branchField.isEnabled = false
        branchField.placeholderString = "Branch to track"
        branchCheck.target = self
        branchCheck.action = #selector(branchToggled)
        let branchRow = NSStackView(views: [branchCheck, branchField])
        branchRow.spacing = 6

        let grid = NSGridView(views: [
            [ToolDialog.label("Repository:"), urlCombo],
            [ToolDialog.label("Path:"), pathRow],
            [NSGridCell.emptyContentView, branchRow],
            [NSGridCell.emptyContentView, forceCheck]
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        urlCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 310).isActive = true
        branchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Add", target: self, action: #selector(addClicked))
        ok.keyEquivalent = "\r"
        let buttons = ToolDialog.buttonRow([cancel, ok])
        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate(LayoutHelper.pinEdges(stack, to: content) + [buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        suggestPath()
    }

    @objc private func branchToggled() {
        branchField.isEnabled = branchCheck.state == .on
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === pathField {
            pathIsAutomatic = pathField.stringValue.isEmpty || pathField.stringValue == baseFolder
        } else {
            suggestPath()
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.suggestPath() }
    }

    /// Fills the path from the URL's repository name, inside the clicked folder.
    private func suggestPath() {
        guard pathIsAutomatic, let name = GitURL.repositoryName(from: urlCombo.stringValue) else { return }
        pathField.stringValue = baseFolder.isEmpty ? name : "\(baseFolder)/\(name)"
    }

    private func browsePath() {
        guard let url = ToolDialog.chooseFolder(title: "Choose the Submodule Folder",
                                                initial: repositoryPath.appendingPathComponent(pathField.stringValue).rawPath) else { return }
        guard let relative = PangolinPath(url: url).relative(to: repositoryPath) else {
            ToolDialog.showMessage("Outside the repository", "Choose a folder inside “\(repositoryPath.rawPath)”.", in: window, style: .warning)
            return
        }
        pathField.stringValue = relative
        pathIsAutomatic = false
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func addClicked() {
        let url = urlCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !path.isEmpty else {
            ToolDialog.showMessage("Incomplete", "Enter the repository URL and the path.", in: window, style: .warning)
            return
        }
        var args = ["submodule", "add"]
        let branch = branchField.stringValue.trimmingCharacters(in: .whitespaces)
        if branchCheck.state == .on, !branch.isEmpty { args += ["-b", branch] }
        if forceCheck.state == .on { args.append("--force") }
        args += ["--", url, path]
        ConfigManager.shared.addRecentUrl(url)
        let root = repositoryPath
        window?.close()
        ProgressWindowController.run(title: "Add Submodule", commands: [args], workingDirectory: root, postActions: { outcome in
            guard outcome.succeeded else { return [] }
            return [.init("Commit…") { CommandRouter.shared.execute(command: .commit, targetPath: root.rawPath) }]
        })
    }
}

extension SubmoduleAddWindowController: NSTextFieldDelegate {}

/// *Submodule Update…* (TortoiseGit's `SubmoduleUpdateDlg.cpp`): choose the submodules (those under
/// the clicked folder are preselected, *Whole project* selects all) and the update options.
@MainActor
final class SubmoduleUpdateWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let repositoryPath: PangolinPath
    private var submodules: [GitSubmoduleInfo] = []
    private var checked = Set<String>()
    private let preselect: [String]
    private let tableView = NSTableView()
    private let wholeProjectCheck = NSButton(checkboxWithTitle: "Whole project", target: nil, action: nil)
    private let initCheck = NSButton(checkboxWithTitle: "Initialize (--init)", target: nil, action: nil)
    private let recursiveCheck = NSButton(checkboxWithTitle: "Recursive (--recursive)", target: nil, action: nil)
    private let forceCheck = NSButton(checkboxWithTitle: "Force (--force)", target: nil, action: nil)
    private let noFetchCheck = NSButton(checkboxWithTitle: "No fetch (--no-fetch)", target: nil, action: nil)
    private let remoteCheck = NSButton(checkboxWithTitle: "Remote tracking branch (--remote)", target: nil, action: nil)
    private let modePopup = NSPopUpButton()

    /// - Parameter paths: repository-relative folders or submodule paths to preselect; empty = all.
    init(repositoryPath: PangolinPath, paths: [String] = []) {
        self.repositoryPath = repositoryPath
        self.preselect = paths
        super.init(window: ToolDialog.window(title: "Update Submodules", repository: repositoryPath, width: 560, height: 460))
        setupUI()
        load()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        let check = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check"))
        check.width = 24
        check.title = ""
        tableView.addTableColumn(check)
        let path = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        path.title = "Submodule"
        path.width = 420
        tableView.addTableColumn(path)
        tableView.dataSource = self
        tableView.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        wholeProjectCheck.target = self
        wholeProjectCheck.action = #selector(wholeProjectToggled)
        initCheck.state = .on
        recursiveCheck.state = .on
        modePopup.addItems(withTitles: ["Checkout (default)", "Merge (--merge)", "Rebase (--rebase)"])
        let modeRow = NSStackView(views: [ToolDialog.label("Update by:"), modePopup])
        let options = NSGridView(views: [[initCheck, forceCheck], [recursiveCheck, noFetchCheck], [remoteCheck, modeRow]])
        options.rowSpacing = 4
        options.columnSpacing = 20

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Update", target: self, action: #selector(updateClicked))
        ok.keyEquivalent = "\r"
        let buttons = ToolDialog.buttonRow([cancel, ok])

        let stack = NSStackView(views: [scroll, wholeProjectCheck, options, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate(LayoutHelper.pinEdges(stack, to: content) + [
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func load() {
        let root = repositoryPath
        Task { @MainActor in
            let items = await SubmoduleWindowController.loadSubmodules(root)
            self.submodules = items
            let initial = GitSubmoduleInfo.filter(items, under: self.preselect)
            self.checked = Set(initial.map(\.path))
            self.wholeProjectCheck.state = self.checked.count == items.count ? .on : .off
            self.tableView.reloadData()
        }
    }

    @objc private func wholeProjectToggled() {
        checked = wholeProjectCheck.state == .on ? Set(submodules.map(\.path)) : []
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { submodules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = submodules[row]
        if tableColumn?.identifier.rawValue == "check" {
            let box = ClosureButton(title: "") { [weak self] in
                guard let self else { return }
                if self.checked.contains(item.path) { self.checked.remove(item.path) } else { self.checked.insert(item.path) }
                self.wholeProjectCheck.state = self.checked.count == self.submodules.count ? .on : .off
            }
            box.setButtonType(.switch)
            box.state = checked.contains(item.path) ? .on : .off
            return box
        }
        let label = NSTextField(labelWithString: item.path + (item.state == .uninitialized ? "  (not initialized)" : ""))
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func updateClicked() {
        var options = GitSubmoduleInfo.UpdateOptions()
        options.initialize = initCheck.state == .on
        options.recursive = recursiveCheck.state == .on
        options.force = forceCheck.state == .on
        options.noFetch = noFetchCheck.state == .on
        options.remote = remoteCheck.state == .on
        options.mode = GitSubmoduleInfo.UpdateOptions.Mode(rawValue: modePopup.indexOfSelectedItem) ?? .checkout
        let selected = submodules.map(\.path).filter { checked.contains($0) }
        guard !selected.isEmpty else {
            ToolDialog.showMessage("Nothing selected", "Choose at least one submodule.", in: window, style: .warning)
            return
        }
        // The whole project is updated without a pathspec so new nested entries are included too.
        let paths = selected.count == submodules.count ? [] : selected
        window?.close()
        ProgressWindowController.run(title: "Update Submodules", commands: [options.arguments(paths: paths)], workingDirectory: repositoryPath)
    }
}

/// Shared submodule hooks for other dialogs (TortoiseGit offers *Update submodules* after
/// checkout, reset, pull and switch when the repository has submodules).
@MainActor
enum SubmoduleSupport {
    static func hasSubmodules(_ repository: PangolinPath) -> Bool {
        FileManager.default.fileExists(atPath: repository.appendingPathComponent(".gitmodules").rawPath)
    }

    /// A post action that opens Update Submodules, or nil when the repository has none.
    static func updatePostAction(repository: PangolinPath) -> ProgressWindowController.PostAction? {
        guard hasSubmodules(repository) else { return nil }
        return .init("Update Submodules…") {
            WindowRegistry.shared.present({ SubmoduleUpdateWindowController(repositoryPath: repository) }, repository: repository)
        }
    }
}
