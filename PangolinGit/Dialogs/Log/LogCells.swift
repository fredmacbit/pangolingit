import Cocoa
import PangolinGitCore

/// Reusable single-line text cell for the Log tables. Cells are recycled through
/// `makeView(withIdentifier:)` instead of creating an `NSTextField` per row and redraw (QF-26, LG-15).
final class LogTextCellView: NSTableCellView {
    static func make(in tableView: NSTableView, identifier: String, owner: Any?) -> LogTextCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let cell = tableView.makeView(withIdentifier: id, owner: owner) as? LogTextCellView {
            return cell
        }
        let cell = LogTextCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func configure(_ text: String, font: NSFont, color: NSColor = .labelColor) {
        textField?.stringValue = text
        textField?.font = font
        textField?.textColor = color
    }
}

/// Message column: ref labels drawn as rounded chips before (or after) the subject, like
/// TortoiseGit's `CGitLogListBase::DrawTagBranchMessage`. Drawn in one pass; no subviews.
final class LogMessageCellView: NSTableCellView {
    struct Chip {
        let text: String
        let kind: GitRefLabel.Kind
        let isCurrent: Bool
    }

    var chips: [Chip] = [] { didSet { needsDisplay = true } }
    var message = "" { didSet { needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 12) { didSet { needsDisplay = true } }
    var textColor = NSColor.labelColor { didSet { needsDisplay = true } }
    var chipsOnRight = false { didSet { needsDisplay = true } }
    /// Row selection changes text contrast.
    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }

    static func make(in tableView: NSTableView, owner: Any?) -> LogMessageCellView {
        let id = NSUserInterfaceItemIdentifier("LogMessageCell")
        if let cell = tableView.makeView(withIdentifier: id, owner: owner) as? LogMessageCellView {
            return cell
        }
        let cell = LogMessageCellView()
        cell.identifier = id
        return cell
    }

    /// Fill colour per ref kind (TortoiseGit's Settings ▸ Colors log-label colours).
    static func color(for kind: GitRefLabel.Kind) -> NSColor {
        switch kind {
        case .head: return .systemRed
        case .localBranch: return .systemGreen
        case .remoteBranch: return .systemOrange
        case .tag, .annotatedTag: return .systemYellow
        case .stash: return .systemGray
        case .bisectBad: return .systemRed
        case .bisectGood: return .systemGreen
        case .other: return .systemTeal
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let chipFont = NSFont.systemFont(ofSize: max(font.pointSize - 1.5, 9))
        let boldChipFont = NSFont.boldSystemFont(ofSize: chipFont.pointSize)
        let chipHeight = min(bounds.height - 4, chipFont.pointSize + 6)
        let chipY = (bounds.height - chipHeight) / 2

        var widths: [CGFloat] = []
        var attributed: [NSAttributedString] = []
        for chip in chips {
            let marker = chip.kind == .annotatedTag ? "◆ " : ""
            let text = NSAttributedString(string: marker + chip.text, attributes: [
                .font: chip.isCurrent ? boldChipFont : chipFont,
                .foregroundColor: NSColor.black
            ])
            attributed.append(text)
            widths.append(ceil(text.size().width) + 10)
        }
        let chipsWidth = widths.reduce(0) { $0 + $1 + 4 }

        func drawChips(startingAt x: CGFloat) {
            var x = x
            for (index, chip) in chips.enumerated() {
                let rect = NSRect(x: x, y: chipY, width: widths[index], height: chipHeight)
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                Self.color(for: chip.kind).withAlphaComponent(0.55).setFill()
                path.fill()
                if chip.isCurrent || chip.kind == .head {
                    NSColor.labelColor.withAlphaComponent(0.7).setStroke()
                    path.lineWidth = 1.2
                    path.stroke()
                }
                let size = attributed[index].size()
                attributed[index].draw(at: NSPoint(x: x + 5, y: chipY + (chipHeight - size.height) / 2))
                x += widths[index] + 4
            }
        }

        let color = backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : textColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: message, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let textHeight = ceil(text.size().height)
        let textY = (bounds.height - textHeight) / 2
        if chipsOnRight {
            let available = max(bounds.width - chipsWidth - 4, 0)
            text.draw(with: NSRect(x: 2, y: textY, width: available, height: textHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            drawChips(startingAt: max(bounds.width - chipsWidth, 2))
        } else {
            drawChips(startingAt: 2)
            let start = chips.isEmpty ? 2 : chipsWidth + 4
            text.draw(with: NSRect(x: start, y: textY, width: max(bounds.width - start, 0), height: textHeight),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

/// Table view that reports Return and modifier-arrow keys (TortoiseGit: Enter compares,
/// Alt+Up/Down/Left/Right navigate).
final class LogTableView: NSTableView {
    var onReturn: (() -> Void)?
    /// Arrow key with ⌥ held; returns true when handled.
    var onOptionArrow: ((UInt16) -> Bool)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // return, enter
            if let onReturn { onReturn(); return }
        case 123, 124, 125, 126 where event.modifierFlags.contains(.option):
            if onOptionArrow?(event.keyCode) == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

/// Plain read-only text window for unified diffs and similar output, with diff colouring.
final class LogTextWindowController: NSWindowController {
    init(title: String, text: String, isDiff: Bool = true) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        super.init(window: window)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = window.contentView!.bounds
        scroll.autoresizingMask = [.width, .height]
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textStorage?.setAttributedString(isDiff ? Self.colored(text) : NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]))
        window.contentView?.addSubview(scroll)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func colored(_ diff: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            var color = NSColor.labelColor
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                color = .secondaryLabelColor
            } else if line.hasPrefix("+") {
                color = .systemGreen
            } else if line.hasPrefix("-") {
                color = .systemRed
            } else if line.hasPrefix("@@") {
                color = .systemBlue
            } else if line.hasPrefix("commit ") {
                color = .systemOrange
            }
            result.append(NSAttributedString(string: line + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }
}
