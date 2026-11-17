import Cocoa
import PangolinGitCore

/// Dual-pane side-by-side diff with a unified alternative, mirroring TortoiseGitMerge's two-pane
/// view (`src/TortoiseMerge/LeftView.cpp`, `RightView.cpp`, `LocatorBar.cpp`): aligned rows with
/// full-width line colours, a line-number gutter with change markers, intra-line highlighting,
/// a locator bar, difference navigation, collapse/wrap toggles and the find bar.
public final class SideBySideDiffView: NSView {

    public enum ViewMode: Int {
        case sideBySide = 0
        case unified = 1
    }

    /// Which pane a context-menu click or a find request refers to.
    public enum Side {
        case left
        case right
    }

    private var modeSegment: NSSegmentedControl!
    private var locatorBar: DiffLocatorBar!
    private var leftScrollView: NSScrollView!
    private var leftTextView: DiffTextView!
    private var rightScrollView: NSScrollView!
    private var rightTextView: DiffTextView!
    private var unifiedScrollView: NSScrollView!
    private var unifiedTextView: DiffTextView!
    private var paneConstraints: [NSLayoutConstraint] = []

    private var isSyncingScroll = false
    private var rawDiff = ""
    /// Rows before collapsing; `rows` is what is displayed.
    private var allRows: [DiffRow] = []
    public private(set) var rows: [DiffRow] = []
    /// Ranges of `rows` holding changes (F7 / Shift-F7 targets).
    public private(set) var blocks: [Range<Int>] = []
    /// Index into `blocks` of the difference last navigated to.
    public private(set) var currentBlockIndex: Int?

    public var inlineMode: InlineDiffMode = ConfigManager.shared.inlineDiffMode {
        didSet { if oldValue != inlineMode { rebuildRows() } }
    }
    public var collapseUnchanged: Bool = ConfigManager.shared.diffCollapseUnchanged {
        didSet { if oldValue != collapseUnchanged { rebuildRows() } }
    }
    public var wrapLines: Bool = ConfigManager.shared.diffWrapLines {
        didSet { applyWrap() }
    }
    /// Hides the Side-by-Side / Unified switch when the host window provides its own.
    public var showsModeSwitch = true {
        didSet { modeSegment.isHidden = !showsModeSwitch; layoutPanes() }
    }
    public var viewMode: ViewMode = .sideBySide {
        didSet { modeSegment.selectedSegment = viewMode.rawValue; applyMode() }
    }
    /// Extra context-menu items for a click on `row` in `side` (e.g. *Use left block*).
    public var contextMenuProvider: ((_ side: Side, _ row: Int?) -> [NSMenuItem])?
    /// Called after navigation so a host can enable block actions.
    public var onCurrentBlockChange: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        modeSegment = NSSegmentedControl(labels: ["Side-by-Side", "Unified"], trackingMode: .selectOne, target: self, action: #selector(modeChanged))
        modeSegment.selectedSegment = 0
        modeSegment.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeSegment)

        locatorBar = DiffLocatorBar()
        locatorBar.translatesAutoresizingMaskIntoConstraints = false
        locatorBar.onJump = { [weak self] fraction in self?.scroll(toFraction: fraction) }
        addSubview(locatorBar)

        (leftScrollView, leftTextView) = createTextPane(side: .left)
        (rightScrollView, rightTextView) = createTextPane(side: .right)
        (unifiedScrollView, unifiedTextView) = createTextPane(side: .right)
        unifiedScrollView.isHidden = true
        unifiedScrollView.verticalRulerView = nil
        unifiedScrollView.rulersVisible = false
        for pane in [leftScrollView!, rightScrollView!, unifiedScrollView!] { addSubview(pane) }

        NotificationCenter.default.addObserver(self, selector: #selector(leftDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: leftScrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(rightDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: rightScrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(frameDidChange(_:)), name: NSView.frameDidChangeNotification, object: rightScrollView.contentView)
        layoutPanes()
        applyWrap()
    }

    private func layoutPanes() {
        NSLayoutConstraint.deactivate(paneConstraints)
        let top = showsModeSwitch ? modeSegment.bottomAnchor : topAnchor
        let gap: CGFloat = showsModeSwitch ? 8 : 0
        paneConstraints = [
            modeSegment.topAnchor.constraint(equalTo: topAnchor),
            modeSegment.trailingAnchor.constraint(equalTo: trailingAnchor),
            modeSegment.widthAnchor.constraint(equalToConstant: 200),

            locatorBar.topAnchor.constraint(equalTo: top, constant: gap),
            locatorBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            locatorBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            locatorBar.widthAnchor.constraint(equalToConstant: 14),

            leftScrollView.topAnchor.constraint(equalTo: top, constant: gap),
            leftScrollView.leadingAnchor.constraint(equalTo: locatorBar.trailingAnchor, constant: 3),
            leftScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftScrollView.trailingAnchor.constraint(equalTo: centerXAnchor, constant: 4),

            rightScrollView.topAnchor.constraint(equalTo: top, constant: gap),
            rightScrollView.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 8),
            rightScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            unifiedScrollView.topAnchor.constraint(equalTo: top, constant: gap),
            unifiedScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            unifiedScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            unifiedScrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(paneConstraints)
    }

    private func createTextPane(side: Side) -> (NSScrollView, DiffTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let storage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)

        let textView = DiffTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize), textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.menuProvider = { [weak self] textView, event in self?.contextMenu(for: textView, side: side, event: event) }
        scrollView.documentView = textView

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return (scrollView, textView)
    }

    // MARK: - Fonts

    static var diffFont: NSFont {
        let config = ConfigManager.shared
        let size = CGFloat(config.diffFontSize > 4 ? config.diffFontSize : 12)
        if !config.diffFontName.isEmpty, let font = NSFont(name: config.diffFontName, size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: diffFont]).width
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * CGFloat(max(1, ConfigManager.shared.diffTabWidth))
        style.lineBreakMode = .byCharWrapping
        return style
    }

    // MARK: - Diff Loading

    public func setDiff(rawUnifiedText: String) {
        rawDiff = rawUnifiedText
        unifiedTextView.textStorage?.setAttributedString(UnifiedDiffFormatter.attributedString(for: rawUnifiedText))
        rebuildRows()
    }

    /// Re-applies fonts and colours after a settings change.
    public func reloadAppearance() {
        unifiedTextView.textStorage?.setAttributedString(UnifiedDiffFormatter.attributedString(for: rawDiff))
        rebuildRows()
    }

    private func rebuildRows() {
        allRows = SideBySideDiffBuilder.rows(fromUnifiedDiff: rawDiff, inline: inlineMode,
                                             maxInlineLength: ConfigManager.shared.maxInlineLength)
        rows = collapseUnchanged ? SideBySideDiffBuilder.collapse(allRows) : allRows
        blocks = SideBySideDiffBuilder.changeBlocks(rows)
        if let index = currentBlockIndex, index >= blocks.count { currentBlockIndex = nil }
        render(side: .left, into: leftTextView)
        render(side: .right, into: rightTextView)
        locatorBar.update(rows: rows)
        updateLocatorVisibleRange()
    }

    private func render(side: Side, into textView: DiffTextView) {
        let font = Self.diffFont
        let paragraph = Self.paragraphStyle
        let result = NSMutableAttributedString()
        var starts: [Int] = []
        var backgrounds: [NSColor?] = []
        var numbers: [Int?] = []
        var markers: [DiffRow.Kind?] = []
        var offset = 0
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        let added = DiffColors.added, deleted = DiffColors.deleted

        for row in rows {
            let present = side == .left ? row.leftNumber != nil : row.rightNumber != nil
            var text = Self.displayable(side == .left ? row.leftText : row.rightText)
            var attributes = base
            var background: NSColor?
            var marker: DiffRow.Kind?
            switch row.kind {
            case .context:
                break
            case .header:
                attributes[.foregroundColor] = DiffColors.position
                background = DiffColors.position.withAlphaComponent(0.08)
            case .fold:
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                background = NSColor.quaternaryLabelColor.withAlphaComponent(0.15)
            case .added, .deleted, .modified:
                if !present {
                    text = ""
                    background = NSColor.quaternaryLabelColor.withAlphaComponent(0.25)
                } else if row.kind == .modified {
                    background = (side == .left ? deleted : added).withAlphaComponent(0.10)
                    marker = .modified
                } else {
                    background = (row.kind == .added ? added : deleted).withAlphaComponent(0.14)
                    marker = row.kind
                }
            }
            starts.append(offset)
            backgrounds.append(background)
            numbers.append(side == .left ? row.leftNumber : row.rightNumber)
            markers.append(marker)
            let piece = NSMutableAttributedString(string: text + "\n", attributes: attributes)
            if row.kind == .modified, present {
                let color = (side == .left ? deleted : added).withAlphaComponent(0.35)
                let length = (text as NSString).length
                for range in side == .left ? row.leftInline : row.rightInline where range.upperBound <= length {
                    piece.addAttribute(.backgroundColor, value: color, range: NSRange(location: range.lowerBound, length: range.count))
                }
            }
            result.append(piece)
            offset += (text as NSString).length + 1
        }

        if let layoutManager = textView.layoutManager as? DiffLayoutManager {
            layoutManager.paragraphStarts = starts
            layoutManager.rowBackgrounds = backgrounds
        }
        if let ruler = textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView {
            ruler.numbers = numbers
            ruler.changeMarkers = markers
            ruler.updateThickness(maxNumber: numbers.compactMap { $0 }.max() ?? 0)
        }
        textView.textStorage?.setAttributedString(result)
        textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Characters that NSTextView would treat as paragraph breaks would shift the alignment.
    private static func displayable(_ text: String) -> String {
        guard text.contains(where: { $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" || $0 == "\u{0B}" || $0 == "\u{0C}" }) else { return text }
        return text.replacingOccurrences(of: "\r", with: "␍")
            .replacingOccurrences(of: "\u{2028}", with: "␤")
            .replacingOccurrences(of: "\u{2029}", with: "¶")
            .replacingOccurrences(of: "\u{0B}", with: "␋")
            .replacingOccurrences(of: "\u{0C}", with: "␌")
    }

    // MARK: - Wrap & mode

    private func applyWrap() {
        for textView in [leftTextView!, rightTextView!, unifiedTextView!] {
            guard let container = textView.textContainer, let scrollView = textView.enclosingScrollView else { continue }
            if wrapLines {
                textView.isHorizontallyResizable = false
                container.widthTracksTextView = true
                container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
                textView.frame.size.width = scrollView.contentSize.width
            } else {
                container.widthTracksTextView = false
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textView.isHorizontallyResizable = true
            }
            scrollView.hasHorizontalScroller = !wrapLines
            textView.needsDisplay = true
            scrollView.verticalRulerView?.needsDisplay = true
        }
    }

    @objc private func modeChanged() {
        viewMode = ViewMode(rawValue: modeSegment.selectedSegment) ?? .sideBySide
    }

    private func applyMode() {
        let unified = viewMode == .unified
        leftScrollView.isHidden = unified
        rightScrollView.isHidden = unified
        locatorBar.isHidden = unified
        unifiedScrollView.isHidden = !unified
    }

    // MARK: - Navigation (TortoiseMerge F7 / Shift-F7, Ctrl-G)

    public var hasNextDifference: Bool { nextBlockIndex(forward: true) != nil }
    public var hasPreviousDifference: Bool { nextBlockIndex(forward: false) != nil }

    public func goToNextDifference() { goToBlock(nextBlockIndex(forward: true)) }
    public func goToPreviousDifference() { goToBlock(nextBlockIndex(forward: false)) }

    public func goToFirstDifference() { goToBlock(blocks.isEmpty ? nil : 0) }

    private func nextBlockIndex(forward: Bool) -> Int? {
        guard !blocks.isEmpty else { return nil }
        if let current = currentBlockIndex {
            let next = current + (forward ? 1 : -1)
            return blocks.indices.contains(next) ? next : nil
        }
        // Not navigated yet: start from what is on screen.
        let top = topVisibleRow()
        if forward { return blocks.firstIndex { $0.lowerBound >= top } }
        return blocks.lastIndex { $0.lowerBound < top }
    }

    private func goToBlock(_ index: Int?) {
        guard let index, blocks.indices.contains(index) else { NSSound.beep(); return }
        currentBlockIndex = index
        selectRows(blocks[index])
        onCurrentBlockChange?()
    }

    /// Scrolls to and selects the row showing line `line` of the right (or, if absent, left) file.
    @discardableResult
    public func goToLine(_ line: Int, side: Side = .right) -> Bool {
        func find() -> Int? {
            rows.firstIndex { (side == .right ? $0.rightNumber : $0.leftNumber) == line }
        }
        if find() == nil, collapseUnchanged { collapseUnchanged = false }
        guard let row = find() else { return false }
        selectRows(row..<(row + 1))
        return true
    }

    /// The difference block containing `row`, if any.
    public func blockIndex(containing row: Int) -> Int? {
        blocks.firstIndex { $0.contains(row) }
    }

    private func selectRows(_ range: Range<Int>) {
        for textView in [leftTextView!, rightTextView!] {
            guard let layoutManager = textView.layoutManager as? DiffLayoutManager,
                  range.lowerBound < layoutManager.paragraphStarts.count else { continue }
            let start = layoutManager.paragraphStarts[range.lowerBound]
            let end = range.upperBound < layoutManager.paragraphStarts.count
                ? layoutManager.paragraphStarts[range.upperBound] - 1 : (textView.string as NSString).length
            let charRange = NSRange(location: start, length: max(0, end - start))
            textView.setSelectedRange(charRange)
        }
        // Centre the block in the right pane; the left follows through scroll sync.
        scrollRowToCenter(range.lowerBound, in: rightTextView)
        updateLocatorVisibleRange()
    }

    private func scrollRowToCenter(_ row: Int, in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager as? DiffLayoutManager,
              row < layoutManager.paragraphStarts.count, let scrollView = textView.enclosingScrollView else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: layoutManager.paragraphStarts[row])
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let visible = scrollView.contentView.bounds
        var origin = NSPoint(x: visible.minX, y: rect.minY - visible.height / 3)
        let maxY = max(0, textView.frame.height - visible.height)
        origin.y = min(max(0, origin.y), maxY)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func topVisibleRow() -> Int {
        row(atY: rightScrollView.contentView.bounds.minY, in: rightTextView) ?? 0
    }

    private func row(atY y: CGFloat, in textView: NSTextView) -> Int? {
        guard let layoutManager = textView.layoutManager as? DiffLayoutManager, let container = textView.textContainer,
              !layoutManager.paragraphStarts.isEmpty, layoutManager.numberOfGlyphs > 0 else { return nil }
        let point = NSPoint(x: 0, y: max(0, y - textView.textContainerInset.height))
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        return layoutManager.row(forCharacter: layoutManager.characterIndexForGlyph(at: glyph))
    }

    private func scroll(toFraction fraction: CGFloat) {
        guard !rows.isEmpty else { return }
        let row = min(rows.count - 1, max(0, Int(fraction * CGFloat(rows.count))))
        scrollRowToCenter(row, in: rightTextView)
    }

    // MARK: - Find (Ctrl-F in TortoiseMerge)

    /// Shows the find bar of the focused pane (right pane by default).
    public func showFindBar() {
        let target: NSTextView
        if viewMode == .unified {
            target = unifiedTextView
        } else if window?.firstResponder === leftTextView {
            target = leftTextView
        } else {
            target = rightTextView
        }
        window?.makeFirstResponder(target)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        target.performTextFinderAction(item)
    }

    // MARK: - Context menu

    private func contextMenu(for textView: DiffTextView, side: Side, event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        var row: Int?
        if textView !== unifiedTextView, let layoutManager = textView.layoutManager as? DiffLayoutManager, let container = textView.textContainer {
            var point = textView.convert(event.locationInWindow, from: nil)
            point.y -= textView.textContainerInset.height
            if layoutManager.numberOfGlyphs > 0 {
                let glyph = layoutManager.glyphIndex(for: point, in: container)
                row = layoutManager.row(forCharacter: layoutManager.characterIndexForGlyph(at: glyph))
            }
        }
        for item in contextMenuProvider?(side, row) ?? [] { menu.addItem(item) }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - Synchronized scrolling

    @objc private func leftDidScroll(_ notification: Notification) {
        sync(from: leftScrollView, fromText: leftTextView, to: rightScrollView, toText: rightTextView)
    }

    @objc private func rightDidScroll(_ notification: Notification) {
        sync(from: rightScrollView, fromText: rightTextView, to: leftScrollView, toText: leftTextView)
    }

    @objc private func frameDidChange(_ notification: Notification) {
        if wrapLines { applyWrap() }
        updateLocatorVisibleRange()
    }

    /// Aligns by row rather than by pixel so wrapped rows of different heights stay side by side.
    private func sync(from source: NSScrollView, fromText: NSTextView, to target: NSScrollView, toText: NSTextView) {
        source.verticalRulerView?.needsDisplay = true
        guard !isSyncingScroll else { return }
        isSyncingScroll = true
        defer { isSyncingScroll = false }
        let bounds = source.contentView.bounds
        var origin = NSPoint(x: bounds.minX, y: bounds.minY)
        if wrapLines, let row = row(atY: bounds.minY, in: fromText),
           let sourceRect = rect(ofRow: row, in: fromText), let targetRect = rect(ofRow: row, in: toText) {
            origin.y = targetRect.minY + min(bounds.minY - sourceRect.minY, targetRect.height)
        }
        target.contentView.scroll(to: origin)
        target.reflectScrolledClipView(target.contentView)
        target.verticalRulerView?.needsDisplay = true
        updateLocatorVisibleRange()
    }

    private func rect(ofRow row: Int, in textView: NSTextView) -> NSRect? {
        guard let layoutManager = textView.layoutManager as? DiffLayoutManager, row < layoutManager.paragraphStarts.count,
              layoutManager.numberOfGlyphs > 0 else { return nil }
        let start = layoutManager.paragraphStarts[row]
        let end = row + 1 < layoutManager.paragraphStarts.count ? layoutManager.paragraphStarts[row + 1] : (textView.string as NSString).length
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: start, length: max(1, end - start)), actualCharacterRange: nil)
        guard let container = textView.textContainer else { return nil }
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    private func updateLocatorVisibleRange() {
        guard !rows.isEmpty, let top = row(atY: rightScrollView.contentView.bounds.minY, in: rightTextView),
              let bottom = row(atY: rightScrollView.contentView.bounds.maxY, in: rightTextView) else {
            locatorBar.visibleFraction = 0..<1
            return
        }
        let total = CGFloat(rows.count)
        locatorBar.visibleFraction = CGFloat(top) / total..<CGFloat(bottom + 1) / total
    }
}

// MARK: - Text view with per-click context menu

final class DiffTextView: NSTextView {
    var menuProvider: ((DiffTextView, NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(self, event) ?? super.menu(for: event)
    }
}

// MARK: - Layout manager drawing full-width row backgrounds

/// Draws each row's background across the whole pane width, as TortoiseMerge colours whole lines;
/// glyph-level `.backgroundColor` (intra-line marks) is drawn on top by `super`.
final class DiffLayoutManager: NSLayoutManager {
    /// UTF-16 offset of each row's first character.
    var paragraphStarts: [Int] = []
    var rowBackgrounds: [NSColor?] = []

    func row(forCharacter index: Int) -> Int {
        var low = 0, high = paragraphStarts.count - 1
        guard high >= 0 else { return 0 }
        while low < high {
            let mid = (low + high + 1) / 2
            if paragraphStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let width = max(firstTextView?.bounds.width ?? 0, firstTextView?.enclosingScrollView?.contentSize.width ?? 0)
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphRange, _ in
            let row = self.row(forCharacter: self.characterIndexForGlyph(at: glyphRange.location))
            guard row < self.rowBackgrounds.count, let color = self.rowBackgrounds[row] else { return }
            color.setFill()
            NSRect(x: 0, y: rect.minY + origin.y, width: width, height: rect.height).fill()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

// MARK: - Line-number gutter

/// Line numbers plus a change marker per row (TortoiseMerge's line-number margin and
/// line-status icons: + added, − removed, ≠ edited).
final class LineNumberRulerView: NSRulerView {
    var numbers: [Int?] = []
    var changeMarkers: [DiffRow.Kind?] = []

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateThickness(maxNumber: Int) {
        let digits = max(3, String(maxNumber).count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let width = ("8" as NSString).size(withAttributes: [.font: font]).width * CGFloat(digits) + 20
        if abs(ruleThickness - width) > 0.5 { ruleThickness = ceil(width) }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let textView = clientView as? NSTextView, let layoutManager = textView.layoutManager as? DiffLayoutManager,
              let container = textView.textContainer, let scrollView, layoutManager.numberOfGlyphs > 0 else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        var visible = scrollView.contentView.bounds
        visible.origin.y -= textView.textContainerInset.height
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, glyphs, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphs.location)
            let row = layoutManager.row(forCharacter: charIndex)
            guard row < layoutManager.paragraphStarts.count, layoutManager.paragraphStarts[row] == charIndex else { return }
            let y = self.convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerInset.height), from: textView).y
            if row < self.numbers.count, let number = self.numbers[row] {
                let label = "\(number)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: self.ruleThickness - 14 - size.width, y: y + (fragment.height - size.height) / 2), withAttributes: attributes)
            }
            if row < self.changeMarkers.count, let marker = self.changeMarkers[row] {
                let (symbol, color): (String, NSColor) = {
                    switch marker {
                    case .added: return ("+", DiffColors.added)
                    case .deleted: return ("−", DiffColors.deleted)
                    default: return ("≠", DiffColors.modified)
                    }
                }()
                let markerAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: color]
                let size = (symbol as NSString).size(withAttributes: markerAttributes)
                (symbol as NSString).draw(at: NSPoint(x: self.ruleThickness - 11, y: y + (fragment.height - size.height) / 2), withAttributes: markerAttributes)
            }
        }
    }
}

// MARK: - Locator bar

/// Overview strip mapping every difference in the file; click or drag to jump
/// (TortoiseMerge's `CLocatorBar`).
final class DiffLocatorBar: NSView {
    var onJump: ((CGFloat) -> Void)?
    var visibleFraction: Range<CGFloat> = 0..<1 { didSet { needsDisplay = true } }
    private var segments: [(Range<CGFloat>, NSColor)] = []

    override var isFlipped: Bool { true }

    func update(rows: [DiffRow]) {
        segments.removeAll()
        guard !rows.isEmpty else { needsDisplay = true; return }
        let total = CGFloat(rows.count)
        var index = 0
        while index < rows.count {
            let kind = rows[index].kind
            var end = index + 1
            while end < rows.count && rows[end].kind == kind { end += 1 }
            let color: NSColor?
            switch kind {
            case .added: color = DiffColors.added
            case .deleted: color = DiffColors.deleted
            case .modified: color = DiffColors.modified
            default: color = nil
            }
            if let color { segments.append((CGFloat(index) / total..<CGFloat(end) / total, color)) }
            index = end
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        for (range, color) in segments {
            color.withAlphaComponent(0.8).setFill()
            let y = range.lowerBound * bounds.height
            NSRect(x: 2, y: y, width: bounds.width - 4, height: max(2, (range.upperBound - range.lowerBound) * bounds.height)).fill()
        }
        let visible = NSRect(x: 0.5, y: visibleFraction.lowerBound * bounds.height, width: bounds.width - 1,
                             height: max(4, (visibleFraction.upperBound - visibleFraction.lowerBound) * bounds.height))
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
        NSBezierPath(rect: visible).stroke()
    }

    override func mouseDown(with event: NSEvent) { jump(event) }
    override func mouseDragged(with event: NSEvent) { jump(event) }

    private func jump(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onJump?(min(1, max(0, point.y / max(1, bounds.height))))
    }
}

// MARK: - Unified diff colouring

/// Colours raw `git diff` text like TortoiseGitUDiff: command, header, position, added and removed lines.
enum UnifiedDiffFormatter {
    @MainActor
    static func attributedString(for diff: String) -> NSAttributedString {
        let font = SideBySideDiffView.diffFont
        let paragraph = SideBySideDiffView.paragraphStyle
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        var inHunk = false
        for line in diff.components(separatedBy: "\n") {
            var attributes = base
            if line.hasPrefix("@@") {
                inHunk = true
                attributes[.foregroundColor] = DiffColors.position
            } else if line.hasPrefix("diff ") || line.hasPrefix("From ") && !inHunk {
                inHunk = false
                attributes[.foregroundColor] = DiffColors.header
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            } else if !inHunk && (line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++")
                                  || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("rename ")
                                  || line.hasPrefix("similarity") || line.hasPrefix("old mode") || line.hasPrefix("new mode")) {
                attributes[.foregroundColor] = DiffColors.header
            } else if line.hasPrefix("+") && inHunk {
                attributes[.foregroundColor] = DiffColors.added
                attributes[.backgroundColor] = DiffColors.added.withAlphaComponent(0.10)
            } else if line.hasPrefix("-") && inHunk {
                attributes[.foregroundColor] = DiffColors.deleted
                attributes[.backgroundColor] = DiffColors.deleted.withAlphaComponent(0.10)
            } else if line.hasPrefix("\\") {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            } else if !line.hasPrefix(" ") && !line.isEmpty {
                // Commit headers of a format-patch / log -p, outside hunks.
                inHunk = false
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            }
            result.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }
        return result
    }
}
