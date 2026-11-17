import Cocoa
import PangolinGitCore

/// Auto Layout helper ensuring consistent RTL (Right-to-Left) behavior across all PangolinGit dialogs (Phase 11.3).
public enum LayoutHelper {
    
    /// Configures leading and trailing Auto Layout constraints with RTL-safe layout margins.
    public static func pinToContainerHorizontally(_ view: NSView, in container: NSView, padding: CGFloat = 20) -> [NSLayoutConstraint] {
        return [
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding)
        ]
    }
    
    /// Configures full pin with leading, trailing, top, and bottom.
    public static func pinEdges(_ view: NSView, to container: NSView, insets: NSEdgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)) -> [NSLayoutConstraint] {
        return [
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom)
        ]
    }
    
    /// Adjusts an NSTextField's alignment to respect RTL layout.
    public static func configureBidiAlignment(for textField: NSTextField) {
        if LocalizationHelper.isRightToLeft {
            textField.alignment = .right
            textField.baseWritingDirection = .rightToLeft
        } else {
            textField.alignment = .left
            textField.baseWritingDirection = .leftToRight
        }
    }
}
