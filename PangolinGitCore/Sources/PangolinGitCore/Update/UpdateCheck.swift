import Foundation

/// A published release, read from a GitHub-compatible releases feed.
public struct ReleaseInfo: Equatable, Sendable {
    public struct Asset: Equatable, Sendable {
        public let name: String
        public let downloadURL: URL
        public let size: Int
    }

    /// Version without a leading "v".
    public let version: String
    public let name: String
    /// Release notes (Markdown) shown in the changelog pane.
    public let notes: String
    public let pageURL: URL?
    public let publishedAt: Date?
    public let isPrerelease: Bool
    public let assets: [Asset]
}

/// Update-check logic behind PangolinGit's "Check for Updates" window (TortoiseGit's
/// `CCheckForUpdatesDlg`): feed parsing, version comparison, channel choice and the weekly schedule.
public enum UpdateCheck {

    /// Releases of the official repository; the Advanced option `UpdateCheckURL` (or a managed
    /// preference with that key) points the check at a mirror instead.
    public static let defaultFeedURL = URL(string: "https://api.github.com/repos/fredmacbit/pangolingit/releases")!

    /// TortoiseGit checks weekly.
    public static let interval: TimeInterval = 7 * 24 * 60 * 60

    /// Parses a releases list (or a single release object, as `/releases/latest` returns). Drafts are skipped.
    public static func parseReleases(_ data: Data) -> [ReleaseInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let objects: [[String: Any]]
        if let list = json as? [[String: Any]] {
            objects = list
        } else if let single = json as? [String: Any] {
            objects = [single]
        } else {
            return []
        }
        let iso = ISO8601DateFormatter()
        return objects.compactMap { object in
            guard (object["draft"] as? Bool) != true,
                  let tag = object["tag_name"] as? String, !tag.isEmpty else { return nil }
            let assets: [ReleaseInfo.Asset] = (object["assets"] as? [[String: Any]] ?? []).compactMap { asset in
                guard let name = asset["name"] as? String,
                      let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
                return ReleaseInfo.Asset(name: name, downloadURL: link, size: asset["size"] as? Int ?? 0)
            }
            return ReleaseInfo(
                version: normalizedVersion(tag),
                name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
                notes: object["body"] as? String ?? "",
                pageURL: (object["html_url"] as? String).flatMap(URL.init(string:)),
                publishedAt: (object["published_at"] as? String).flatMap { iso.date(from: $0) },
                isPrerelease: object["prerelease"] as? Bool ?? false,
                assets: assets
            )
        }
    }

    /// "v1.2.3" → "1.2.3".
    public static func normalizedVersion(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, first == "v" || first == "V" { return String(trimmed.dropFirst()) }
        return trimmed
    }

    /// Compares dotted versions numerically; a pre-release suffix (`1.2.0-beta.1`) sorts before the
    /// release with the same numbers.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func split(_ version: String) -> ([Int], String?) {
            let normalized = normalizedVersion(version)
            let parts = normalized.split(separator: "-", maxSplits: 1)
            let numbers = (parts.first ?? "").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
            return (numbers, parts.count > 1 ? String(parts[1]) : nil)
        }
        let (left, leftSuffix) = split(lhs)
        let (right, rightSuffix) = split(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        switch (leftSuffix, rightSuffix) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (a?, b?): return a.compare(b, options: .numeric)
        }
    }

    /// The newest release of the chosen channel, if it is newer than `currentVersion`.
    public static func availableUpdate(in releases: [ReleaseInfo], currentVersion: String,
                                       includePrereleases: Bool) -> ReleaseInfo? {
        let candidates = releases.filter { includePrereleases || !$0.isPrerelease }
        guard let newest = candidates.max(by: { compare($0.version, $1.version) == .orderedAscending }) else { return nil }
        return compare(newest.version, currentVersion) == .orderedDescending ? newest : nil
    }

    /// Whether an automatic check is due.
    public static func isAutomaticCheckDue(lastCheck: Date?, remindAfter: Date?, now: Date = Date()) -> Bool {
        if let remindAfter, now < remindAfter { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// The download that fits this Mac best: a .dmg, then a .pkg, then a .zip.
    public static func preferredAsset(of release: ReleaseInfo) -> ReleaseInfo.Asset? {
        for suffix in [".dmg", ".pkg", ".zip"] {
            if let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(suffix) }) { return asset }
        }
        return release.assets.first
    }
}
