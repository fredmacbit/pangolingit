import Cocoa
import PangolinGitCore

/// Settings pane for git blame viewer styling and options (`SettingsTBlame.cpp` in TortoiseGit):
/// colouring, age-gradient end points, font, date format, whitespace, moved/copied-line detection
/// (level and minimum block size) and first-parent blame.
public final class BlameSettingsViewController: NSViewController {

    private var colorModePopup: NSPopUpButton!
    private var newestWell: NSColorWell!
    private var oldestWell: NSColorWell!
    private var fontPopUp: NSPopUpButton!
    private var fontSizeField: NSTextField!
    private var dateFormatField: NSTextField!
    private var ignoreWhitespaceCheck: NSButton!
    private var detectionPopup: NSPopUpButton!
    private var thresholdField: NSTextField!
    private var firstParentCheck: NSButton!

    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        setupUI()
        loadData()
    }

    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Blame Viewer Settings")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)

        colorModePopup = NSPopUpButton()
        colorModePopup.addItems(withTitles: ["Color by Author", "Color by Age", "No Color"])
        newestWell = NSColorWell()
        oldestWell = NSColorWell()
        for well in [newestWell!, oldestWell!] {
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let gradient = NSStackView(views: [NSTextField(labelWithString: "Newest:"), newestWell, NSTextField(labelWithString: "Oldest:"), oldestWell])
        gradient.spacing = 6

        fontPopUp = NSPopUpButton()
        fontPopUp.addItems(withTitles: ["Menlo", "SF Mono", "Courier", "Monaco", "PT Mono"])
        fontSizeField = NSTextField()
        fontSizeField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let fontRow = NSStackView(views: [fontPopUp, NSTextField(labelWithString: "Size:"), fontSizeField])
        fontRow.spacing = 6

        dateFormatField = NSTextField()
        dateFormatField.placeholderString = "yyyy-MM-dd HH:mm"
        dateFormatField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        ignoreWhitespaceCheck = NSButton(checkboxWithTitle: "Ignore whitespace changes (-w)", target: nil, action: nil)
        detectionPopup = NSPopUpButton()
        detectionPopup.addItems(withTitles: GitBlame.MoveDetection.allCases.map(\.title))
        thresholdField = NSTextField()
        thresholdField.placeholderString = "20"
        thresholdField.toolTip = "Minimum number of alphanumeric characters a moved or copied block must have (empty = git's default of 20)"
        thresholdField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let detectionRow = NSStackView(views: [detectionPopup, NSTextField(labelWithString: "Min. characters:"), thresholdField])
        detectionRow.spacing = 6
        firstParentCheck = NSButton(checkboxWithTitle: "Follow only the first parent of merges (--first-parent)", target: nil, action: nil)

        for control in [colorModePopup, newestWell, oldestWell, fontPopUp, ignoreWhitespaceCheck, detectionPopup, firstParentCheck] as [NSControl] {
            control.target = self
            control.action = #selector(settingChanged)
        }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Coloring:"), colorModePopup],
            [NSTextField(labelWithString: "Age gradient:"), gradient],
            [NSTextField(labelWithString: "Font:"), fontRow],
            [NSTextField(labelWithString: "Date format:"), dateFormatField],
            [NSTextField(labelWithString: "Moved/copied lines:"), detectionRow],
            [NSGridCell.emptyContentView, ignoreWhitespaceCheck],
            [NSGridCell.emptyContentView, firstParentCheck]
        ])
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let stack = NSStackView(views: [titleLabel, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
        ])
    }

    public func loadData() {
        let config = ConfigManager.shared
        switch config.blameColorMode {
        case "date": colorModePopup.selectItem(at: 1)
        case "none": colorModePopup.selectItem(at: 2)
        default: colorModePopup.selectItem(at: 0)
        }
        newestWell.color = NSColor(hexString: config.blameNewestColorHex) ?? .systemOrange
        oldestWell.color = NSColor(hexString: config.blameOldestColorHex) ?? .systemBlue
        if fontPopUp.itemTitles.contains(config.blameFontName) {
            fontPopUp.selectItem(withTitle: config.blameFontName)
        }
        fontSizeField.stringValue = "\(Int(config.blameFontSize))"
        dateFormatField.stringValue = config.blameDateFormat
        ignoreWhitespaceCheck.state = config.blameIgnoreWhitespace ? .on : .off
        detectionPopup.selectItem(at: config.blameMoveDetection.rawValue)
        thresholdField.stringValue = config.blameMoveThreshold > 0 ? "\(config.blameMoveThreshold)" : ""
        firstParentCheck.state = config.blameFirstParent ? .on : .off
    }

    public func save() {
        let config = ConfigManager.shared
        config.blameColorMode = ["author", "date", "none"][max(0, colorModePopup.indexOfSelectedItem)]
        config.blameNewestColorHex = newestWell.color.hexString
        config.blameOldestColorHex = oldestWell.color.hexString
        config.blameFontName = fontPopUp.titleOfSelectedItem ?? "Menlo"
        if let size = Double(fontSizeField.stringValue) {
            config.blameFontSize = size
        }
        config.blameDateFormat = dateFormatField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.blameIgnoreWhitespace = ignoreWhitespaceCheck.state == .on
        config.blameMoveDetection = GitBlame.MoveDetection(rawValue: detectionPopup.indexOfSelectedItem) ?? .disabled
        config.blameMoveThreshold = Int(thresholdField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        config.blameFirstParent = firstParentCheck.state == .on
    }

    @objc private func settingChanged() {
        save()
    }
}
