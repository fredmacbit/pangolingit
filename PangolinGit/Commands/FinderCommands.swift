import Foundation

/// Targets of the Finder-only commands routed by `CommandRouter` (TortoiseGit `HelpCommand`).
extension CommandRouter {
    /// Opened by the Finder *Help* entry and `pangolingit://help`; same page as Help ▸ PangolinGit Documentation.
    static let helpURL = URL(string: "https://github.com/fredmacbit/pangolingit/wiki")!
}
