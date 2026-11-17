import Cocoa
import PangolinGitCore

/// Base of the settings panes whose values live in git configuration rather than in PangolinGit's
/// preferences (TortoiseGit's Dialogs 3 and Issue Tracker pages). The header picks the repository and
/// the level that is edited (local `.git/config`, project `.tgitconfig`, global); a field left empty
/// (or a checkbox in the mixed state) is unset at that level and inherits the value shown as placeholder.
class GitConfigPaneViewController: NSViewController, NSTextFieldDelegate {

    struct Row {
        enum Kind {
            case text(placeholder: String)
            case integer
            case bool
            /// Popup of (title, value); the first entry should mean "inherit" with an empty value.
            case choice([(String, String)])
        }

        let key: String
        let label: String
        let kind: Kind
        let tooltip: String
    }

    /// Rows shown below the header; set by subclasses before the view loads.
    var rows: [Row] = []
    var paneTitle = ""
    var paneDescription = ""

    private let repositoryPopup = NSPopUpButton()
    private let scopePopup = NSPopUpButton()
    private var controls: [String: NSControl] = [:]
    /// Values as loaded for the edited scope, to write only what changed.
    private var loaded: [String: String] = [:]
    private(set) var effective: [String: String] = [:]
    let contentStack = NSStackView()
    private var loadGeneration = 0
    /// Repository and level the controls currently show. Saving targets these, because the popups'
    /// actions fire after the new selection is already made.
    private var editedRepository: PangolinPath?
    private var editedScope: GitConfigScope?

    var repository: PangolinPath? {
        let path = repositoryPopup.selectedItem?.representedObject as? String
        return path.map(PangolinPath.init)
    }

    var scope: GitConfigScope {
        (scopePopup.selectedItem?.representedObject as? String).flatMap(GitConfigScope.init(rawValue:)) ?? .global
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        buildHeader()
        buildRows()
        reload()
    }

    private func buildHeader() {
        let title = NSTextField(labelWithString: paneTitle)
        title.font = .boldSystemFont(ofSize: 13)
        let description = NSTextField(wrappingLabelWithString: paneDescription)
        description.textColor = .secondaryLabelColor

        repositoryPopup.target = self
        repositoryPopup.action = #selector(repositoryChanged)
        repositoryPopup.toolTip = "Repository whose settings are shown (recent repositories)."
        var repositories = ConfigManager.shared.recentRepositories
        if let current = WindowRegistry.shared.currentRepository?.rawPath {
            repositories.removeAll { $0 == current }
            repositories.insert(current, at: 0)
        }
        repositoryPopup.addItem(withTitle: "No repository (global settings only)")
        for path in repositories where FileManager.default.fileExists(atPath: path) {
            repositoryPopup.addItem(withTitle: (path as NSString).abbreviatingWithTildeInPath)
            repositoryPopup.lastItem?.representedObject = path
        }
        if repositoryPopup.numberOfItems > 1 { repositoryPopup.selectItem(at: 1) }

        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        scopePopup.toolTip = "Level that is edited. Empty fields inherit from the levels below (local → project → global → system)."
        rebuildScopes()

        let repoLabel = NSTextField(labelWithString: "Repository:")
        let scopeLabel = NSTextField(labelWithString: "Edit in:")
        let grid = NSGridView(views: [[repoLabel, repositoryPopup], [scopeLabel, scopePopup]])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10

        let outer = NSStackView(views: [title, description, grid, separator(), contentStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            outer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            outer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            outer.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16),
            description.widthAnchor.constraint(equalTo: outer.widthAnchor),
            contentStack.widthAnchor.constraint(equalTo: outer.widthAnchor)
        ])
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return box
    }

    private func rebuildScopes() {
        let previous = scope
        scopePopup.removeAllItems()
        let scopes: [GitConfigScope] = repository == nil ? [.global] : [.local, .project, .global]
        for scope in scopes {
            scopePopup.addItem(withTitle: scope.title)
            scopePopup.lastItem?.representedObject = scope.rawValue
        }
        if let index = scopes.firstIndex(of: previous) { scopePopup.selectItem(at: index) }
    }

    private func buildRows() {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for row in rows {
            let label = NSTextField(labelWithString: row.label)
            let control: NSControl
            switch row.kind {
            case .text(let placeholder):
                let field = NSTextField()
                field.placeholderString = placeholder
                field.delegate = self
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
                control = field
            case .integer:
                let field = NSTextField()
                field.formatter = NumberFormatter()
                field.delegate = self
                field.widthAnchor.constraint(equalToConstant: 80).isActive = true
                control = field
            case .bool:
                let checkbox = NSButton(checkboxWithTitle: row.label, target: self, action: #selector(controlChanged))
                checkbox.allowsMixedState = true
                control = checkbox
                label.stringValue = ""
            case .choice(let choices):
                let popup = NSPopUpButton()
                for (title, value) in choices {
                    popup.addItem(withTitle: title)
                    popup.lastItem?.representedObject = value
                }
                popup.target = self
                popup.action = #selector(controlChanged)
                control = popup
            }
            control.toolTip = row.tooltip + "  (git config \(row.key))"
            label.toolTip = control.toolTip
            controls[row.key] = control
            grid.addRow(with: [label, control])
        }
        grid.column(at: 0).xPlacement = .trailing
        contentStack.addArrangedSubview(grid)
    }

    // MARK: - Loading and saving

    /// Reads the edited scope and the effective values (for the "inherited" placeholders).
    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let store = GitConfigStore(repository: repository)
        let scope = self.scope
        editedRepository = nil
        editedScope = nil
        Task { @MainActor in
            let scoped = await store.values(in: scope)
            let effective = await store.values(in: store.repository == nil ? .global : .effective)
            guard generation == loadGeneration else { return }
            self.editedRepository = store.repository
            self.editedScope = scope
            self.effective = effective
            self.loaded = Dictionary(uniqueKeysWithValues: rows.compactMap { row in scoped[row.key].map { (row.key, $0) } })
            for row in rows { show(row, value: scoped[row.key], inherited: effective[row.key]) }
            valuesDidLoad()
        }
    }

    /// Hook for subclasses after values were (re)loaded.
    func valuesDidLoad() {}

    private func show(_ row: Row, value: String?, inherited: String?) {
        guard let control = controls[row.key] else { return }
        switch row.kind {
        case .text(let placeholder):
            let field = control as? NSTextField
            field?.stringValue = value ?? ""
            field?.placeholderString = inherited.map { "inherited: \($0)" } ?? placeholder
        case .integer:
            let field = control as? NSTextField
            field?.stringValue = value ?? ""
            field?.placeholderString = inherited.map { "(\($0))" } ?? ""
        case .bool:
            let checkbox = control as? NSButton
            if let value {
                checkbox?.state = BugtraqConfig.parseBool(value) ? .on : .off
            } else {
                checkbox?.state = .mixed
            }
            checkbox?.toolTip = row.tooltip + (inherited.map { " Inherited: \($0)." } ?? "") + " Mixed = inherit."
        case .choice:
            let popup = control as? NSPopUpButton
            let index = popup?.itemArray.firstIndex { ($0.representedObject as? String) == (value ?? "") } ?? 0
            popup?.selectItem(at: index)
        }
    }

    /// Current value of a row's control (nil = unset at this level).
    func currentValue(_ key: String) -> String? {
        guard let row = rows.first(where: { $0.key == key }), let control = controls[key] else { return nil }
        switch row.kind {
        case .text, .integer:
            let text = (control as? NSTextField)?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        case .bool:
            switch (control as? NSButton)?.state {
            case .on?: return "true"
            case .off?: return "false"
            default: return nil
            }
        case .choice:
            let value = (control as? NSPopUpButton)?.selectedItem?.representedObject as? String ?? ""
            return value.isEmpty ? nil : value
        }
    }

    /// Effective value of a key, preferring what is being edited.
    func value(_ key: String) -> String {
        currentValue(key) ?? effective[key] ?? ""
    }

    /// Writes the changed rows to the edited scope.
    func save() {
        // Nothing to save until the shown values finished loading.
        guard isViewLoaded, let scope = editedScope else { return }
        let store = GitConfigStore(repository: editedRepository)
        var changes: [(String, String?)] = []
        for row in rows where currentValue(row.key) != loaded[row.key] {
            changes.append((row.key, currentValue(row.key)))
            loaded[row.key] = currentValue(row.key)
        }
        guard !changes.isEmpty else { return }
        Task {
            for (key, value) in changes {
                do {
                    try await store.set(key, to: value, in: scope)
                } catch {
                    await MainActor.run { _ = NSAlert(error: error).runModal() }
                }
            }
            if scope == .project, let repository = store.repository {
                await MainActor.run { RepositoryEvents.post(repository) }
            }
        }
    }

    @objc func controlChanged() {
        save()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        save()
    }

    @objc private func repositoryChanged() {
        save()
        rebuildScopes()
        reload()
    }

    @objc private func scopeChanged() {
        save()
        reload()
    }
}
