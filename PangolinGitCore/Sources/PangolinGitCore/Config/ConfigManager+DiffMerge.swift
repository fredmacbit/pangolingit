import Foundation

/// Settings for the diff viewer, the merge editor and external tools — TortoiseGit's
/// *Diff Viewer* / *Merge Tool* pages and TortoiseGitMerge's own settings (`SetMainPage.cpp`,
/// `SetColorPage.cpp`) and TortoiseGitUDiff's colour page.
extension ConfigManager {

    public enum DiffKeys {
        public static let useExternalDiffTool = "diff.useExternalTool"
        public static let useExternalMergeTool = "merge.useExternalTool"
        public static let diffToolOverrides = "diff.toolOverrides"
        public static let mergeToolOverrides = "merge.toolOverrides"
        public static let mergeToolBlockTrust = "merge.blockTrust"
        public static let unifiedDiffViewer = "diff.unifiedViewer"
        public static let alternativeEditor = "alternativeEditor"
        public static let inlineDiffMode = "diff.inlineMode"
        public static let maxInlineLength = "diff.maxInlineLength"
        public static let collapseUnchanged = "diff.collapseUnchanged"
        public static let wrapLines = "diff.wrapLines"
        public static let whitespaceMode = "diff.whitespace"
        public static let ignoreLineEndings = "diff.ignoreEOL"
        public static let ignoreBlankLines = "diff.ignoreBlankLines"
        public static let fontName = "diff.fontName"
        public static let fontSize = "diff.fontSize"
        public static let tabWidth = "diff.tabWidth"
        public static let headerColorHex = "diff.headerColorHex"
        public static let positionColorHex = "diff.positionColorHex"
        public static let mergeBackup = "merge.backup"
        public static let mergeShowBase = "merge.showBase"
        public static let mergeUseGitResult = "merge.useGitResult"
    }

    /// TortoiseGit's `MergeBlockTrustBehavior`: whether to wait for an external merge tool, and
    /// whether its exit code decides that the conflict is resolved.
    public enum MergeBlockTrust: Int, CaseIterable, Sendable {
        case dontWait = 0
        case waitAndAsk = 1
        case waitAndTrustExitCode = 2

        public var title: String {
            switch self {
            case .dontWait: return "Don't wait for the tool"
            case .waitAndAsk: return "Block while running, then ask"
            case .waitAndTrustExitCode: return "Block while running and trust the exit code"
            }
        }
    }

    // MARK: External tools

    /// Use the external diff tool instead of the built-in viewer (⌥ inverts, like TortoiseGit's Shift).
    public var useExternalDiffTool: Bool {
        get { defaults.object(forKey: DiffKeys.useExternalDiffTool) as? Bool ?? false }
        set { defaults.set(newValue, forKey: DiffKeys.useExternalDiffTool) }
    }

    public var useExternalMergeTool: Bool {
        get { defaults.object(forKey: DiffKeys.useExternalMergeTool) as? Bool ?? false }
        set { defaults.set(newValue, forKey: DiffKeys.useExternalMergeTool) }
    }

    /// Per-extension or per-file-name diff command lines (`.png` → `…`).
    public var diffToolOverrides: [String: String] {
        get { defaults.dictionary(forKey: DiffKeys.diffToolOverrides) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: DiffKeys.diffToolOverrides) }
    }

    public var mergeToolOverrides: [String: String] {
        get { defaults.dictionary(forKey: DiffKeys.mergeToolOverrides) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: DiffKeys.mergeToolOverrides) }
    }

    public var mergeToolBlockTrust: MergeBlockTrust {
        get { MergeBlockTrust(rawValue: defaults.integer(forKey: DiffKeys.mergeToolBlockTrust)) ?? .dontWait }
        set { defaults.set(newValue.rawValue, forKey: DiffKeys.mergeToolBlockTrust) }
    }

    /// Application or command for unified diffs and `.patch` files; empty uses the built-in viewer.
    public var unifiedDiffViewer: String {
        get { defaults.string(forKey: DiffKeys.unifiedDiffViewer) ?? "" }
        set { defaults.set(newValue, forKey: DiffKeys.unifiedDiffViewer) }
    }

    /// TortoiseGit's *Alternative editor* (Open with alternative editor in file lists).
    public var alternativeEditor: String {
        get { defaults.string(forKey: DiffKeys.alternativeEditor) ?? "" }
        set { defaults.set(newValue, forKey: DiffKeys.alternativeEditor) }
    }

    // MARK: Built-in diff viewer

    public var inlineDiffMode: InlineDiffMode {
        get { InlineDiffMode(rawValue: defaults.string(forKey: DiffKeys.inlineDiffMode) ?? "") ?? .character }
        set { defaults.set(newValue.rawValue, forKey: DiffKeys.inlineDiffMode) }
    }

    public var maxInlineLength: Int {
        get { defaults.object(forKey: DiffKeys.maxInlineLength) as? Int ?? SideBySideDiffBuilder.defaultMaxInlineLength }
        set { defaults.set(newValue, forKey: DiffKeys.maxInlineLength) }
    }

    public var diffCollapseUnchanged: Bool {
        get { defaults.object(forKey: DiffKeys.collapseUnchanged) as? Bool ?? false }
        set { defaults.set(newValue, forKey: DiffKeys.collapseUnchanged) }
    }

    public var diffWrapLines: Bool {
        get { defaults.object(forKey: DiffKeys.wrapLines) as? Bool ?? false }
        set { defaults.set(newValue, forKey: DiffKeys.wrapLines) }
    }

    /// Remembered whitespace/EOL options, applied to every new diff window.
    public var diffOptions: GitDiffOptions {
        get {
            GitDiffOptions(whitespace: GitDiffOptions.Whitespace(rawValue: defaults.string(forKey: DiffKeys.whitespaceMode) ?? "") ?? .compare,
                           ignoreBlankLines: defaults.bool(forKey: DiffKeys.ignoreBlankLines),
                           ignoreLineEndings: defaults.bool(forKey: DiffKeys.ignoreLineEndings))
        }
        set {
            defaults.set(newValue.whitespace.rawValue, forKey: DiffKeys.whitespaceMode)
            defaults.set(newValue.ignoreBlankLines, forKey: DiffKeys.ignoreBlankLines)
            defaults.set(newValue.ignoreLineEndings, forKey: DiffKeys.ignoreLineEndings)
        }
    }

    /// Empty means the system monospaced font.
    public var diffFontName: String {
        get { defaults.string(forKey: DiffKeys.fontName) ?? "" }
        set { defaults.set(newValue, forKey: DiffKeys.fontName) }
    }

    public var diffFontSize: Double {
        get { defaults.object(forKey: DiffKeys.fontSize) as? Double ?? 12 }
        set { defaults.set(newValue, forKey: DiffKeys.fontSize) }
    }

    public var diffTabWidth: Int {
        get { defaults.object(forKey: DiffKeys.tabWidth) as? Int ?? 4 }
        set { defaults.set(newValue, forKey: DiffKeys.tabWidth) }
    }

    /// Unified-diff colours for file headers (`diff`, `index`, `---`, `+++`) and hunk positions (`@@`).
    public var diffHeaderColorHex: String {
        get { defaults.string(forKey: DiffKeys.headerColorHex) ?? "#6F42C1" }
        set { defaults.set(newValue, forKey: DiffKeys.headerColorHex) }
    }

    public var diffPositionColorHex: String {
        get { defaults.string(forKey: DiffKeys.positionColorHex) ?? "#0366D6" }
        set { defaults.set(newValue, forKey: DiffKeys.positionColorHex) }
    }

    // MARK: Merge editor

    /// Keep `<file>.orig` with the conflicted content when saving (TortoiseMerge's *Backup original file*).
    public var mergeBackupOriginal: Bool {
        get { defaults.object(forKey: DiffKeys.mergeBackup) as? Bool ?? false }
        set { defaults.set(newValue, forKey: DiffKeys.mergeBackup) }
    }

    public var mergeShowBasePane: Bool {
        get { defaults.object(forKey: DiffKeys.mergeShowBase) as? Bool ?? false }
        set { defaults.set(newValue, forKey: DiffKeys.mergeShowBase) }
    }

    /// Start from `git merge-file --diff3` (git's own conflict hunks) rather than PangolinGit's engine.
    public var mergeUseGitResult: Bool {
        get { defaults.object(forKey: DiffKeys.mergeUseGitResult) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DiffKeys.mergeUseGitResult) }
    }
}
