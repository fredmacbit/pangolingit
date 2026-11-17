import Cocoa
import PangolinGitCore

/// Settings pane for diff colours and the diff font (`SettingsColors.cpp` in TortoiseGit, plus
/// TortoiseGitMerge's colour page and TortoiseGitUDiff's colour/font page: added, removed,
/// modified, header and position colours, font, size and tab width).
public final class ColorsSettingsViewController: NSViewController {

    private var addedColorWell: NSColorWell!
    private var deletedColorWell: NSColorWell!
    private var modifiedColorWell: NSColorWell!
    private var headerColorWell: NSColorWell!
    private var positionColorWell: NSColorWell!
    private var fontPopup: NSPopUpButton!
    private var sizeField: NSTextField!
    private var tabField: NSTextField!

    private static let systemFontTitle = "System Monospaced"

    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        setupUI()
        loadData()
    }

    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Diff Colors and Font")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)

        let subLabel = NSTextField(labelWithString: "Used by the diff viewer, the unified diff viewer, the merge editor and file lists:")
        subLabel.textColor = .secondaryLabelColor

        func well() -> NSColorWell {
            let well = NSColorWell()
            well.target = self
            well.action = #selector(colorChanged)
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            return well
        }
        addedColorWell = well()
        deletedColorWell = well()
        modifiedColorWell = well()
        headerColorWell = well()
        positionColorWell = well()

        fontPopup = NSPopUpButton()
        fontPopup.addItem(withTitle: Self.systemFontTitle)
        let monospaced = NSFontManager.shared.availableFontFamilies.filter { family in
            NSFontManager.shared.availableMembers(ofFontFamily: family)?.first.flatMap { $0.first as? String }
                .flatMap { NSFont(name: $0, size: 12) }?.isFixedPitch ?? false
        }
        fontPopup.addItems(withTitles: monospaced)
        fontPopup.target = self
        fontPopup.action = #selector(colorChanged)
        sizeField = NSTextField()
        sizeField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        tabField = NSTextField()
        tabField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        for field in [sizeField!, tabField!] {
            field.target = self
            field.action = #selector(colorChanged)
        }

        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetDefaultsClicked))
        resetButton.bezelStyle = .rounded

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Added lines / insertions:"), addedColorWell],
            [NSTextField(labelWithString: "Deleted lines / deletions:"), deletedColorWell],
            [NSTextField(labelWithString: "Modified lines / changed files:"), modifiedColorWell],
            [NSTextField(labelWithString: "Unified diff file headers:"), headerColorWell],
            [NSTextField(labelWithString: "Hunk positions (@@):"), positionColorWell],
            [NSTextField(labelWithString: "Font:"), fontPopup],
            [NSTextField(labelWithString: "Font size:"), sizeField],
            [NSTextField(labelWithString: "Tab width (spaces):"), tabField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView(views: [titleLabel, subLabel, grid, resetButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
    }

    public func loadData() {
        let config = ConfigManager.shared
        addedColorWell.color = NSColor(hexString: config.diffAddedColorHex) ?? .systemGreen
        deletedColorWell.color = NSColor(hexString: config.diffDeletedColorHex) ?? .systemRed
        modifiedColorWell.color = NSColor(hexString: config.diffModifiedColorHex) ?? .systemBlue
        headerColorWell.color = NSColor(hexString: config.diffHeaderColorHex) ?? .systemPurple
        positionColorWell.color = NSColor(hexString: config.diffPositionColorHex) ?? .systemBlue
        let family = config.diffFontName.isEmpty ? nil : NSFont(name: config.diffFontName, size: 12)?.familyName
        fontPopup.selectItem(withTitle: family ?? Self.systemFontTitle)
        if fontPopup.selectedItem == nil { fontPopup.selectItem(at: 0) }
        sizeField.stringValue = "\(Int(config.diffFontSize))"
        tabField.stringValue = "\(config.diffTabWidth)"
    }

    public func save() {
        guard isViewLoaded else { return }
        let config = ConfigManager.shared
        config.diffAddedColorHex = addedColorWell.color.hexString
        config.diffDeletedColorHex = deletedColorWell.color.hexString
        config.diffModifiedColorHex = modifiedColorWell.color.hexString
        config.diffHeaderColorHex = headerColorWell.color.hexString
        config.diffPositionColorHex = positionColorWell.color.hexString
        if let title = fontPopup.titleOfSelectedItem, title != Self.systemFontTitle,
           let name = NSFontManager.shared.availableMembers(ofFontFamily: title)?.first?.first as? String {
            config.diffFontName = name
        } else {
            config.diffFontName = ""
        }
        if let size = Double(sizeField.stringValue), (6...48).contains(size) { config.diffFontSize = size }
        if let width = Int(tabField.stringValue), (1...16).contains(width) { config.diffTabWidth = width }
    }

    @objc private func colorChanged() {
        save()
    }

    @objc private func resetDefaultsClicked() {
        addedColorWell.color = NSColor(hexString: DiffColors.defaultAddedHex)!
        deletedColorWell.color = NSColor(hexString: DiffColors.defaultDeletedHex)!
        modifiedColorWell.color = NSColor(hexString: DiffColors.defaultModifiedHex)!
        headerColorWell.color = NSColor(hexString: DiffColors.defaultHeaderHex)!
        positionColorWell.color = NSColor(hexString: DiffColors.defaultPositionHex)!
        fontPopup.selectItem(at: 0)
        sizeField.stringValue = "12"
        tabField.stringValue = "4"
        save()
    }
}
