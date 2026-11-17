import Cocoa
import PangolinGitCore

/// Settings ▸ Log: the log options of TortoiseGit's Dialogs 1 page (`SetDialogs.cpp`) and the
/// log-related options of Dialogs 2 (`SetDialogs2.cpp`: mailmap, FETCH_HEAD, tag order).
public final class LogSettingsViewController: NSViewController {

    private let limitField = NSTextField()
    private let limitPopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let fontSizeField = NSTextField()
    private let shortDate = NSButton(checkboxWithTitle: "Short date/time format", target: nil, action: nil)
    private let relativeTimes = NSButton(checkboxWithTitle: "Relative times (“3 days ago”)", target: nil, action: nil)
    private let systemLocale = NSButton(checkboxWithTitle: "Format dates for the system locale", target: nil, action: nil)
    private let doubleClick = NSButton(checkboxWithTitle: "Double-click compares with the previous revision", target: nil, action: nil)
    private let abbreviate = NSButton(checkboxWithTitle: "Abbreviate renamings (dir/{old => new})", target: nil, action: nil)
    private let symbolize = NSButton(checkboxWithTitle: "Symbolize ref names (/main, origin/≡)", target: nil, action: nil)
    private let labelsRight = NSButton(checkboxWithTitle: "Draw branch and tag labels on the right", target: nil, action: nil)
    private let fullMessage = NSButton(checkboxWithTitle: "Show subject and body on the log line", target: nil, action: nil)
    private let gravatar = NSButton(checkboxWithTitle: "Show Gravatar:", target: nil, action: nil)
    private let gravatarURL = NSTextField()
    private let revisionNumber = NSButton(checkboxWithTitle: "Show branch revision number (rev-list --count --first-parent)", target: nil, action: nil)
    private let describe = NSButton(checkboxWithTitle: "Show “git describe”:", target: nil, action: nil)
    private let describeStrategy = NSPopUpButton()
    private let describeLong = NSButton(checkboxWithTitle: "Always long format", target: nil, action: nil)
    private let describeFirstParent = NSButton(checkboxWithTitle: "Only follow first parent", target: nil, action: nil)
    private let mailmap = NSButton(checkboxWithTitle: "Use .mailmap for names and emails", target: nil, action: nil)
    private let fetchHead = NSButton(checkboxWithTitle: "Offer FETCH_HEAD in the branch chooser", target: nil, action: nil)
    private let tagsReversed = NSButton(checkboxWithTitle: "List tags in reverse order", target: nil, action: nil)

    private static let limitKinds = ["all", "commits", "years", "months", "weeks"]

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 440))
        setupUI()
        loadData()
    }

    private func setupUI() {
        limitPopup.addItems(withTitles: ["All commits", "Last N commits", "Last N years", "Last N months", "Last N weeks"])
        limitField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        fontPopup.addItem(withTitle: "System Font")
        fontPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        fontSizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        gravatarURL.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        describeStrategy.addItems(withTitles: ["Nearest tag before (--tags)", "First tag containing (--contains)"])

        let controls: [NSControl] = [limitPopup, fontPopup, describeStrategy] + allChecks
        for control in controls {
            control.target = self
            control.action = #selector(changed)
        }

        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.spacing = 6
            return stack
        }
        let content = NSStackView(views: [
            row([NSTextField(labelWithString: "New log windows show:"), limitPopup, limitField]),
            row([NSTextField(labelWithString: "Message font:"), fontPopup, fontSizeField, NSTextField(labelWithString: "pt")]),
            row([shortDate, relativeTimes]),
            systemLocale,
            doubleClick,
            abbreviate,
            symbolize,
            row([labelsRight, fullMessage]),
            row([gravatar, gravatarURL]),
            revisionNumber,
            row([describe, describeStrategy, describeLong, describeFirstParent]),
            mailmap,
            row([fetchHead, tagsReversed])
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
    }

    private var allChecks: [NSButton] {
        [shortDate, relativeTimes, systemLocale, doubleClick, abbreviate, symbolize, labelsRight, fullMessage, gravatar,
         revisionNumber, describe, describeLong, describeFirstParent, mailmap, fetchHead, tagsReversed]
    }

    public func loadData() {
        let config = ConfigManager.shared
        let limit = config.logDefaultLimit
        limitPopup.selectItem(at: Self.limitKinds.firstIndex(of: limit.kind) ?? 0)
        limitField.stringValue = limit == .unlimited ? "" : "\(limit.count)"
        if config.logFontName.isEmpty { fontPopup.selectItem(at: 0) } else { fontPopup.selectItem(withTitle: config.logFontName) }
        fontSizeField.stringValue = "\(Int(config.logFontSize))"
        shortDate.state = config.logShortDateFormat ? .on : .off
        relativeTimes.state = config.logRelativeTimes ? .on : .off
        systemLocale.state = config.logUseSystemLocale ? .on : .off
        doubleClick.state = config.logDoubleClickCompares ? .on : .off
        abbreviate.state = config.logAbbreviateRenamings ? .on : .off
        symbolize.state = config.logSymbolizeRefs ? .on : .off
        labelsRight.state = config.logLabelsOnRight ? .on : .off
        fullMessage.state = config.logFullMessageOnLine ? .on : .off
        gravatar.state = config.logShowGravatar ? .on : .off
        gravatarURL.stringValue = config.logGravatarURL
        revisionNumber.state = config.logShowBranchRevisionNumber ? .on : .off
        describe.state = config.logShowDescribe ? .on : .off
        describeStrategy.selectItem(at: config.logDescribeContains ? 1 : 0)
        describeLong.state = config.logDescribeAlwaysLong ? .on : .off
        describeFirstParent.state = config.logDescribeFirstParent ? .on : .off
        mailmap.state = config.useMailmap ? .on : .off
        fetchHead.state = config.branchesIncludeFetchHead ? .on : .off
        tagsReversed.state = config.sortTagsReversed ? .on : .off
        updateEnabledState()
    }

    public func save() {
        let config = ConfigManager.shared
        let kind = Self.limitKinds[max(limitPopup.indexOfSelectedItem, 0)]
        config.logDefaultLimit = GitLogQuery.Limit(kind: kind, count: Int(limitField.stringValue) ?? (kind == "commits" ? 1000 : 1))
        config.logFontName = fontPopup.indexOfSelectedItem <= 0 ? "" : (fontPopup.titleOfSelectedItem ?? "")
        if let size = Double(fontSizeField.stringValue), size >= 8, size <= 32 { config.logFontSize = size }
        config.logShortDateFormat = shortDate.state == .on
        config.logRelativeTimes = relativeTimes.state == .on
        config.logUseSystemLocale = systemLocale.state == .on
        config.logDoubleClickCompares = doubleClick.state == .on
        config.logAbbreviateRenamings = abbreviate.state == .on
        config.logSymbolizeRefs = symbolize.state == .on
        config.logLabelsOnRight = labelsRight.state == .on
        config.logFullMessageOnLine = fullMessage.state == .on
        config.logShowGravatar = gravatar.state == .on
        let url = gravatarURL.stringValue.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty { config.logGravatarURL = url }
        config.logShowBranchRevisionNumber = revisionNumber.state == .on
        config.logShowDescribe = describe.state == .on
        config.logDescribeContains = describeStrategy.indexOfSelectedItem == 1
        config.logDescribeAlwaysLong = describeLong.state == .on
        config.logDescribeFirstParent = describeFirstParent.state == .on
        config.useMailmap = mailmap.state == .on
        config.branchesIncludeFetchHead = fetchHead.state == .on
        config.sortTagsReversed = tagsReversed.state == .on
    }

    private func updateEnabledState() {
        limitField.isEnabled = limitPopup.indexOfSelectedItem > 0
        gravatarURL.isEnabled = gravatar.state == .on
        let describeOn = describe.state == .on
        describeStrategy.isEnabled = describeOn
        // --long and --first-parent only apply to the "--tags" strategy.
        describeLong.isEnabled = describeOn && describeStrategy.indexOfSelectedItem == 0
        describeFirstParent.isEnabled = describeOn && describeStrategy.indexOfSelectedItem == 0
    }

    @objc private func changed() {
        updateEnabledState()
        save()
    }
}

/// Top-down document view for scrolling settings panes.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
