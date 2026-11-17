import Cocoa
import PangolinGitCore

/// Shared "choose version" control (TortoiseGit's `CChooseVersion`): HEAD, a branch, a tag or any
/// commit-ish (`HEAD~4`, a hash, …), with `…` pickers that open the Log or Browse References.
/// Used by Switch, Branch/Tag, Reset, Export, Rebase, Worktree, Bisect and Compare Revisions.
@MainActor
final class RevisionChooserView: NSView, NSComboBoxDelegate, NSTextFieldDelegate {

    enum Kind: CaseIterable {
        case head, branch, tag, commit
    }

    private let repository: PangolinPath
    private let kinds: [Kind]
    private var radios: [Kind: NSButton] = [:]
    private let branchCombo = NSComboBox()
    private let tagCombo = NSComboBox()
    private let commitField = NSTextField()
    private var pendingRevision: String?
    private(set) var branches: [String] = []
    private(set) var tags: [String] = []

    /// Called whenever the chosen revision changes.
    var onChange: (() -> Void)?

    /// - Parameters:
    ///   - kinds: the choices to offer, in order (e.g. leave out `.head` for a merge source).
    ///   - initialRevision: preselected revision; picks the matching kind once refs are loaded.
    init(repository: PangolinPath, kinds: [Kind] = Kind.allCases, initialRevision: String? = nil) {
        self.repository = repository
        self.kinds = kinds
        self.pendingRevision = initialRevision
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        select(kinds.first ?? .commit)
        loadReferences()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Value

    /// The chosen revision as git understands it (empty when nothing usable is entered).
    var revision: String {
        switch selectedKind {
        case .head: return "HEAD"
        case .branch: return branchCombo.stringValue.trimmingCharacters(in: .whitespaces)
        case .tag: return tagCombo.stringValue.trimmingCharacters(in: .whitespaces)
        case .commit: return commitField.stringValue.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Selects the kind that matches `revision` (a known branch or tag, HEAD, or free text).
    func setRevision(_ revision: String) {
        if branches.isEmpty && tags.isEmpty {
            pendingRevision = revision
        }
        if revision == "HEAD", kinds.contains(.head) {
            select(.head)
        } else if branches.contains(revision), kinds.contains(.branch) {
            branchCombo.stringValue = revision
            select(.branch)
        } else if tags.contains(revision), kinds.contains(.tag) {
            tagCombo.stringValue = revision
            select(.tag)
        } else if kinds.contains(.commit) {
            commitField.stringValue = revision
            select(.commit)
        }
        onChange?()
    }

    private var selectedKind: Kind {
        kinds.first { radios[$0]?.state == .on } ?? .commit
    }

    // MARK: - UI

    private func buildUI() {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        addSubview(grid)

        for kind in kinds {
            let radio = NSButton(radioButtonWithTitle: title(for: kind), target: self, action: #selector(radioChanged(_:)))
            radios[kind] = radio
            switch kind {
            case .head:
                grid.addRow(with: [radio, NSGridCell.emptyContentView])
            case .branch:
                configure(branchCombo, placeholder: "Branch")
                grid.addRow(with: [radio, branchCombo])
            case .tag:
                configure(tagCombo, placeholder: "Tag")
                grid.addRow(with: [radio, tagCombo])
            case .commit:
                commitField.placeholderString = "Commit, e.g. a1b2c3d or HEAD~2"
                commitField.delegate = self
                let picker = RevisionPickerButton(repository: repository) { [weak self] revision in self?.setRevision(revision) }
                let row = NSStackView(views: [commitField, picker])
                row.spacing = 6
                grid.addRow(with: [radio, row])
            }
        }
        grid.column(at: 0).xPlacement = .leading
        grid.rowAlignment = .firstBaseline

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            branchCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            commitField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    private func configure(_ combo: NSComboBox, placeholder: String) {
        combo.placeholderString = placeholder
        combo.completes = true
        combo.numberOfVisibleItems = 16
        combo.delegate = self
    }

    private func title(for kind: Kind) -> String {
        switch kind {
        case .head: return "HEAD"
        case .branch: return "Branch"
        case .tag: return "Tag"
        case .commit: return "Commit"
        }
    }

    private func select(_ kind: Kind) {
        for (candidate, radio) in radios {
            radio.state = candidate == kind ? .on : .off
        }
        branchCombo.isEnabled = kind == .branch
        tagCombo.isEnabled = kind == .tag
        commitField.isEnabled = kind == .commit
    }

    @objc private func radioChanged(_ sender: NSButton) {
        guard let kind = radios.first(where: { $0.value === sender })?.key else { return }
        select(kind)
        onChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: - Data

    private func loadReferences() {
        let root = repository
        Task { @MainActor in
            let branchOutput = (try? await GitCLIRunner.runAsync(
                arguments: ["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"], workingDirectory: root
            )) ?? ""
            let tagOutput = (try? await GitCLIRunner.runAsync(
                arguments: ["for-each-ref", "--sort=-v:refname", "--format=%(refname:short)", "refs/tags"], workingDirectory: root
            )) ?? ""
            // Local branches come first in for-each-ref order; skip the symbolic origin/HEAD.
            self.branches = branchOutput.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
            self.tags = tagOutput.split(separator: "\n").map(String.init)
            self.branchCombo.removeAllItems()
            self.branchCombo.addItems(withObjectValues: self.branches)
            self.tagCombo.removeAllItems()
            self.tagCombo.addItems(withObjectValues: self.tags)
            if let pending = self.pendingRevision {
                self.pendingRevision = nil
                self.setRevision(pending)
            }
        }
    }
}

/// The `…` button next to a revision field: opens the Log or Browse References as a picker and
/// hands back the chosen commit or ref (TortoiseGit's log / ref-browser buttons).
@MainActor
final class RevisionPickerButton: NSButton {
    private var repository = PangolinPath("/")
    private var onPick: ((String) -> Void)?

    convenience init(repository: PangolinPath, onPick: @escaping (String) -> Void) {
        self.init(frame: .zero)
        self.repository = repository
        self.onPick = onPick
        title = "…"
        bezelStyle = .rounded
        toolTip = "Choose from the log or from the references"
        target = self
        action = #selector(showMenu)
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Choose from Log…", symbol: "clock.arrow.circlepath") { [weak self] in self?.pickFromLog() })
        menu.addItem(ClosureMenuItem(title: "Choose from References…", symbol: "tag") { [weak self] in self?.pickFromReferences() })
        menu.addItem(ClosureMenuItem(title: "Choose from RefLog…", symbol: "arrow.uturn.backward.circle") { [weak self] in self?.pickFromRefLog() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    private func pickFromLog() {
        let root = repository
        WindowRegistry.shared.present({
            LogWindowController(repositoryPath: root) { [weak self] hash in self?.onPick?(hash) }
        }, repository: root)
    }

    private func pickFromReferences() {
        let root = repository
        WindowRegistry.shared.present({
            BrowseRefsWindowController(repositoryPath: root) { [weak self] ref in self?.onPick?(ref) }
        }, repository: root)
    }

    /// TortoiseGit's RefLog picker (e.g. Compare Revisions): recovers commits no ref points at any more.
    private func pickFromRefLog() {
        let root = repository
        WindowRegistry.shared.present({
            RefLogWindowController(repositoryPath: root, ref: "HEAD") { [weak self] hash in self?.onPick?(hash) }
        }, repository: root)
    }
}
