import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Centralized localization and layout helper supporting Apple String Catalogs and RTL locales (Phases 11.1, 11.3, 11.5).
public enum LocalizationHelper {
    
    /// Returns the localized string for a given key, falling back to English or the key itself.
    public static func localized(_ key: String, comment: String = "") -> String {
        return NSLocalizedString(key, comment: comment)
    }
    
    /// Detects if the current user interface layout direction is Right-to-Left (e.g. Arabic, Hebrew).
    public static var isRightToLeft: Bool {
        #if canImport(AppKit)
        return NSApp?.userInterfaceLayoutDirection == .rightToLeft
        #else
        let code = Locale.preferredLanguages.first ?? Locale.current.languageCode ?? "en"
        return Locale.characterDirection(forLanguage: code) == .rightToLeft
        #endif
    }
    
    /// Returns the natural text alignment based on the current layout direction.
    #if canImport(AppKit)
    public static var naturalTextAlignment: NSTextAlignment {
        return isRightToLeft ? .right : .left
    }
    #endif
}
