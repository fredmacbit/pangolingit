import Cocoa
import PangolinGitCore

/// Building blocks shared by Pull/Fetch, Push and Sync: the remote-or-URL chooser with *Manage*
/// (TortoiseGit's `CHistoryCombo` + *Manage* link), the remote-branch combo with its `…` picker and
/// small form helpers.
@MainActor
enum RemoteDialogSupport {

    /// Opens the remote editor (TortoiseGit's *Manage* button opens Settings ▸ Git ▸ Remote).
    /// Callers reload their remote lists through `RepositoryEvents`, which every remote edit posts.
    static func manageRemotes(repository: PangolinPath) {
        WindowRegistry.shared.present({ RemotesWindowController(repositoryPath: repository) },
                                      key: "remotes|\(repository.rawPath)", repository: repository)
    }

    /// A right-aligned form label.
    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    /// A two-column form; `nil` in the first column leaves the label cell empty.
    static func grid(_ rows: [[NSView?]]) -> NSGridView {
        let filled: [[NSView]] = rows.map { row in row.map { $0 ?? NSGridCell.emptyContentView } }
        let grid = NSGridView(views: filled)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    static func hStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = .centerY
        return stack
    }

    static func vStack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    /// Lays `content` out in the window with standard margins and an OK/Cancel row, sized to fit.
    static func install(_ content: NSView, buttons: [NSButton], in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        content.translatesAutoresizingMaskIntoConstraints = false
        let buttonRow = hStack(buttons)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        contentView.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttonRow.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
        window.setContentSize(contentView.fittingSize)
    }

    /// "Resolve…" for a run that left conflicts: the Status area's Resolve dialog once it exists,
    /// Check for Modifications until then.
    static func resolveAction(root: PangolinPath) -> ProgressWindowController.PostAction {
        .init("Resolve…") {
            let command = PangolinCommand(rawValue: "resolve") ?? .changed
            CommandRouter.shared.execute(command: command, targetPath: root.rawPath)
        }
    }

    /// Whether git's output reports merge/rebase conflicts.
    static func reportsConflicts(_ output: String) -> Bool {
        output.contains("CONFLICT") || output.contains("Automatic merge failed") || output.contains("could not apply")
    }
}

/// "Remote: [origin ▾] [Manage…]" or "URL: [combo] [Browse…]" — where to pull from / push to
/// (TortoiseGit's Remote / Arbitrary URL radio pair, PF-02).
@MainActor
final class RemoteTargetView: NSView, NSComboBoxDelegate {

    /// Popup title used for "fetch from every remote" (`git fetch --all`).
    static let allRemotesTitle = "All Remotes"

    private let repository: PangolinPath
    private let remoteRadio = NSButton(radioButtonWithTitle: "Remote:", target: nil, action: nil)
    private let urlRadio = NSButton(radioButtonWithTitle: "URL:", target: nil, action: nil)
    let remotePopup = NSPopUpButton()
    let urlCombo = NSComboBox()
    private(set) var remotes: [GitRemoteConfig] = []
    /// Offer "All Remotes" at the end of the popup (Fetch).
    var offersAllRemotes = false { didSet { rebuildPopup(keeping: remotePopup.titleOfSelectedItem) } }

    var onChange: (() -> Void)?

    init(repository: PangolinPath, urlBrowseTitle: String = "Browse…") {
        self.repository = repository
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        for radio in [remoteRadio, urlRadio] {
            radio.target = self
            radio.action = #selector(radioChanged(_:))
        }
        remoteRadio.state = .on
        remotePopup.target = self
        remotePopup.action = #selector(changed)
        let manage = NSButton(title: "Manage…", target: self, action: #selector(manage))
        manage.bezelStyle = .rounded
        manage.toolTip = "Add, edit or remove remotes"

        urlCombo.addItems(withObjectValues: ConfigManager.shared.recentUrls)
        urlCombo.placeholderString = "https://… , git@host:path or a local folder"
        urlCombo.delegate = self
        urlCombo.completes = true
        let browse = NSButton(title: urlBrowseTitle, target: self, action: #selector(browse))
        browse.bezelStyle = .rounded
        browse.toolTip = "Choose a local repository folder"

        let grid = NSGridView(views: [
            [remoteRadio, remotePopup, manage],
            [urlRadio, urlCombo, browse]
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            urlCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        updateEnabled()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lets the form label line up with the first radio button.
    override var firstBaselineAnchor: NSLayoutYAxisAnchor { remoteRadio.firstBaselineAnchor }

    /// True when the arbitrary URL is chosen.
    var usesURL: Bool { urlRadio.state == .on }

    /// The selected remote name (nil for a URL or "All Remotes").
    var remoteName: String? {
        guard !usesURL, let title = remotePopup.titleOfSelectedItem, title != Self.allRemotesTitle else { return nil }
        return title
    }

    var allRemotesSelected: Bool { !usesURL && remotePopup.titleOfSelectedItem == Self.allRemotesTitle }

    var url: String { urlCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What git gets as `<repository>`: the remote name or the URL.
    var repositoryArgument: String? {
        if usesURL { return url.isEmpty ? nil : url }
        return remoteName
    }

    /// The selected remote's settings.
    var selectedRemote: GitRemoteConfig? {
        remoteName.flatMap { name in remotes.first { $0.name == name } }
    }

    /// Reloads the remotes, keeping the selection or choosing `preferred`.
    func reload(preferred: String? = nil) async {
        let previous = remotePopup.titleOfSelectedItem
        remotes = await GitRemotes.loadRemotes(in: repository)
        rebuildPopup(keeping: preferred ?? previous)
        if remotes.isEmpty && !usesURL {
            // Nothing to choose from: switch to the URL field like TortoiseGit does.
            select(url: true)
        }
        onChange?()
    }

    func selectRemote(_ name: String) {
        if remotePopup.itemTitles.contains(name) {
            remotePopup.selectItem(withTitle: name)
            select(url: false)
        }
    }

    /// Remembers the URL in the history (Settings ▸ Saved Data).
    func recordURLInHistory() {
        if usesURL, !url.isEmpty { ConfigManager.shared.addRecentUrl(url) }
    }

    private func rebuildPopup(keeping title: String?) {
        remotePopup.removeAllItems()
        remotePopup.addItems(withTitles: remotes.map(\.name))
        if offersAllRemotes && remotes.count > 1 {
            remotePopup.menu?.addItem(.separator())
            remotePopup.addItem(withTitle: Self.allRemotesTitle)
        }
        if let title, remotePopup.itemTitles.contains(title) {
            remotePopup.selectItem(withTitle: title)
        } else if let origin = remotes.first(where: { $0.name == "origin" }) {
            remotePopup.selectItem(withTitle: origin.name)
        }
    }

    private func select(url: Bool) {
        urlRadio.state = url ? .on : .off
        remoteRadio.state = url ? .off : .on
        updateEnabled()
    }

    private func updateEnabled() {
        remotePopup.isEnabled = !usesURL
        urlCombo.isEnabled = usesURL
    }

    @objc private func radioChanged(_ sender: NSButton) {
        select(url: sender === urlRadio)
        if usesURL { window?.makeFirstResponder(urlCombo) }
        onChange?()
    }

    @objc private func changed() {
        onChange?()
    }

    @objc private func manage() {
        RemoteDialogSupport.manageRemotes(repository: repository)
    }

    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose a local repository folder or bundle file"
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        urlCombo.stringValue = picked.path
        select(url: true)
        onChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.onChange?() }
    }
}

/// Editable branch combo with a `…` button that picks from the log or the references (PF-01).
/// Picked remote-tracking refs are reduced to the branch name on the remote.
@MainActor
final class BranchComboField: NSView, NSComboBoxDelegate {

    let combo = NSComboBox()
    /// Remote whose `<remote>/` prefix is stripped from picked refs.
    var remote: String?
    var onChange: (() -> Void)?

    init(repository: PangolinPath, placeholder: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        combo.placeholderString = placeholder
        combo.completes = true
        combo.delegate = self
        combo.numberOfVisibleItems = 15
        let picker = RevisionPickerButton(repository: repository) { [weak self] picked in
            self?.applyPicked(picked)
        }
        let stack = RemoteDialogSupport.hStack([combo, picker], spacing: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            combo.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lets form labels line up with the combo's text.
    override var firstBaselineAnchor: NSLayoutYAxisAnchor { combo.firstBaselineAnchor }
    override var lastBaselineAnchor: NSLayoutYAxisAnchor { combo.lastBaselineAnchor }

    var stringValue: String {
        get { combo.stringValue.trimmingCharacters(in: .whitespaces) }
        set { combo.stringValue = newValue }
    }

    var isEnabled: Bool {
        get { combo.isEnabled }
        set { combo.isEnabled = newValue }
    }

    func setItems(_ items: [String]) {
        combo.removeAllItems()
        combo.addItems(withObjectValues: items)
    }

    /// `refs/remotes/origin/x` / `origin/x` / `refs/heads/x` → `x`.
    nonisolated static func branchName(fromPicked picked: String, remote: String?) -> String {
        var name = picked
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        if let remote, name.hasPrefix(remote + "/") {
            name.removeFirst(remote.count + 1)
        }
        return name
    }

    private func applyPicked(_ picked: String) {
        combo.stringValue = Self.branchName(fromPicked: picked, remote: remote)
        onChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.onChange?() }
    }
}
