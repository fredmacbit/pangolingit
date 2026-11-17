import Foundation

/// Text formatting used by the Log window, following TortoiseGit's Dialogs 1 options.
public enum LogDisplayFormat {

    /// Formats a commit date.
    /// - Parameters:
    ///   - short: TortoiseGit's "Short date/time format".
    ///   - relative: "Use relative times" ("3 days ago").
    ///   - systemLocale: off = locale-independent `yyyy-MM-dd HH:mm(:ss)`.
    public static func date(_ date: Date, short: Bool, relative: Bool, systemLocale: Bool, now: Date = Date()) -> String {
        if relative {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            if !systemLocale { formatter.locale = Locale(identifier: "en_US_POSIX") }
            return formatter.localizedString(for: date, relativeTo: now)
        }
        let formatter = DateFormatter()
        if systemLocale {
            formatter.dateStyle = short ? .short : .medium
            formatter.timeStyle = short ? .short : .medium
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = short ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd HH:mm:ss Z"
        }
        return formatter.string(from: date)
    }

    /// Git-style abbreviated rename, e.g. `src/{old => new}/file.swift` (TortoiseGit's
    /// "Abbreviate renamings").
    public static func abbreviatedRename(from old: String, to new: String) -> String {
        let a = Array(old), b = Array(new)
        // Common prefix ending at a slash.
        var prefix = 0
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] {
            if a[i] == "/" { prefix = i + 1 }
            i += 1
        }
        // Common suffix starting at a slash, not overlapping the prefix.
        var suffix = 0
        var j = 0
        while j < a.count - prefix, j < b.count - prefix, a[a.count - 1 - j] == b[b.count - 1 - j] {
            if a[a.count - 1 - j] == "/" { suffix = j + 1 }
            j += 1
        }
        let head = String(a[0..<prefix])
        let oldMiddle = String(a[prefix..<(a.count - suffix)])
        let newMiddle = String(b[prefix..<(b.count - suffix)])
        let tail = String(a[(a.count - suffix)...])
        if head.isEmpty, tail.isEmpty { return "\(old) => \(new)" }
        return "\(head){\(oldMiddle) => \(newMiddle)}\(tail)"
    }
}
