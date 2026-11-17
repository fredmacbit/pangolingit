import Foundation

/// Log and Statistics preferences: TortoiseGit's Settings ▸ Dialogs 1 page (`SetDialogs.cpp`), the
/// log-related options of Dialogs 2 (`SetDialogs2.cpp`) and the state the Log dialog remembers
/// between runs (`LogDialog\…` registry values).
public extension ConfigManager {

    enum LogKeys {
        public static let limitKind = "log.limitKind"
        public static let limitCount = "log.limitCount"
        public static let fontName = "log.fontName"
        public static let fontSize = "log.fontSize"
        public static let shortDateFormat = "log.shortDateFormat"
        public static let relativeTimes = "log.relativeTimes"
        public static let useSystemLocale = "log.useSystemLocale"
        public static let doubleClickCompares = "log.doubleClickCompares"
        public static let abbreviateRenamings = "log.abbreviateRenamings"
        public static let symbolizeRefs = "log.symbolizeRefs"
        public static let showGravatar = "log.showGravatar"
        public static let gravatarURL = "log.gravatarURL"
        public static let labelsOnRight = "log.labelsOnRight"
        public static let fullMessageOnLine = "log.fullMessageOnLine"
        public static let showBranchRevisionNumber = "log.showBranchRevisionNumber"
        public static let showDescribe = "log.showDescribe"
        public static let describeContains = "log.describeContains"
        public static let describeAlwaysLong = "log.describeAlwaysLong"
        public static let describeFirstParent = "log.describeFirstParent"
        public static let useMailmap = "log.useMailmap"
        public static let includeFetchHead = "log.includeFetchHead"
        public static let sortTagsReversed = "log.sortTagsReversed"
        public static let searchFields = "log.searchFields"
        public static let searchRegex = "log.searchRegex"
        public static let searchCaseSensitive = "log.searchCaseSensitive"
        public static let scopePrefix = "log.scope."
        public static let showWorkingTreeChanges = "log.showWorkingTreeChanges"
        public static let showUnversioned = "log.showUnversioned"
        public static let showRefLabels = "log.showRefLabels"
        public static let hideUnrelatedPaths = "log.hideUnrelatedPaths"
        public static let statsSortByCount = "stats.sortByCommitCount"
        public static let statsCaseSensitive = "stats.authorsCaseSensitive"
        public static let statsUseCommitter = "stats.useCommitterNames"
        public static let statsUseCommitDates = "stats.useCommitDates"
        public static let statsAuthorsShown = "stats.authorsShown"
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    // MARK: Dialogs 1

    /// Default "show only" limitation of a new Log window (TortoiseGit default: no limit).
    var logDefaultLimit: GitLogQuery.Limit {
        get { GitLogQuery.Limit(kind: defaults.string(forKey: LogKeys.limitKind) ?? "all",
                                count: defaults.object(forKey: LogKeys.limitCount) as? Int ?? 1) }
        set {
            defaults.set(newValue.kind, forKey: LogKeys.limitKind)
            defaults.set(newValue.count, forKey: LogKeys.limitCount)
        }
    }

    /// Message font; empty name = system font.
    var logFontName: String {
        get { defaults.string(forKey: LogKeys.fontName) ?? "" }
        set { defaults.set(newValue, forKey: LogKeys.fontName) }
    }

    var logFontSize: Double {
        get { defaults.object(forKey: LogKeys.fontSize) as? Double ?? 12 }
        set { defaults.set(newValue, forKey: LogKeys.fontSize) }
    }

    var logShortDateFormat: Bool {
        get { bool(LogKeys.shortDateFormat, true) }
        set { defaults.set(newValue, forKey: LogKeys.shortDateFormat) }
    }

    var logRelativeTimes: Bool {
        get { bool(LogKeys.relativeTimes, false) }
        set { defaults.set(newValue, forKey: LogKeys.relativeTimes) }
    }

    /// Format dates for the system locale; off = ISO 8601 style.
    var logUseSystemLocale: Bool {
        get { bool(LogKeys.useSystemLocale, true) }
        set { defaults.set(newValue, forKey: LogKeys.useSystemLocale) }
    }

    /// Double-click in the Log compares with the previous revision (otherwise it opens the commit).
    var logDoubleClickCompares: Bool {
        get { bool(LogKeys.doubleClickCompares, false) }
        set { defaults.set(newValue, forKey: LogKeys.doubleClickCompares) }
    }

    /// Show renames as `dir/{old => new}` in the changed-files list.
    var logAbbreviateRenamings: Bool {
        get { bool(LogKeys.abbreviateRenamings, false) }
        set { defaults.set(newValue, forKey: LogKeys.abbreviateRenamings) }
    }

    var logSymbolizeRefs: Bool {
        get { bool(LogKeys.symbolizeRefs, false) }
        set { defaults.set(newValue, forKey: LogKeys.symbolizeRefs) }
    }

    var logShowGravatar: Bool {
        get { bool(LogKeys.showGravatar, false) }
        set { defaults.set(newValue, forKey: LogKeys.showGravatar) }
    }

    /// `%HASH%` is replaced with the SHA-256 of the lower-cased email.
    var logGravatarURL: String {
        get { defaults.string(forKey: LogKeys.gravatarURL) ?? "https://gravatar.com/avatar/%HASH%?d=identicon" }
        set { defaults.set(newValue, forKey: LogKeys.gravatarURL) }
    }

    /// Draw ref labels right-aligned instead of before the subject.
    var logLabelsOnRight: Bool {
        get { bool(LogKeys.labelsOnRight, false) }
        set { defaults.set(newValue, forKey: LogKeys.labelsOnRight) }
    }

    /// Show subject and body on the log line.
    var logFullMessageOnLine: Bool {
        get { bool(LogKeys.fullMessageOnLine, false) }
        set { defaults.set(newValue, forKey: LogKeys.fullMessageOnLine) }
    }

    /// `git rev-list --count --first-parent` in the detail pane.
    var logShowBranchRevisionNumber: Bool {
        get { bool(LogKeys.showBranchRevisionNumber, false) }
        set { defaults.set(newValue, forKey: LogKeys.showBranchRevisionNumber) }
    }

    /// `git describe` in the detail pane and the Describe column.
    var logShowDescribe: Bool {
        get { bool(LogKeys.showDescribe, false) }
        set { defaults.set(newValue, forKey: LogKeys.showDescribe) }
    }

    /// Describe strategy: false = `--tags` (nearest tag before), true = `--contains` (first tag after).
    var logDescribeContains: Bool {
        get { bool(LogKeys.describeContains, false) }
        set { defaults.set(newValue, forKey: LogKeys.describeContains) }
    }

    var logDescribeAlwaysLong: Bool {
        get { bool(LogKeys.describeAlwaysLong, false) }
        set { defaults.set(newValue, forKey: LogKeys.describeAlwaysLong) }
    }

    var logDescribeFirstParent: Bool {
        get { bool(LogKeys.describeFirstParent, false) }
        set { defaults.set(newValue, forKey: LogKeys.describeFirstParent) }
    }

    /// The `git describe` arguments for the chosen strategy.
    func describeArguments(for revision: String) -> [String] {
        var args = ["describe"]
        if logDescribeContains {
            args.append("--contains")
        } else {
            args.append("--tags")
            if logDescribeAlwaysLong { args.append("--long") }
            if logDescribeFirstParent { args.append("--first-parent") }
        }
        args.append(revision)
        return args
    }

    // MARK: Dialogs 2 (log-related)

    /// Map names and emails through `.mailmap` in the Log and Statistics.
    var useMailmap: Bool {
        get { bool(LogKeys.useMailmap, true) }
        set { defaults.set(newValue, forKey: LogKeys.useMailmap) }
    }

    /// Offer FETCH_HEAD in the Log's ref chooser.
    var branchesIncludeFetchHead: Bool {
        get { bool(LogKeys.includeFetchHead, true) }
        set { defaults.set(newValue, forKey: LogKeys.includeFetchHead) }
    }

    /// List tags newest version first in the ref chooser.
    var sortTagsReversed: Bool {
        get { bool(LogKeys.sortTagsReversed, false) }
        set { defaults.set(newValue, forKey: LogKeys.sortTagsReversed) }
    }

    // MARK: Remembered Log state

    var logSearchFields: LogSearchFilter.Fields {
        get { (defaults.object(forKey: LogKeys.searchFields) as? Int).map(LogSearchFilter.Fields.init(rawValue:)) ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: LogKeys.searchFields) }
    }

    var logSearchRegex: Bool {
        get { bool(LogKeys.searchRegex, false) }
        set { defaults.set(newValue, forKey: LogKeys.searchRegex) }
    }

    var logSearchCaseSensitive: Bool {
        get { bool(LogKeys.searchCaseSensitive, false) }
        set { defaults.set(newValue, forKey: LogKeys.searchCaseSensitive) }
    }

    /// "All branches" state remembered per repository, as TortoiseGit does:
    /// "current", "all", "basic" or "local".
    func logScope(forRepository root: String) -> String {
        defaults.string(forKey: LogKeys.scopePrefix + root) ?? "current"
    }

    func setLogScope(_ scope: String, forRepository root: String) {
        defaults.set(scope, forKey: LogKeys.scopePrefix + root)
    }

    var logShowWorkingTreeChanges: Bool {
        get { bool(LogKeys.showWorkingTreeChanges, true) }
        set { defaults.set(newValue, forKey: LogKeys.showWorkingTreeChanges) }
    }

    var logShowUnversioned: Bool {
        get { bool(LogKeys.showUnversioned, false) }
        set { defaults.set(newValue, forKey: LogKeys.showUnversioned) }
    }

    var logShowRefLabels: Bool {
        get { bool(LogKeys.showRefLabels, true) }
        set { defaults.set(newValue, forKey: LogKeys.showRefLabels) }
    }

    /// With a path filter: hide (true) or grey (false) changed files outside the path.
    var logHideUnrelatedPaths: Bool {
        get { bool(LogKeys.hideUnrelatedPaths, false) }
        set { defaults.set(newValue, forKey: LogKeys.hideUnrelatedPaths) }
    }

    // MARK: Statistics

    var statsSortByCommitCount: Bool {
        get { bool(LogKeys.statsSortByCount, true) }
        set { defaults.set(newValue, forKey: LogKeys.statsSortByCount) }
    }

    var statsAuthorsCaseSensitive: Bool {
        get { bool(LogKeys.statsCaseSensitive, true) }
        set { defaults.set(newValue, forKey: LogKeys.statsCaseSensitive) }
    }

    var statsUseCommitterNames: Bool {
        get { bool(LogKeys.statsUseCommitter, false) }
        set { defaults.set(newValue, forKey: LogKeys.statsUseCommitter) }
    }

    var statsUseCommitDates: Bool {
        get { bool(LogKeys.statsUseCommitDates, false) }
        set { defaults.set(newValue, forKey: LogKeys.statsUseCommitDates) }
    }

    var statsAuthorsShown: Int {
        get { defaults.object(forKey: LogKeys.statsAuthorsShown) as? Int ?? 10 }
        set { defaults.set(newValue, forKey: LogKeys.statsAuthorsShown) }
    }
}
