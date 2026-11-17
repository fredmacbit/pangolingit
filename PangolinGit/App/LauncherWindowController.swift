import Cocoa
import PangolinGitCore

/// Start window listing recent repositories, shown when PangolinGit is opened from the Dock or
/// Launchpad rather than from a Finder context menu.
@MainActor
final class LauncherWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let tableView = NSTableView()
    private var repositories: [String] = []
    private var actionButtons: [NSButton] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PangolinGit"
        window.minSize = NSSize(width: 460, height: 320)
        window.setFrameAutosaveName("PangolinGitLauncher")
        super.init(window: window)
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let appIcon = NSImageView(image: NSApp.applicationIconImage)
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "PangolinGit")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Recent Repositories")
        subtitle.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = NSStackView(views: [appIcon, titles])
        header.spacing = 12
        NSLayoutConstraint.activate([
            appIcon.widthAnchor.constraint(equalToConstant: 56),
            appIcon.heightAnchor.constraint(equalToConstant: 56)
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("repo"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 40
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(showLog(_:))

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        func button(_ title: String, _ symbol: String, _ action: Selector, needsSelection: Bool = true) -> NSButton {
            let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: action)
            b.imagePosition = .imageLeading
            if needsSelection { actionButtons.append(b) }
            return b
        }

        let repoActions = NSStackView(views: [
            button("Log", "clock.arrow.circlepath", #selector(showLog(_:))),
            button("Commit", "checkmark.circle", #selector(commit(_:))),
            button("Changes", "doc.text.magnifyingglass", #selector(changes(_:))),
            button("Sync", "arrow.triangle.2.circlepath", #selector(sync(_:))),
            button("Show in Finder", "folder", #selector(revealInFinder(_:)))
        ])
        let globalActions = NSStackView(views: [
            button("Open…", "folder.badge.plus", #selector(openRepository(_:)), needsSelection: false),
            button("Clone…", "square.and.arrow.down", #selector(clone(_:)), needsSelection: false)
        ])

        let stack = NSStackView(views: [header, scroll, repoActions, globalActions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func reload() {
        repositories = ConfigManager.shared.recentRepositories.filter {
            FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git"))
        }
        tableView.reloadData()
        if !repositories.isEmpty && tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateButtons()
    }

    private var selectedRepository: String? {
        let row = tableView.selectedRow
        return row >= 0 && row < repositories.count ? repositories[row] : nil
    }

    private func updateButtons() {
        actionButtons.forEach { $0.isEnabled = selectedRepository != nil }
    }

    private func run(_ command: PangolinCommand) {
        guard let repo = selectedRepository else { return }
        CommandRouter.shared.execute(command: command, targetPath: repo)
        reload()
    }

    @objc private func showLog(_ sender: Any?) { run(.log) }
    @objc private func commit(_ sender: Any?) { run(.commit) }
    @objc private func changes(_ sender: Any?) { run(.changed) }
    @objc private func sync(_ sender: Any?) { run(.sync) }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let repo = selectedRepository else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo)])
    }

    @objc func openRepository(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a folder inside a Git working tree"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        CommandRouter.shared.execute(command: .log, targetPath: url.path)
        reload()
    }

    @objc private func clone(_ sender: Any?) {
        CommandRouter.shared.execute(command: .clone, paths: [])
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        repositories.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = repositories[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: path))
        let name = NSTextField(labelWithString: (path as NSString).lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let location = NSTextField(labelWithString: (path as NSString).abbreviatingWithTildeInPath)
        location.textColor = .secondaryLabelColor
        location.font = .systemFont(ofSize: 11)
        location.lineBreakMode = .byTruncatingMiddle

        let labels = NSStackView(views: [name, location])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let row = NSStackView(views: [icon, labels])
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}
