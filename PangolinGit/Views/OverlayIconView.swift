import Cocoa
import PangolinGitCore

/// Reusable view for displaying status overlay badges.
public final class OverlayIconView: NSView {
    public var badgeKind: GitBadgeKind = .none {
        didSet {
            needsDisplay = true
        }
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Draw badge indicator
        let path = NSBezierPath(ovalIn: bounds)
        switch badgeKind {
        case .normal:
            NSColor.systemGreen.setFill()
        case .modified:
            NSColor.systemRed.setFill()
        case .conflicted:
            NSColor.systemYellow.setFill()
        case .added:
            NSColor.systemBlue.setFill()
        case .deleted:
            NSColor.systemGray.setFill()
        default:
            NSColor.clear.setFill()
        }
        path.fill()
    }
}
