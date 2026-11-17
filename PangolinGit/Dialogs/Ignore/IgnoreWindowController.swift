import Foundation
import Cocoa
import PangolinGitCore

/// Controller for adding patterns to an ignore file (`IgnoreDlg.cpp` / `CAppUtils::IgnoreFile` in
/// TortoiseGit): by name, by extension or a custom pattern; written to the root `.gitignore`, the
/// `.gitignore` of each item's folder, or `info/exclude`; matching only in the containing folder or
/// recursively. Works on the whole Finder selection and warns when selected items are tracked
/// (ignore rules do not affect tracked files), offering to stop tracking them.
public final class IgnoreWindowController: NSWindowController {

    public let repositoryPath: PangolinPath
    /// Repository-relative selection; "" stands for the repository root.
    public let relativeFilePaths: [String]
    public var relativeFilePath: String { relativeFilePaths.first ?? "" }
    private var items: [String] { relativeFilePaths.filter { !$0.isEmpty } }

    private var typeRadios: [NSButton] = []
    private var customPatternField: NSTextField!
    private var locationPopup: NSPopUpButton!
    private var scopeRadios: [NSButton] = []
    private var trackedLabel: NSTextField!
    private var untrackCheckbox: NSButton!
    private var previewTextView: NSTextView!
    private var tracked: [String] = []

    public convenience init(repositoryPath: PangolinPath, relativeFilePath: String = "") {
        self.init(repositoryPath: repositoryPath, relativeFilePaths: [relativeFilePath])
    }

    public init(repositoryPath: PangolinPath, relativeFilePaths: [String]) {
        self.repositoryPath = repositoryPath
        self.relativeFilePaths = relativeFilePaths.isEmpty ? [""] : relativeFilePaths

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add to Ignore List — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 560, height: 480)

        super.init(window: window)
        setupUI()
        checkTracked()
        updatePreview()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let itemsLabel = NSTextField(wrappingLabelWithString: items.isEmpty
            ? "Selection: the repository root (enter a custom pattern)"
            : "Selection: " + items.prefix(5).joined(separator: ", ") + (items.count > 5 ? " … (\(items.count) items)" : ""))
        itemsLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        // Pattern type
        let names = items.map { ($0.hasSuffix("/") ? String($0.dropLast()) : $0) as NSString }.map(\.lastPathComponent)
        let extensions = Array(Set(items.map { ($0 as NSString).pathExtension }.filter { !$0.isEmpty })).sorted()
        let nameText = names.isEmpty ? "(nothing selected)" : names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        let extText = extensions.isEmpty ? "(no extension)" : extensions.prefix(4).map { "*.\($0)" }.joined(separator: ", ")
        typeRadios = [
            NSButton(radioButtonWithTitle: "By name: \(nameText)", target: self, action: #selector(typeChanged(_:))),
            NSButton(radioButtonWithTitle: "By extension: \(extText)", target: self, action: #selector(typeChanged(_:))),
            NSButton(radioButtonWithTitle: "Custom pattern:", target: self, action: #selector(typeChanged(_:)))
        ]
        typeRadios[1].isEnabled = !extensions.isEmpty
        customPatternField = NSTextField()
        customPatternField.placeholderString = "e.g. *.log, build/, temp/"
        customPatternField.target = self
        customPatternField.action = #selector(optionChanged)
        customPatternField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let customRow = NSStackView(views: [typeRadios[2], customPatternField])
        // On the repository root there is no file to name: only a custom pattern makes sense.
        if items.isEmpty {
            typeRadios[0].isEnabled = false
            typeRadios[2].state = .on
        } else {
            typeRadios[0].state = .on
            customPatternField.isEnabled = false
        }

        // Ignore file and scope
        locationPopup = NSPopUpButton()
        locationPopup.addItems(withTitles: [".gitignore in the repository root",
                                            ".gitignore in the containing folder",
                                            "info/exclude (local only, not committed)"])
        locationPopup.target = self
        locationPopup.action = #selector(optionChanged)
        let locationRow = NSStackView(views: [NSTextField(labelWithString: "Ignore file:"), locationPopup])

        scopeRadios = [
            NSButton(radioButtonWithTitle: "Only in the containing folder", target: self, action: #selector(scopeChanged(_:))),
            NSButton(radioButtonWithTitle: "Recursively (in every folder below it)", target: self, action: #selector(scopeChanged(_:)))
        ]
        scopeRadios[0].state = .on
        let scopeRow = NSStackView(views: [NSTextField(labelWithString: "Match:")] + scopeRadios)

        trackedLabel = NSTextField(wrappingLabelWithString: "")
        trackedLabel.textColor = .systemOrange
        trackedLabel.isHidden = true
        untrackCheckbox = NSButton(checkboxWithTitle: "Also stop tracking them (git rm --cached, files stay on disk)", target: nil, action: nil)
        untrackCheckbox.isHidden = true

        let previewLbl = NSTextField(labelWithString: "Ignore file preview:")
        previewLbl.font = NSFont.boldSystemFont(ofSize: 12)

        let options = NSStackView(views: [itemsLabel, typeRadios[0], typeRadios[1], customRow, locationRow, scopeRow,
                                          trackedLabel, untrackCheckbox, previewLbl])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 7
        options.setCustomSpacing(12, after: itemsLabel)
        options.setCustomSpacing(12, after: customRow)
        options.setCustomSpacing(12, after: scopeRow)
        options.translatesAutoresizingMaskIntoConstraints = false
        itemsLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 630).isActive = true
        trackedLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 630).isActive = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        previewTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        previewTextView.autoresizingMask = [.width]
        previewTextView.isEditable = false
        previewTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = previewTextView

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        let applyBtn = NSButton(title: "Add to Ignore", target: self, action: #selector(applyClicked))
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelBtn, applyBtn])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        [options, scroll, buttons].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            options.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            options.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 25),
            options.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -25),

            scroll.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 25),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -25),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),

            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -25),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    /// Ignore rules do not apply to tracked files; say so and offer `git rm --cached`.
    private func checkTracked() {
        guard let repo = GitRepository.open(at: repositoryPath) else { return }
        tracked = repo.trackedPaths(among: items)
        guard !tracked.isEmpty else { return }
        trackedLabel.stringValue = "⚠️ \(tracked.count) selected item(s) are tracked (\(tracked.prefix(3).joined(separator: ", "))"
            + (tracked.count > 3 ? ", …" : "") + "). Ignore rules have no effect on tracked files."
        trackedLabel.isHidden = false
        untrackCheckbox.isHidden = false
        untrackCheckbox.state = .on
    }

    private var location: GitIgnoreFile.Location {
        GitIgnoreFile.Location(rawValue: locationPopup.indexOfSelectedItem) ?? .rootGitignore
    }

    private var scope: GitIgnoreFile.Scope {
        scopeRadios[1].state == .on ? .recursive : .containingFolderOnly
    }

    /// Patterns per ignore file for the current choices.
    private func plannedPatterns() -> [(file: URL, patterns: [String])] {
        var byFile: [URL: [String]] = [:]
        var order: [URL] = []
        func add(_ pattern: String, to file: URL) {
            if byFile[file] == nil { order.append(file) }
            if !(byFile[file]?.contains(pattern) ?? false) { byFile[file, default: []].append(pattern) }
        }
        func file(for path: String) -> URL {
            if let folder = GitIgnoreFile.ignoreFileFolder(for: path, location: location) {
                return GitIgnoreFile.gitignoreURL(inFolder: folder, repositoryRoot: repositoryPath)
            }
            return GitIgnoreFile.url(for: .localExclude, repositoryRoot: repositoryPath)
        }

        if typeRadios[2].state == .on {
            let pattern = customPatternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pattern.isEmpty {
                // A custom pattern goes to the first item's ignore file (the root for the repository itself).
                add(pattern, to: file(for: items.first ?? ".gitignore"))
            }
        } else {
            let byExtension = typeRadios[1].state == .on
            for path in items {
                guard let pattern = GitIgnoreFile.pattern(forPath: path, byExtension: byExtension, scope: scope, location: location) else { continue }
                add(pattern, to: file(for: path))
            }
        }
        return order.map { ($0, byFile[$0] ?? []) }
    }

    @objc private func typeChanged(_ sender: NSButton) {
        typeRadios.forEach { $0.state = $0 === sender ? .on : .off }
        customPatternField.isEnabled = typeRadios[2].state == .on
        scopeRadios.forEach { $0.isEnabled = typeRadios[2].state != .on }
        updatePreview()
    }

    @objc private func scopeChanged(_ sender: NSButton) {
        scopeRadios.forEach { $0.state = $0 === sender ? .on : .off }
        updatePreview()
    }

    @objc private func optionChanged() {
        updatePreview()
    }

    private func updatePreview() {
        var text = ""
        for (file, patterns) in plannedPatterns() {
            let display = PangolinPath(url: file).relative(to: repositoryPath) ?? file.path
            var content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
            let existing = Set(content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
            text += "── \(display)\n" + content
            for pattern in patterns {
                text += existing.contains(pattern) ? "  \(pattern)   <-- (already present)\n" : "+ \(pattern)   <-- (will be appended)\n"
            }
            text += "\n"
        }
        previewTextView.string = text.isEmpty ? "(No pattern for the current choice.)" : text
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func applyClicked() {
        let planned = plannedPatterns().filter { !$0.patterns.isEmpty }
        guard !planned.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Invalid Pattern"
            alert.informativeText = "Please enter or select a valid ignore pattern."
            alert.runModal()
            return
        }
        do {
            for (file, patterns) in planned {
                try GitIgnoreFile.append(patterns, toFile: file)
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        RepositoryEvents.post(repositoryPath)
        let untrack = !tracked.isEmpty && untrackCheckbox.state == .on
        let root = repositoryPath
        let trackedPaths = tracked
        window?.close()
        if untrack {
            ProgressWindowController.run(title: "Stop Tracking", commands: [["rm", "-r", "--cached", "--"] + trackedPaths],
                                         workingDirectory: root, postActions: { $0.succeeded ? [WorkingTreeOperations.commitAction(root)] : [] })
        }
    }
}
