import Cocoa
import PangolinGitCore

/// Settings pane for Finder badges: status cache mode, which badge kinds are shown, folder aggregation,
/// watched and excluded folders (TortoiseGit Settings ▸ Icon Overlays and Overlay Handlers,
/// `SetOverlayPage.cpp` / `SetOverlayHandlers.cpp`). Unversioned and ignored badges keep their
/// switches on the General pane.
public final class OverlaysSettingsViewController: NSViewController {

    /// Badge kinds with a switch here, in TortoiseGit's Overlay Handlers order.
    private static let badgeKinds: [(GitBadgeKind, String)] = [
        (.normal, "Unmodified"),
        (.modified, "Modified"),
        (.conflicted, "Conflicted"),
        (.added, "Added"),
        (.deleted, "Deleted"),
        (.locked, "Skip-worktree (locked)"),
        (.needsLock, "Assume-unchanged")
    ]

    private let cacheModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var badgeCheckboxes: [GitBadgeKind: NSButton] = [:]
    private let unversionedParentCheckbox = NSButton(checkboxWithTitle: "Unversioned files mark their folder as modified", target: nil, action: nil)
    private let submoduleParentCheckbox = NSButton(checkboxWithTitle: "Changes inside submodules mark the folders above them as modified", target: nil, action: nil)
    private var watchedRootsView: NSTextView?
    private var excludedPathsView: NSTextView?

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 470))
        setupUI()
        loadData()
    }

    private func setupUI() {
        let cacheLabel = NSTextField(labelWithString: "Status cache:")
        cacheModePopup.addItems(withTitles: OverlayCacheMode.allCases.map(\.title))
        cacheModePopup.target = self
        cacheModePopup.action = #selector(optionChanged)

        let badgesLabel = NSTextField(labelWithString: "Show these badges:")
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 4
        grid.columnSpacing = 24
        var pair: [NSView] = []
        for (kind, title) in Self.badgeKinds {
            let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(optionChanged))
            badgeCheckboxes[kind] = checkbox
            pair.append(checkbox)
            if pair.count == 2 {
                grid.addRow(with: pair)
                pair.removeAll()
            }
        }
        if !pair.isEmpty { grid.addRow(with: pair + [NSGridCell.emptyContentView]) }

        for checkbox in [unversionedParentCheckbox, submoduleParentCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(optionChanged)
        }

        let watchedLabel = NSTextField(labelWithString: "Badge and offer menus in these folders (one per line; empty = your home folder and /Volumes):")
        let watchedScroll = Self.makeTextArea()
        watchedRootsView = watchedScroll.documentView as? NSTextView
        let excludedLabel = NSTextField(labelWithString: "Never badge these paths (one per line; end with * to include everything below):")
        let excludedScroll = Self.makeTextArea()
        excludedPathsView = excludedScroll.documentView as? NSTextView

        let views: [NSView] = [cacheLabel, cacheModePopup, badgesLabel, grid, unversionedParentCheckbox, submoduleParentCheckbox,
                               watchedLabel, watchedScroll, excludedLabel, excludedScroll]
        for subview in views {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let leading: CGFloat = 20
        NSLayoutConstraint.activate([
            cacheLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            cacheLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leading),
            cacheModePopup.centerYAnchor.constraint(equalTo: cacheLabel.centerYAnchor),
            cacheModePopup.leadingAnchor.constraint(equalTo: cacheLabel.trailingAnchor, constant: 8),

            badgesLabel.topAnchor.constraint(equalTo: cacheModePopup.bottomAnchor, constant: 16),
            badgesLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leading),
            grid.topAnchor.constraint(equalTo: badgesLabel.bottomAnchor, constant: 6),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leading + 12),

            unversionedParentCheckbox.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            unversionedParentCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leading),
            submoduleParentCheckbox.topAnchor.constraint(equalTo: unversionedParentCheckbox.bottomAnchor, constant: 6),
            submoduleParentCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leading),

            watchedLabel.topAnchor.constraint(equalTo: submoduleParentCheckbox.bottomAnchor, constant: 16),
            watchedLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leading),
            watchedScroll.topAnchor.constraint(equalTo: watchedLabel.bottomAnchor, constant: 6),
            watchedScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leading),
            watchedScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -leading),
            watchedScroll.heightAnchor.constraint(equalToConstant: 54),

            excludedLabel.topAnchor.constraint(equalTo: watchedScroll.bottomAnchor, constant: 12),
            excludedLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leading),
            excludedScroll.topAnchor.constraint(equalTo: excludedLabel.bottomAnchor, constant: 6),
            excludedScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leading),
            excludedScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -leading),
            excludedScroll.heightAnchor.constraint(equalToConstant: 54),
            excludedScroll.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
    }

    private static func makeTextArea() -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
        }
        return scroll
    }

    public func loadData() {
        let config = ConfigManager.shared
        cacheModePopup.selectItem(at: OverlayCacheMode.allCases.firstIndex(of: config.overlayCacheMode) ?? 0)
        for (kind, checkbox) in badgeCheckboxes {
            checkbox.state = config.isOverlayEnabled(kind) ? .on : .off
        }
        unversionedParentCheckbox.state = config.unversionedMarksParentModified ? .on : .off
        submoduleParentCheckbox.state = config.submoduleStatusInParent ? .on : .off
        watchedRootsView?.string = config.overlayWatchedRoots.joined(separator: "\n")
        excludedPathsView?.string = config.overlayExcludedPaths.joined(separator: "\n")
    }

    public func save() {
        let config = ConfigManager.shared
        let before = Self.fingerprint(config)
        config.overlayCacheMode = OverlayCacheMode.allCases[max(0, cacheModePopup.indexOfSelectedItem)]
        for (kind, checkbox) in badgeCheckboxes {
            config.setOverlayEnabled(checkbox.state == .on, for: kind)
        }
        config.unversionedMarksParentModified = unversionedParentCheckbox.state == .on
        config.submoduleStatusInParent = submoduleParentCheckbox.state == .on
        if let text = watchedRootsView?.string { config.overlayWatchedRoots = Self.lines(text) }
        if let text = excludedPathsView?.string { config.overlayExcludedPaths = Self.lines(text) }
        // Cached snapshots were built with the old options; re-read every repository and re-badge.
        if Self.fingerprint(config) != before {
            StatusAgentClient.invalidate(PangolinPath(""))
        }
    }

    /// Everything that changes how the agent builds badges.
    private static func fingerprint(_ config: ConfigManager) -> String {
        [config.overlayCacheMode.rawValue,
         config.overlayDisabledBadges.map(\.rawValue).sorted().joined(separator: ","),
         "\(config.unversionedMarksParentModified)", "\(config.submoduleStatusInParent)",
         config.overlayWatchedRoots.joined(separator: ","), config.overlayExcludedPaths.joined(separator: ",")]
            .joined(separator: "|")
    }

    @objc private func optionChanged() {
        save()
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
