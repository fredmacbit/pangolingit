import Cocoa
import PangolinGitCore

/// Shows how a submodule pointer moved — TortoiseGit's Submodule Diff dialog (`SubmoduleDiffDlg.cpp`):
/// From/To hashes with subjects, the change type, *Show log* per side, *Show differences* and *Update*.
final class SubmoduleDiffWindowController: NSWindowController {

    private let root: PangolinPath
    private let submodulePath: String
    private let oldRevision: String
    private let newRevision: String?
    private var oldHash: String?
    private var newHash: String?

    private let fromLabel = NSTextField(wrappingLabelWithString: "")
    private let toLabel = NSTextField(wrappingLabelWithString: "")
    private let changeLabel = NSTextField(labelWithString: "Loading…")

    private var submoduleRoot: PangolinPath { PangolinPath(root.appending(submodulePath).rawPath) }

    /// A folder is treated as a submodule when it is not the repository root and has its own `.git`.
    static func isSubmodule(_ path: PangolinPath, root: PangolinPath) -> Bool {
        guard path.rawPath != root.rawPath else { return false }
        return FileManager.default.fileExists(atPath: path.url.appendingPathComponent(".git").path)
    }

    init(root: PangolinPath, submodulePath: String, oldRevision: String, newRevision: String?) {
        self.root = root
        self.submodulePath = submodulePath
        self.oldRevision = oldRevision
        self.newRevision = newRevision
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 260),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Submodule Diff — \(submodulePath)"
        window.minSize = NSSize(width: 480, height: 240)
        super.init(window: window)
        setupUI()
        load()
        RepositoryEvents.observe(root, owner: self) { [weak self] in self?.load() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        let fromLog = NSButton(title: "Show Log", target: self, action: #selector(onShowLog))
        let toLog = NSButton(title: "Show Log", target: self, action: #selector(onShowLog))
        let fromTitle = NSTextField(labelWithString: "From (\(oldRevision)):")
        let toTitle = NSTextField(labelWithString: "To (\(newRevision ?? "working tree")):")
        for title in [fromTitle, toTitle] { title.font = .boldSystemFont(ofSize: 12) }
        for label in [fromLabel, toLabel] {
            label.isSelectable = true
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        changeLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let grid = NSGridView(views: [[fromTitle, fromLabel, fromLog], [toTitle, toLabel, toLog]])
        grid.column(at: 1).width = 380
        grid.rowSpacing = 12
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline

        let diffButton = NSButton(title: "Show Differences", target: self, action: #selector(onShowDifferences))
        let updateButton = NSButton(title: "Update Submodule", target: self, action: #selector(onUpdate))
        updateButton.toolTip = "git submodule update --init -- \(submodulePath)"
        let closeButton = NSButton(title: "Close", target: self, action: #selector(onClose))
        closeButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [diffButton, updateButton, closeButton])

        let stack = NSStackView(views: [changeLabel, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
        ])
        fromLog.tag = 0
        toLog.tag = 1
    }

    private func load() {
        Task { @MainActor in
            let old = await gitlink(at: oldRevision)
            let new: String?
            if let newRevision {
                new = await gitlink(at: newRevision)
            } else {
                new = (try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "HEAD"], workingDirectory: submoduleRoot))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            oldHash = old
            newHash = new
            let oldInfo = await commitInfo(old)
            let newInfo = await commitInfo(new)
            var mergeBase: String?
            if let old, let new, old != new {
                mergeBase = (try? await GitCLIRunner.runAsync(arguments: ["merge-base", old, new], workingDirectory: submoduleRoot))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let change = SubmoduleChange.classify(old: old, new: new, mergeBase: mergeBase, oldTime: oldInfo?.time, newTime: newInfo?.time)
            changeLabel.stringValue = "Change: \(change.rawValue)"
            fromLabel.stringValue = describe(old, oldInfo)
            toLabel.stringValue = describe(new, newInfo)
        }
    }

    private func describe(_ hash: String?, _ info: (subject: String, time: Int)?) -> String {
        guard let hash else { return "(none)" }
        guard let info else { return "\(hash)\n(commit not available — submodule not initialised or not fetched)" }
        return "\(hash)\n\(info.subject)"
    }

    /// The gitlink hash recorded in the superproject at `revision` (`git rev-parse rev:path`).
    private func gitlink(at revision: String) async -> String? {
        let output = try? await GitCLIRunner.runAsync(arguments: ["rev-parse", "\(revision):\(submodulePath)"], workingDirectory: root)
        let hash = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hash.isEmpty ? nil : hash
    }

    private func commitInfo(_ hash: String?) async -> (subject: String, time: Int)? {
        guard let hash else { return nil }
        guard let output = try? await GitCLIRunner.runAsync(arguments: ["log", "-1", "--format=%ct%x00%s", hash], workingDirectory: submoduleRoot) else {
            return nil
        }
        let parts = output.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        guard parts.count == 2, let time = Int(parts[0]) else { return nil }
        return (parts[1], time)
    }

    @objc private func onShowLog(_ sender: NSButton) {
        let path = submoduleRoot
        WindowRegistry.shared.present({ LogWindowController(repositoryPath: path) }, key: "log|\(path.rawPath)", repository: path)
    }

    @objc private func onShowDifferences() {
        guard let oldHash, let newHash else { NSSound.beep(); return }
        let path = submoduleRoot
        WindowRegistry.shared.present({ FileDiffWindowController(repositoryPath: path, rev1: oldHash, rev2: newHash) }, repository: path)
    }

    @objc private func onUpdate() {
        ProgressWindowController.run(title: "Submodule Update", commands: [["submodule", "update", "--init", "--progress", "--", submodulePath]],
                                     workingDirectory: root, repository: root)
    }

    @objc private func onClose() {
        close()
    }
}
