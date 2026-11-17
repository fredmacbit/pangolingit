import Cocoa
import PangolinGitCore

/// Clean up dialog mirroring TortoiseGit's `CCleanTypeDlg` + `CleanupCommand`: removes untracked
/// and/or ignored files with `git clean`. By default the files are listed with a dry run and moved
/// to the Trash one by one (TortoiseGit uses the Recycle Bin the same way); *Do not use the Trash*
/// runs `git clean` itself, and *Dry run* only shows what would go, offering *Clean to Trash* /
/// *Clean permanently* afterwards.
public final class CleanupWindowController: NSWindowController {

    private let repositoryPath: PangolinPath
    /// Repository-relative selection; empty means the whole working tree.
    private let selection: [String]

    private var scopeButtons: [NSButton] = []
    private let directoriesCheckbox = NSButton(checkboxWithTitle: "Remove untracked directories (-d)", target: nil, action: nil)
    private let nestedCheckbox = NSButton(checkboxWithTitle: "Remove nested repositories (-f -f)", target: nil, action: nil)
    private let submodulesCheckbox = NSButton(checkboxWithTitle: "Also clean submodules (recursively)", target: nil, action: nil)
    private let noTrashCheckbox = NSButton(checkboxWithTitle: "Do not use the Trash (delete permanently)", target: nil, action: nil)
    private let dryRunCheckbox = NSButton(checkboxWithTitle: "Dry run (only list what would be removed)", target: nil, action: nil)
    private let cleanButton = NSButton(title: "Clean Up", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private static let defaultsKey = "CleanupOptions"

    public init(repositoryPath: PangolinPath, selection: [String] = []) {
        self.repositoryPath = repositoryPath
        self.selection = selection.filter { !$0.isEmpty }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Clean Up — \(repositoryPath.filename)"
        super.init(window: window)
        setupUI()
        restoreOptions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let scopeLabel = NSTextField(labelWithString: "Remove:")
        scopeLabel.font = NSFont.boldSystemFont(ofSize: 12)
        let titles = ["All untracked files (also ignored ones, -x)",
                      "Untracked files that are not ignored",
                      "Ignored files only (-X)"]
        scopeButtons = titles.map { NSButton(radioButtonWithTitle: $0, target: self, action: #selector(scopeChanged(_:))) }

        let where_ = NSTextField(wrappingLabelWithString: selection.isEmpty
            ? "Applies to the whole working tree."
            : "Applies to: " + selection.prefix(4).joined(separator: ", ") + (selection.count > 4 ? " …" : ""))
        where_.textColor = .secondaryLabelColor
        where_.font = NSFont.systemFont(ofSize: 11)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        let options = NSStackView(views: [scopeLabel] + scopeButtons + [directoriesCheckbox, nestedCheckbox, submodulesCheckbox,
                                                                         noTrashCheckbox, dryRunCheckbox, where_])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 6
        options.setCustomSpacing(12, after: scopeButtons.last!)
        options.setCustomSpacing(12, after: dryRunCheckbox)
        options.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cleanButton.target = self
        cleanButton.action = #selector(cleanClicked)
        cleanButton.bezelStyle = .rounded
        cleanButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [statusLabel, cancelButton, cleanButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        [options, buttons].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            options.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            options.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            options.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            where_.widthAnchor.constraint(lessThanOrEqualToConstant: 440),

            buttons.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            options.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -12)
        ])
    }

    @objc private func scopeChanged(_ sender: NSButton) {
        scopeButtons.forEach { $0.state = $0 === sender ? .on : .off }
    }

    private var options: GitCleanOptions {
        GitCleanOptions(scope: GitCleanOptions.Scope(rawValue: scopeButtons.firstIndex { $0.state == .on } ?? 1) ?? .nonIgnored,
                        directories: directoriesCheckbox.state == .on,
                        nestedRepositories: nestedCheckbox.state == .on,
                        submodules: submodulesCheckbox.state == .on)
    }

    // MARK: - Remembered options (per user, like TortoiseGit's registry values)

    private func restoreOptions() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) ?? [:]
        let scope = stored["scope"] as? Int ?? GitCleanOptions.Scope.nonIgnored.rawValue
        scopeButtons.enumerated().forEach { $1.state = $0 == scope ? .on : .off }
        directoriesCheckbox.state = (stored["directories"] as? Bool ?? true) ? .on : .off
        nestedCheckbox.state = (stored["nested"] as? Bool ?? false) ? .on : .off
        submodulesCheckbox.state = (stored["submodules"] as? Bool ?? false) ? .on : .off
        noTrashCheckbox.state = (stored["noTrash"] as? Bool ?? !ConfigManager.shared.useTrashOnRevert) ? .on : .off
        dryRunCheckbox.state = (stored["dryRun"] as? Bool ?? false) ? .on : .off
    }

    private func saveOptions() {
        let opts = options
        UserDefaults.standard.set([
            "scope": opts.scope.rawValue, "directories": opts.directories, "nested": opts.nestedRepositories,
            "submodules": opts.submodules, "noTrash": noTrashCheckbox.state == .on, "dryRun": dryRunCheckbox.state == .on
        ], forKey: Self.defaultsKey)
    }

    // MARK: - Running

    @objc private func cancelClicked() {
        close()
    }

    @objc private func cleanClicked() {
        saveOptions()
        let opts = options
        let root = repositoryPath
        let paths = selection
        if dryRunCheckbox.state == .on {
            close()
            Self.runDryRun(opts, root: root, paths: paths)
        } else if noTrashCheckbox.state == .on {
            close()
            Self.cleanPermanently(opts, root: root, paths: paths)
        } else {
            cleanButton.isEnabled = false
            statusLabel.stringValue = "Looking for files to remove…"
            Task { @MainActor in
                await Self.cleanToTrash(opts, root: root, paths: paths)
                self.close()
            }
        }
    }

    private static func commands(_ options: GitCleanOptions, dryRun: Bool, paths: [String]) -> [[String]] {
        var commands = [GitRepository.cleanArguments(options, dryRun: dryRun, paths: paths)]
        if options.submodules {
            commands.append(GitRepository.submoduleCleanArguments(options, dryRun: dryRun))
        }
        return commands
    }

    /// Lists what would be removed, then offers the real clean (TortoiseGit's post-commands).
    static func runDryRun(_ options: GitCleanOptions, root: PangolinPath, paths: [String]) {
        ProgressWindowController.run(title: "Clean Up (Dry Run)", commands: commands(options, dryRun: true, paths: paths),
                                     workingDirectory: root, postActions: { outcome in
            guard outcome.succeeded else { return [] }
            return [
                ProgressWindowController.PostAction("Clean to Trash") {
                    Task { @MainActor in await cleanToTrash(options, root: root, paths: paths) }
                },
                ProgressWindowController.PostAction("Clean Permanently") { cleanPermanently(options, root: root, paths: paths) }
            ]
        })
    }

    static func cleanPermanently(_ options: GitCleanOptions, root: PangolinPath, paths: [String]) {
        ProgressWindowController.run(title: "Clean Up", commands: commands(options, dryRun: false, paths: paths), workingDirectory: root)
    }

    /// Dry-runs `git clean` and moves every listed item to the Trash.
    static func cleanToTrash(_ options: GitCleanOptions, root: PangolinPath, paths: [String]) async {
        var found: [String] = []
        do {
            for command in commands(options, dryRun: true, paths: paths) {
                let output = try await GitCLIRunner.runAsync(arguments: command, workingDirectory: root)
                found += GitRepository.parseCleanDryRun(output)
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        guard !found.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to clean up"
            alert.informativeText = "There are no files matching the chosen options."
            alert.runModal()
            return
        }
        let toTrash = found
        let failures = await Task.detached { () -> [(String, String)] in
            var failures: [(String, String)] = []
            for path in toTrash {
                do {
                    try FileManager.default.trashItem(at: root.appending(path).url, resultingItemURL: nil)
                } catch {
                    failures.append((path, error.localizedDescription))
                }
            }
            return failures
        }.value
        RepositoryEvents.post(root)
        let alert = NSAlert()
        alert.alertStyle = failures.isEmpty ? .informational : .warning
        alert.messageText = "Moved \(found.count - failures.count) item(s) to the Trash"
        alert.informativeText = failures.isEmpty
            ? found.prefix(12).joined(separator: "\n") + (found.count > 12 ? "\n…" : "")
            : "Could not move:\n" + failures.prefix(10).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        alert.runModal()
    }
}
