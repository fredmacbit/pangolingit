import Foundation
import Cocoa
import PangolinGitCore

/// Browse References dialog (`BrowseRefsDlg.cpp` in TortoiseGit): a namespace tree (`refs` ▸ heads /
/// remotes / tags / notes, nested by `/`) beside a sortable list of the refs in the selected node with
/// tracked branch, last commit, authors, dates, SHA-1 and branch description. Filter (by name, subject,
/// author, SHA-1), merged / unmerged filter, context menus for switching, merging, rebasing, comparing,
/// renaming, tracking, fetching and (multi-)deleting, and a picker mode returning one ref or a pair.
public final class BrowseRefsWindowController: NSWindowController {

    public let repositoryPath: PangolinPath

    /// Picker mode (TortoiseGit's `…` buttons): called with the chosen ref name, then the window closes.
    private let pickerCompletion: ((String) -> Void)?
    /// Range picker (two refs, e.g. Compare Revisions): called with (older/first, second).
    private let rangeCompletion: ((String, String) -> Void)?
    private var isPicker: Bool { pickerCompletion != nil || rangeCompletion != nil }

    private var allRefs: [GitRefInfo] = []
    private var tree = GitRefTreeNode.build(from: [])
    private var descriptions: [String: String] = [:]
    private var remotes: [String] = []
    /// Full ref names merged (or not) into HEAD, depending on the branch filter; nil = no filter.
    private var mergeFilter: Set<String>?
    private var shownRefs: [GitRefInfo] = []
    private var selectedNodePath = "refs/heads"

    private let outlineView = NSOutlineView()
    private let tableView = RefsTableView()
    private let searchField = NSSearchField()
    private let mergedPopup = NSPopUpButton()
    private let nestedCheckbox = NSButton(checkboxWithTitle: "Show nested refs", target: nil, action: nil)
    private let infoLabel = NSTextField(labelWithString: "Loading references...")

    private enum FilterField: String, CaseIterable {
        case refname = "Refname", subject = "Subject", authors = "Authors", sha = "SHA-1"
    }
    private var filterFields = Set(FilterField.allCases)

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    public init(repositoryPath: PangolinPath, pickerCompletion: ((String) -> Void)? = nil,
                rangeCompletion: ((String, String) -> Void)? = nil) {
        self.repositoryPath = repositoryPath
        self.pickerCompletion = pickerCompletion
        self.rangeCompletion = rangeCompletion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let title = rangeCompletion != nil ? "Select Two References" : (pickerCompletion == nil ? "Browse References" : "Select Reference")
        window.title = "\(title) — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 760, height: 450)

        super.init(window: window)
        setupUI()
        loadReferences()
        RepositoryEvents.observe(repositoryPath, owner: self) { [weak self] in self?.loadReferences() }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI

    private func setupUI() {
        guard let content = window?.contentView else { return }

        searchField.placeholderString = "Filter references..."
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.searchMenuTemplate = filterMenu()
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        mergedPopup.addItems(withTitles: ["All branches", "Only merged to HEAD", "Only unmerged to HEAD"])
        mergedPopup.target = self
        mergedPopup.action = #selector(mergedFilterChanged)
        mergedPopup.toolTip = "git branch --merged / --no-merged HEAD"
        let currentButton = NSButton(title: "Current Branch", target: self, action: #selector(selectCurrentBranch))
        nestedCheckbox.target = self
        nestedCheckbox.action = #selector(filterChanged)
        nestedCheckbox.toolTip = "Also list the refs of the namespaces below the selected one"
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        let topRow = NSStackView(views: [searchField, mergedPopup, currentButton, nestedCheckbox, NSView(), refreshButton])

        // Namespace tree
        let treeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Node"))
        treeColumn.title = "References"
        outlineView.addTableColumn(treeColumn)
        outlineView.outlineTableColumn = treeColumn
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self
        let treeScroll = NSScrollView()
        treeScroll.hasVerticalScroller = true
        treeScroll.borderType = .bezelBorder
        treeScroll.documentView = outlineView

        // Ref list
        let columns: [(String, String, CGFloat)] = [
            ("Ref", "Ref", 200), ("Upstream", "Tracked Branch", 140), ("Subject", "Last Commit", 260), ("Author", "Last Author", 120),
            ("AuthorDate", "Last Author Date", 120), ("Committer", "Last Committer", 120), ("CommitDate", "Date Last Commit", 120),
            ("Hash", "SHA-1", 90), ("Description", "Description", 180)
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: !id.hasSuffix("Date"))
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(refDoubleClicked)
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        tableView.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = true
        listScroll.borderType = .bezelBorder
        listScroll.documentView = tableView

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(treeScroll)
        split.addArrangedSubview(listScroll)
        treeScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        treeScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        infoLabel.textColor = .secondaryLabelColor
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var buttons: [NSView] = []
        if isPicker {
            let select = NSButton(title: "Select", target: self, action: #selector(selectClicked))
            select.keyEquivalent = "\r"
            buttons.append(select)
        }
        let close = NSButton(title: isPicker ? "Cancel" : "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        buttons.append(close)
        let bottomRow = NSStackView(views: [infoLabel, NSView()] + buttons)

        for view in [topRow, split, bottomRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            topRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            topRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            split.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            split.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -10),
            bottomRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    /// The search field's menu choosing which columns the filter text matches (TortoiseGit's filter menu).
    private func filterMenu() -> NSMenu {
        let menu = NSMenu()
        for field in FilterField.allCases {
            let item = ClosureMenuItem(title: field.rawValue) { [weak self] in self?.toggleFilterField(field) }
            item.state = filterFields.contains(field) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func toggleFilterField(_ field: FilterField) {
        if filterFields.contains(field) {
            if filterFields.count > 1 { filterFields.remove(field) }
        } else {
            filterFields.insert(field)
        }
        searchField.searchMenuTemplate = filterMenu()
        filterChanged()
    }

    // MARK: - Loading

    private func loadReferences() {
        let root = repositoryPath
        Task { @MainActor in
            do {
                let output = try await GitCLIRunner.runAsync(arguments: ["for-each-ref", "--format=\(GitRefs.forEachRefFormat)"], workingDirectory: root)
                let descriptionOutput = (try? await GitCLIRunner.runAsync(
                    arguments: ["config", "-z", "--get-regexp", "^branch\\..*\\.description$"], workingDirectory: root)) ?? ""
                let remoteOutput = (try? await GitCLIRunner.runAsync(arguments: ["remote"], workingDirectory: root)) ?? ""
                self.allRefs = GitRefs.parseForEachRef(output)
                self.descriptions = GitRefs.parseBranchDescriptions(descriptionOutput)
                self.remotes = remoteOutput.split(separator: "\n").map(String.init)
                await self.loadMergeFilter()
                self.rebuildTree()
            } catch {
                self.infoLabel.stringValue = "Failed to load refs: \(error.localizedDescription)"
            }
        }
    }

    /// `for-each-ref --merged/--no-merged HEAD` for the branch filter (BR-04).
    private func loadMergeFilter() async {
        let index = mergedPopup.indexOfSelectedItem
        guard index > 0 else {
            mergeFilter = nil
            return
        }
        let flag = index == 1 ? "--merged=HEAD" : "--no-merged=HEAD"
        let output = (try? await GitCLIRunner.runAsync(arguments: ["for-each-ref", flag, "--format=%(refname)", "refs/heads", "refs/remotes"],
                                                       workingDirectory: repositoryPath)) ?? ""
        mergeFilter = Set(output.split(separator: "\n").map(String.init))
    }

    private func rebuildTree() {
        tree = GitRefTreeNode.build(from: allRefs)
        outlineView.reloadData()
        outlineView.expandItem(tree)
        for name in ["heads", "remotes"] {
            if let node = tree.child(named: name) { outlineView.expandItem(node) }
        }
        if tree.node(atPath: selectedNodePath) == nil { selectedNodePath = "refs/heads" }
        selectNode(atPath: selectedNodePath)
        filterChanged()
    }

    private func selectNode(atPath path: String) {
        guard let node = tree.node(atPath: path) else { return }
        // Expand the ancestors so the row exists.
        var ancestors: [GitRefTreeNode] = []
        var current: GitRefTreeNode? = tree
        while let node = current, node.path != path {
            ancestors.append(node)
            current = node.children.first { path == $0.path || path.hasPrefix($0.path + "/") }
        }
        ancestors.forEach { outlineView.expandItem($0) }
        let row = outlineView.row(forItem: node)
        if row >= 0 { outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    @objc private func mergedFilterChanged() {
        Task { @MainActor in
            await self.loadMergeFilter()
            self.filterChanged()
        }
    }

    /// Applies node, nested, merge and text filters, then the sort (BR-01, BR-04).
    @objc private func filterChanged() {
        let node = tree.node(atPath: selectedNodePath) ?? tree
        let text = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var refs = node.allRefs(nested: nestedCheckbox.state == .on || !text.isEmpty && node === tree)
        if let mergeFilter {
            refs = refs.filter { ($0.kind != .localBranch && $0.kind != .remoteBranch) || mergeFilter.contains($0.fullName) }
        }
        if !text.isEmpty {
            refs = refs.filter { ref in
                (filterFields.contains(.refname) && ref.shortName.lowercased().contains(text)) ||
                (filterFields.contains(.subject) && ref.subject.lowercased().contains(text)) ||
                (filterFields.contains(.authors) && (ref.authorName.lowercased().contains(text) || ref.committerName.lowercased().contains(text))) ||
                (filterFields.contains(.sha) && ref.commitHash.hasPrefix(text))
            }
        }
        shownRefs = sorted(refs)
        let selected = Set(selectedRefs.map(\.fullName))
        tableView.reloadData()
        let rows = IndexSet(shownRefs.indices.filter { selected.contains(shownRefs[$0].fullName) })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        updateInfo()
    }

    private func sorted(_ refs: [GitRefInfo]) -> [GitRefInfo] {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return refs }
        let ascending = descriptor.ascending
        func value(_ ref: GitRefInfo) -> String {
            switch key {
            case "Upstream": return ref.upstream
            case "Subject": return ref.subject
            case "Author": return ref.authorName
            case "Committer": return ref.committerName
            case "Hash": return ref.commitHash
            case "Description": return descriptions[ref.shortName] ?? ""
            default: return ref.shortName
            }
        }
        return refs.sorted { lhs, rhs in
            if key == "AuthorDate" || key == "CommitDate" {
                let l = (key == "AuthorDate" ? lhs.authorDate : lhs.committerDate) ?? .distantPast
                let r = (key == "AuthorDate" ? rhs.authorDate : rhs.committerDate) ?? .distantPast
                return ascending ? l < r : l > r
            }
            let order = value(lhs).localizedStandardCompare(value(rhs))
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private func updateInfo() {
        let selected = tableView.selectedRowIndexes.count
        infoLabel.stringValue = "Showing \(shownRefs.count) refs, \(selected) selected"
    }

    @objc private func refreshClicked() {
        loadReferences()
    }

    @objc private func selectCurrentBranch() {
        guard let head = allRefs.first(where: \.isHead) else {
            infoLabel.stringValue = "HEAD is detached."
            return
        }
        searchField.stringValue = ""
        selectedNodePath = (head.fullName as NSString).deletingLastPathComponent
        selectNode(atPath: selectedNodePath)
        filterChanged()
        if let row = shownRefs.firstIndex(where: \.isHead) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        window?.makeFirstResponder(tableView)
    }

    // MARK: - Selection & picking

    private var selectedRefs: [GitRefInfo] {
        tableView.selectedRowIndexes.compactMap { $0 < shownRefs.count ? shownRefs[$0] : nil }
    }

    @objc private func refDoubleClicked() {
        if isPicker {
            selectClicked()
        } else if let ref = selectedRefs.first {
            // TortoiseGit opens the log of the ref; until the Log can start at a ref the closest
            // read-only view is the comparison with HEAD (never a checkout on a double-click).
            let root = repositoryPath
            if ref.isHead {
                present { DiffWindowController(filePath: root, oldRevision: ref.shortName) }
            } else {
                present { FileDiffWindowController(repositoryPath: root, rev1: "HEAD", rev2: ref.shortName) }
            }
        }
    }

    @objc private func selectClicked() {
        let refs = selectedRefs
        if let rangeCompletion, refs.count == 2 {
            close()
            rangeCompletion(refs[0].shortName, refs[1].shortName)
        } else if let pickerCompletion, refs.count == 1 {
            close()
            pickerCompletion(refs[0].shortName)
        } else {
            infoLabel.stringValue = rangeCompletion != nil ? "Select two references." : "Select one reference."
        }
    }

    @objc private func closeClicked() {
        close()
    }

    /// F2 renames, Delete / ⌫ deletes, Return acts like a double-click.
    private func handleKey(_ key: RefsTableView.Key) -> Bool {
        let refs = selectedRefs
        switch key {
        case .rename:
            guard !isPicker, refs.count == 1, refs[0].kind == .localBranch else { return false }
            rename(refs[0])
        case .delete:
            guard !isPicker, !refs.isEmpty else { return false }
            delete(refs)
        case .enter:
            guard refs.count == 1 || (isPicker && refs.count == 2) else { return false }
            refDoubleClicked()
        }
        return true
    }

    // MARK: - Actions

    private var root: PangolinPath { repositoryPath }

    private func present(_ make: () -> NSWindowController) {
        WindowRegistry.shared.present(make, repository: repositoryPath)
    }

    /// Switch / checkout. A remote branch offers a local tracking branch instead of a detached HEAD (SW-03).
    private func switchTo(_ ref: GitRefInfo) {
        let root = repositoryPath
        switch ref.kind {
        case .localBranch:
            guard !ref.isHead else { return }
            run(GitSwitchOptions(target: ref.shortName), resultingBranch: ref.shortName)
        case .remoteBranch:
            let remote = GitRefs.remote(ofRemoteBranch: ref.shortName, remotes: remotes) ?? ""
            let localName = remote.isEmpty ? ref.shortName : String(ref.shortName.dropFirst(remote.count + 1))
            let localExists = allRefs.contains { $0.fullName == "refs/heads/\(localName)" }
            let alert = NSAlert()
            alert.messageText = "Switch to remote branch “\(ref.shortName)”?"
            if localExists {
                alert.informativeText = "A local branch “\(localName)” exists. Switch to it, or check out \(ref.shortName) as a detached HEAD."
                alert.addButton(withTitle: "Switch to \(localName)")
            } else {
                alert.informativeText = "Create a local branch “\(localName)” that tracks \(ref.shortName) and switch to it — or check out \(ref.shortName) as a detached HEAD."
                alert.addButton(withTitle: "Create Tracking Branch")
            }
            alert.addButton(withTitle: "Detached HEAD")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if localExists {
                    run(GitSwitchOptions(target: localName), resultingBranch: localName)
                } else {
                    var options = GitSwitchOptions(target: ref.shortName)
                    options.newBranch = localName
                    options.track = true
                    run(options, resultingBranch: localName)
                }
            case .alertSecondButtonReturn:
                run(GitSwitchOptions(target: ref.shortName), resultingBranch: nil)
            default:
                return
            }
        default:
            present { SwitchWindowController(repositoryPath: root, initialTarget: ref.shortName) }
        }
    }

    private func run(_ options: GitSwitchOptions, resultingBranch: String?) {
        let root = repositoryPath
        Task { @MainActor in
            let decision = await DirtyWorkingTree.prepare(root, operation: "switch", allowContinue: true, window: self.window)
            guard decision != .cancel else { return }
            SwitchWindowController.runCheckout(options, root: root, resultingBranch: resultingBranch, stashed: decision == .stashed)
        }
    }

    /// Deletes branches, remote branches and tags in one go (BR-07), warning about unmerged local branches.
    private func delete(_ refs: [GitRefInfo]) {
        let locals = refs.filter { $0.kind == .localBranch }
        let remoteBranches = refs.filter { $0.kind == .remoteBranch }
        let tags = refs.filter { $0.kind == .tag }
        let stash = refs.contains { $0.kind == .stash }
        if locals.contains(where: \.isHead) {
            showError("The current branch cannot be deleted. Switch to another branch first.")
            return
        }
        guard !locals.isEmpty || !remoteBranches.isEmpty || !tags.isEmpty || stash else { return }
        let root = repositoryPath
        Task { @MainActor in
            var unmerged: [String] = []
            if !locals.isEmpty {
                let output = (try? await GitCLIRunner.runAsync(arguments: ["for-each-ref", "--no-merged=HEAD", "--format=%(refname:short)", "refs/heads"],
                                                               workingDirectory: root)) ?? ""
                let notMerged = Set(output.split(separator: "\n").map(String.init))
                unmerged = locals.map(\.shortName).filter { notMerged.contains($0) }
            }
            var parts: [String] = []
            if !locals.isEmpty { parts.append(locals.count == 1 ? "branch “\(locals[0].shortName)”" : "\(locals.count) branches") }
            if !remoteBranches.isEmpty { parts.append(remoteBranches.count == 1 ? "remote branch “\(remoteBranches[0].shortName)”" : "\(remoteBranches.count) remote branches") }
            if !tags.isEmpty { parts.append(tags.count == 1 ? "tag “\(tags[0].shortName)”" : "\(tags.count) tags") }
            if stash { parts.append("all stashes") }
            let alert = NSAlert()
            alert.alertStyle = unmerged.isEmpty && remoteBranches.isEmpty ? .warning : .critical
            alert.messageText = "Delete \(parts.joined(separator: ", "))?"
            var info: [String] = []
            if !unmerged.isEmpty {
                info.append("Not merged into HEAD (their commits may be lost): \(unmerged.joined(separator: ", ")).")
            }
            if !remoteBranches.isEmpty {
                info.append("Remote branches are deleted on the server for everyone (git push --delete).")
            }
            if !tags.isEmpty {
                info.append("Tags are deleted locally only; use “Delete Remote Tags…” on a remote to remove them there.")
            }
            alert.informativeText = info.isEmpty ? "This cannot be undone from PangolinGit." : info.joined(separator: "\n\n")
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            var commands: [[String]] = []
            if !locals.isEmpty {
                commands.append(["branch", unmerged.isEmpty ? "--delete" : "-D"] + locals.map(\.shortName))
            }
            if !tags.isEmpty {
                commands.append(["tag", "--delete"] + tags.map(\.shortName))
            }
            var byRemote: [String: [String]] = [:]
            for ref in remoteBranches {
                guard let remote = GitRefs.remote(ofRemoteBranch: ref.shortName, remotes: self.remotes) else { continue }
                byRemote[remote, default: []].append(String(ref.shortName.dropFirst(remote.count + 1)))
            }
            for (remote, branches) in byRemote.sorted(by: { $0.key < $1.key }) {
                commands.append(["push", "--progress", remote, "--delete"] + branches)
            }
            if stash { commands.append(["stash", "clear"]) }
            ProgressWindowController.run(title: "Delete References", commands: commands, workingDirectory: root)
        }
    }

    /// Inline rename of a local branch (TortoiseGit edits the label in place; F2).
    private func rename(_ ref: GitRefInfo) {
        let root = repositoryPath
        let existing = Set(allRefs.filter { $0.kind == .localBranch }.map(\.shortName))
        let sheet = TextInputSheet(title: "Rename Branch", prompt: "New name for “\(ref.shortName)”:", initialText: ref.shortName,
                                   okTitle: "Rename", multiline: false)
        sheet.validator = { value in
            let name = value.trimmingCharacters(in: .whitespaces)
            if let error = GitRefName.validationError(name) { return error }
            return existing.contains(name) && name != ref.shortName ? "A branch with this name already exists." : nil
        }
        sheet.begin(on: window) { name in
            guard let name = name?.trimmingCharacters(in: .whitespaces), name != ref.shortName else { return }
            ProgressWindowController.run(title: "Rename Branch", commands: [["branch", "--move", ref.shortName, name]], workingDirectory: root)
        }
    }

    /// `branch.<name>.description` (git branch --edit-description needs an editor).
    private func editDescription(_ ref: GitRefInfo) {
        let root = repositoryPath
        let key = "branch.\(ref.shortName).description"
        let sheet = TextInputSheet(title: "Branch Description", prompt: "Description of “\(ref.shortName)”:",
                                   initialText: descriptions[ref.shortName] ?? "", okTitle: "Save", multiline: true)
        sheet.begin(on: window) { text in
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            Task { @MainActor in
                let args = text.isEmpty ? ["config", "--unset", key] : ["config", key, text]
                _ = try? await GitCLIRunner().run(arguments: args, workingDirectory: root)
                RepositoryEvents.post(root)
            }
        }
    }

    private func fetch(remote: String, branch: String? = nil) {
        ProgressWindowController.run(title: "Fetch \(remote)", commands: [["fetch", "--progress", remote] + (branch.map { [$0] } ?? [])],
                                     workingDirectory: repositoryPath)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    private static func copy(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Context menus (BR-06, BR-08)

extension BrowseRefsWindowController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === outlineView.menu {
            buildTreeMenu(menu)
        } else {
            let clicked = tableView.clickedRow
            guard clicked >= 0, clicked < shownRefs.count else { return }
            if !tableView.selectedRowIndexes.contains(clicked) {
                tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            }
            buildRefMenu(menu, refs: selectedRefs)
        }
    }

    private func item(_ title: String, _ symbol: String? = nil, _ handler: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, symbol: symbol, handler: handler)
    }

    private func buildRefMenu(_ menu: NSMenu, refs: [GitRefInfo]) {
        let root = repositoryPath
        if isPicker {
            menu.addItem(item("Select", "checkmark") { [weak self] in self?.selectClicked() })
            return
        }
        if refs.count == 2 {
            let (a, b) = (refs[0].shortName, refs[1].shortName)
            menu.addItem(item("Compare “\(a)” and “\(b)”", "arrow.left.arrow.right") { [weak self] in
                self?.present { FileDiffWindowController(repositoryPath: root, rev1: a, rev2: b) }
            })
            menu.addItem(item("Show Unified Diff", "plusminus") { [weak self] in
                self?.present { DiffWindowController(filePath: root, oldRevision: a, newRevision: b) }
            })
            menu.addItem(.separator())
        }
        if refs.count == 1, let ref = refs.first {
            let name = ref.shortName
            if ref.kind != .stash {
                if !ref.isHead {
                    menu.addItem(item("Switch/Checkout to This", "arrow.triangle.swap") { [weak self] in self?.switchTo(ref) })
                    menu.addItem(item("Merge to Current Branch…", "arrow.triangle.merge") { [weak self] in
                        self?.present { MergeBranchWindowController(repositoryPath: root, initialRevision: name) }
                    })
                    menu.addItem(item("Rebase Current Branch onto This…", "arrow.up.and.down.and.sparkles") { [weak self] in
                        self?.present { RebaseWindowController(repositoryPath: root, upstream: name) }
                    })
                }
                menu.addItem(item(ref.kind == .remoteBranch ? "Create Branch from Remote Branch…" : "Create Branch from This…", "arrow.branch") { [weak self] in
                    self?.present { CreateBranchTagWindowController(repositoryPath: root, initialBase: name) }
                })
                menu.addItem(item("Create Tag at This…", "tag") { [weak self] in
                    self?.present { CreateBranchTagWindowController(repositoryPath: root, initialBase: name, createTag: true) }
                })
                menu.addItem(.separator())
            }
            menu.addItem(item("Show RefLog", "clock.arrow.circlepath") { [weak self] in
                self?.present { RefLogWindowController(repositoryPath: root, ref: ref.fullName) }
            })
            menu.addItem(item("Browse Repository", "folder") { [weak self] in
                self?.present { RepoBrowserWindowController(repositoryPath: root, initialRevision: name) }
            })
            menu.addItem(item("Compare with Working Tree", "doc.on.doc") { [weak self] in
                self?.present { DiffWindowController(filePath: root, oldRevision: name) }
            })
            if !ref.isHead {
                menu.addItem(item("Compare with HEAD", "arrow.left.arrow.right") { [weak self] in
                    self?.present { FileDiffWindowController(repositoryPath: root, rev1: "HEAD", rev2: name) }
                })
            }
            if ref.kind == .remoteBranch, let remote = GitRefs.remote(ofRemoteBranch: name, remotes: remotes) {
                menu.addItem(.separator())
                menu.addItem(item("Fetch “\(name)” from \(remote)", "arrow.down.circle") { [weak self] in
                    self?.fetch(remote: remote, branch: String(name.dropFirst(remote.count + 1)))
                })
            }
            if ref.kind == .localBranch {
                menu.addItem(.separator())
                menu.addItem(item("Rename…", "pencil") { [weak self] in self?.rename(ref) })
                menu.addItem(item("Edit Description…", "text.alignleft") { [weak self] in self?.editDescription(ref) })
                let trackItem = NSMenuItem(title: "Select Tracked Branch", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for remoteRef in allRefs where remoteRef.kind == .remoteBranch && !remoteRef.fullName.hasSuffix("/HEAD") {
                    let target = remoteRef.shortName
                    let entry = item(target) {
                        ProgressWindowController.run(title: "Track \(target)", commands: [["branch", "--set-upstream-to=\(target)", name]], workingDirectory: root)
                    }
                    entry.state = ref.upstream == target ? .on : .off
                    submenu.addItem(entry)
                }
                trackItem.submenu = submenu
                trackItem.isEnabled = !submenu.items.isEmpty
                menu.addItem(trackItem)
                if !ref.upstream.isEmpty {
                    menu.addItem(item("Unset Tracked Branch") {
                        ProgressWindowController.run(title: "Unset Upstream", commands: [["branch", "--unset-upstream", name]], workingDirectory: root)
                    })
                }
            }
            menu.addItem(.separator())
        }
        menu.addItem(item(refs.count == 1 ? "Copy Ref Name" : "Copy Ref Names", "doc.on.doc") {
            Self.copy(refs.map(\.shortName))
        })
        menu.addItem(item("Copy SHA-1") { Self.copy(refs.map(\.commitHash)) })
        let deletable = refs.filter { !$0.isHead && $0.kind != .notes && $0.kind != .other }
        if !deletable.isEmpty {
            menu.addItem(.separator())
            let title = deletable.count == 1 ? "Delete “\(deletable[0].shortName)”…" : "Delete \(deletable.count) References…"
            menu.addItem(item(title, "trash") { [weak self] in self?.delete(deletable) })
        }
    }

    /// Namespace actions: Create Branch / Tag, Manage Remotes, Fetch from a remote, Delete all tags, Delete remote tags.
    private func buildTreeMenu(_ menu: NSMenu) {
        let clicked = outlineView.clickedRow
        guard !isPicker, clicked >= 0, let node = outlineView.item(atRow: clicked) as? GitRefTreeNode else { return }
        let root = repositoryPath
        switch node.path {
        case "refs/heads":
            menu.addItem(item("Create Branch…", "arrow.branch") { [weak self] in
                self?.present { CreateBranchTagWindowController(repositoryPath: root) }
            })
        case "refs/tags":
            menu.addItem(item("Create Tag…", "tag") { [weak self] in
                self?.present { CreateBranchTagWindowController(repositoryPath: root, createTag: true) }
            })
            let tags = node.allRefs(nested: true)
            if !tags.isEmpty {
                menu.addItem(item("Delete All \(tags.count) Tags…", "trash") { [weak self] in self?.delete(tags) })
            }
        case "refs/remotes":
            menu.addItem(item("Manage Remotes…", "network") {
                CommandRouter.shared.execute(command: .remotes, targetPath: root.rawPath)
            })
            menu.addItem(item("Fetch All Remotes", "arrow.down.circle") {
                ProgressWindowController.run(title: "Fetch All", commands: [["fetch", "--progress", "--all"]], workingDirectory: root)
            })
        default:
            let remoteName = String(node.path.dropFirst("refs/remotes/".count))
            if node.path.hasPrefix("refs/remotes/"), remotes.contains(remoteName) {
                menu.addItem(item("Fetch from “\(remoteName)”", "arrow.down.circle") { [weak self] in self?.fetch(remote: remoteName) })
                menu.addItem(item("Delete Remote Tags on “\(remoteName)”…", "tag.slash") { [weak self] in
                    self?.present { DeleteRemoteTagsWindowController(repositoryPath: root, remote: remoteName) }
                })
                menu.addItem(item("Manage Remotes…", "network") {
                    CommandRouter.shared.execute(command: .remotes, targetPath: root.rawPath)
                })
            }
        }
    }
}

// MARK: - Tree

extension BrowseRefsWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? GitRefTreeNode else { return 1 }
        return node.children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? GitRefTreeNode else { return tree }
        return node.children[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? GitRefTreeNode)?.children.isEmpty ?? true)
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? GitRefTreeNode else { return nil }
        let title: String
        let symbol: String
        switch node.path {
        case "refs": title = "refs"; symbol = "folder"
        case "refs/heads": title = "Local Branches"; symbol = "arrow.branch"
        case "refs/remotes": title = "Remotes"; symbol = "network"
        case "refs/tags": title = "Tags"; symbol = "tag"
        case "refs/notes": title = "Notes"; symbol = "note.text"
        default:
            title = node.name
            symbol = node.path.hasPrefix("refs/remotes/") && node.path.split(separator: "/").count == 3 ? "server.rack" : "folder"
        }
        let count = node.allRefs(nested: true).count
        let label = NSTextField(labelWithString: count > 0 ? "\(title) (\(count))" : title)
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        let stack = NSStackView(views: [image, label])
        stack.spacing = 4
        return stack
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? GitRefTreeNode else { return }
        selectedNodePath = node.path
        filterChanged()
    }
}

// MARK: - Ref list

extension BrowseRefsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        shownRefs.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < shownRefs.count else { return nil }
        let ref = shownRefs[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        func date(_ value: Date?) -> String { value.map(Self.dateFormatter.string(from:)) ?? "" }
        switch id {
        case "Ref":
            // Under its namespace node the leaf name suffices; nested or filtered lists need the full short name.
            cell.stringValue = ref.isHead ? "● \(ref.shortName)" : ref.shortName
            if ref.isHead {
                cell.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                cell.textColor = .systemGreen
            }
        case "Upstream":
            cell.stringValue = ref.tracking.isEmpty ? ref.upstream : "\(ref.upstream) \(ref.tracking)"
        case "Subject":
            cell.stringValue = ref.subject
        case "Author":
            cell.stringValue = ref.authorName
        case "AuthorDate":
            cell.stringValue = date(ref.authorDate)
        case "Committer":
            cell.stringValue = ref.committerName
        case "CommitDate":
            cell.stringValue = date(ref.committerDate)
        case "Hash":
            cell.stringValue = String(ref.commitHash.prefix(10))
            cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        case "Description":
            cell.stringValue = descriptions[ref.shortName]?.replacingOccurrences(of: "\n", with: " ") ?? ""
            cell.textColor = .secondaryLabelColor
        default:
            break
        }
        return cell
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        filterChanged()
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateInfo()
    }
}

/// Ref list with TortoiseGit's keys: F2 rename, Delete remove, Return open / select.
final class RefsTableView: NSTableView {
    enum Key { case rename, delete, enter }
    var onKey: ((Key) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let key: Key?
        switch event.keyCode {
        case 120: key = .rename                 // F2
        case 51, 117: key = .delete             // ⌫, ⌦
        case 36, 76: key = .enter               // Return, Enter
        default: key = nil
        }
        if let key, onKey?(key) == true { return }
        super.keyDown(with: event)
    }
}
