import Cocoa
import PangolinGitCore

/// Diff colours from Settings ▸ Colors. While a colour is left at its default, the adaptive system
/// colour is used so diffs stay readable in dark mode.
@MainActor
enum DiffColors {
    static let defaultAddedHex = "#28A745"
    static let defaultDeletedHex = "#D73A49"
    static let defaultModifiedHex = "#0366D6"

    static var added: NSColor { resolve(ConfigManager.shared.diffAddedColorHex, default: defaultAddedHex, system: .systemGreen) }
    static var deleted: NSColor { resolve(ConfigManager.shared.diffDeletedColorHex, default: defaultDeletedHex, system: .systemRed) }
    static var modified: NSColor { resolve(ConfigManager.shared.diffModifiedColorHex, default: defaultModifiedHex, system: .systemBlue) }

    static let defaultHeaderHex = "#6F42C1"
    static let defaultPositionHex = "#0366D6"

    /// TortoiseGitUDiff's *Header* colour (`diff`, `index`, `---`, `+++` lines).
    static var header: NSColor { resolve(ConfigManager.shared.diffHeaderColorHex, default: defaultHeaderHex, system: .systemPurple) }
    /// TortoiseGitUDiff's *Position* colour (`@@` hunk headers).
    static var position: NSColor { resolve(ConfigManager.shared.diffPositionColorHex, default: defaultPositionHex, system: .systemBlue) }

    private static func resolve(_ hex: String, default defaultHex: String, system: NSColor) -> NSColor {
        guard hex.caseInsensitiveCompare(defaultHex) != .orderedSame, let custom = NSColor(hexString: hex) else { return system }
        return custom
    }
}

extension NSColor {
    /// `#RRGGBB` (the leading `#` is optional).
    convenience init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard clean.count == 6, let rgb = UInt32(clean, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// `#RRGGBB` in sRGB.
    var hexString: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(srgb.redComponent * 255)),
                      Int(round(srgb.greenComponent * 255)), Int(round(srgb.blueComponent * 255)))
    }
}
