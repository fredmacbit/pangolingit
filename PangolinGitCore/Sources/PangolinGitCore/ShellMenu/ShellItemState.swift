import Foundation

/// What the Finder selection is, as a bit set: the `ITEMIS_*` flags of TortoiseGit's shell extension
/// (`src/TortoiseShell/Globals.h`). Computed by the agent (the sandboxed extension cannot read working
/// trees) and matched against each menu entry's rules (`ShellMenuRule`).
public struct ShellItemState: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Exactly one item is selected.
    public static let onlyOne = ShellItemState(rawValue: 1 << 0)
    /// Shift was held while the menu opened (TortoiseGit: `CMF_EXTENDEDVERBS`).
    public static let extended = ShellItemState(rawValue: 1 << 1)
    /// The first item is versioned (tracked, or a folder inside a working tree).
    public static let inGit = ShellItemState(rawValue: 1 << 2)
    public static let conflicted = ShellItemState(rawValue: 1 << 3)
    public static let folder = ShellItemState(rawValue: 1 << 4)
    /// The first item is a folder inside a working tree.
    public static let folderInGit = ShellItemState(rawValue: 1 << 5)
    /// The first item is unmodified.
    public static let normal = ShellItemState(rawValue: 1 << 6)
    public static let ignored = ShellItemState(rawValue: 1 << 7)
    /// The first item lies inside a working tree (versioned or not).
    public static let inVersionedFolder = ShellItemState(rawValue: 1 << 8)
    public static let added = ShellItemState(rawValue: 1 << 9)
    public static let deleted = ShellItemState(rawValue: 1 << 10)
    /// Some selected item is a `.patch` or `.diff` file.
    public static let patchFile = ShellItemState(rawValue: 1 << 12)
    /// Exactly two items are selected.
    public static let two = ShellItemState(rawValue: 1 << 17)
    /// The working tree has a `.gitmodules` file.
    public static let submoduleContainer = ShellItemState(rawValue: 1 << 18)
    /// `refs/stash` exists.
    public static let stash = ShellItemState(rawValue: 1 << 20)
    /// The first item is the top folder of a working tree.
    public static let wcRoot = ShellItemState(rawValue: 1 << 21)
    /// A bisect is in progress (`BISECT_START`).
    public static let bisect = ShellItemState(rawValue: 1 << 22)
    /// The first item is a bare repository folder.
    public static let bareRepo = ShellItemState(rawValue: 1 << 23)
    /// The first item is the root of a registered submodule.
    public static let submodule = ShellItemState(rawValue: 1 << 24)
    /// A merge is in progress (`MERGE_HEAD`).
    public static let mergeActive = ShellItemState(rawValue: 1 << 25)
    /// The folder has a `.git` entry that cannot be read.
    public static let inaccessible = ShellItemState(rawValue: 1 << 27)

    // PangolinGit additions (no TortoiseGit counterpart bit).

    /// A rebase is in progress (`rebase-merge` / `rebase-apply`).
    public static let rebaseActive = ShellItemState(rawValue: 1 << 28)
    /// A cherry-pick is in progress (`CHERRY_PICK_HEAD`).
    public static let cherryPickActive = ShellItemState(rawValue: 1 << 29)
    /// The repository uses Git LFS (`filter=lfs` in `.gitattributes`, or `.git/lfs` exists).
    public static let lfs = ShellItemState(rawValue: 1 << 30)

    /// Any of these means "something Git-related was clicked" (TortoiseGit's hide-unversioned test).
    public static let gitRelated: ShellItemState = [.inGit, .inVersionedFolder, .folderInGit, .bareRepo, .inaccessible]
}

/// One "show if" condition of a menu entry: every `yes` flag is set and every `no` flag is clear.
/// TortoiseGit's `YesNoPair` (`MenuInfo.h`) with the same quirk: a rule with neither set never matches.
public struct ShellMenuRule: Hashable, Sendable {
    public let yes: ShellItemState
    public let no: ShellItemState

    public init(_ yes: ShellItemState, _ no: ShellItemState = []) {
        self.yes = yes
        self.no = no
    }

    /// `CShellExt::ShouldEnableMenu`.
    public func matches(_ state: ShellItemState) -> Bool {
        if yes.isEmpty && no.isEmpty { return false }
        return state.isSuperset(of: yes) && state.isDisjoint(with: no)
    }
}

/// Computes `ShellItemState` for a Finder selection. Only the first item's status is examined,
/// like `CShellExt::Initialize`; the patch-file flag looks at every item.
public enum ShellItemStateEvaluator {

    public struct Result: Sendable, Equatable {
        public var state: ShellItemState
        /// Working-tree root (or bare repository folder) of the first item; empty outside a repository.
        public var root: String
        /// True when the first item lies inside a `.git` folder; TortoiseGit shows no menu there.
        public var isAdminDirectory: Bool

        public init(state: ShellItemState, root: String, isAdminDirectory: Bool = false) {
            self.state = state
            self.root = root
            self.isAdminDirectory = isAdminDirectory
        }
    }

    /// - Parameter status: the first item's status inside its working tree, or nil when unknown
    ///   (then the item is treated as versioned, as TortoiseGit does when its status call fails).
    public static func evaluate(
        paths rawPaths: [String],
        status: (PangolinPath, GitAdminDir.RepoLocations) -> GitItemStatus?
    ) -> Result {
        let paths = rawPaths.filter { !$0.isEmpty }
        var state: ShellItemState = []
        if paths.count == 1 { state.insert(.onlyOne) }
        if paths.count == 2 { state.insert(.two) }
        if paths.contains(where: isPatchFile) { state.insert(.patchFile) }
        guard let first = paths.first else { return Result(state: state, root: "") }

        let path = PangolinPath(first)
        let isDirectory = path.isDirectory
        if isDirectory { state.insert(.folder) }
        if isInsideAdminDirectory(path.rawPath) {
            return Result(state: state, root: "", isAdminDirectory: true)
        }

        guard let locations = GitAdminDir.findRepository(startingAt: path) else {
            if isDirectory && FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").rawPath) {
                state.insert(.inaccessible)
            }
            return Result(state: state, root: "")
        }
        let root = locations.workingTreeRoot
        if locations.isBare {
            // Only the bare repository folder itself counts; its objects/refs folders get no Git menu.
            if isDirectory && samePath(path, root) { state.insert(.bareRepo) }
            return Result(state: state, root: state.contains(.bareRepo) ? root.rawPath : "")
        }

        state.formUnion(repositoryFlags(locations))
        state.formUnion([.inGit, .inVersionedFolder])
        if isDirectory {
            state.insert(.folderInGit)
            if samePath(path, root) {
                state.insert(.wcRoot)
                if isRegisteredSubmodule(root) { state.insert(.submodule) }
            }
        }

        switch status(path, locations) {
        case .untracked?:
            state.remove(.inGit)
        case .ignored?:
            state.remove(.inGit)
            state.insert(.ignored)
        case .clean?:
            state.insert(.normal)
        case .conflicted?:
            state.insert(.conflicted)
        case .added?:
            state.insert(.added)
        case .deleted?, .missing?:
            state.insert(.deleted)
        default:
            break
        }
        return Result(state: state, root: root.rawPath)
    }

    /// Repository-wide flags: stash, bisect, merge/rebase/cherry-pick in progress, submodules, LFS
    /// (`CTGitPath::GetAdminDirMask`).
    public static func repositoryFlags(_ locations: GitAdminDir.RepoLocations) -> ShellItemState {
        let fm = FileManager.default
        let gitDir = locations.gitDirectory
        let commonDir = locations.commonDirectory
        let root = locations.workingTreeRoot
        var state: ShellItemState = []
        if hasStash(commonDir) { state.insert(.stash) }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("BISECT_START").rawPath) { state.insert(.bisect) }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("MERGE_HEAD").rawPath) { state.insert(.mergeActive) }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").rawPath)
            || fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").rawPath) {
            state.insert(.rebaseActive)
        }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("CHERRY_PICK_HEAD").rawPath) { state.insert(.cherryPickActive) }
        if fm.fileExists(atPath: root.appendingPathComponent(".gitmodules").rawPath) { state.insert(.submoduleContainer) }
        if usesLFS(root: root, commonDir: commonDir) { state.insert(.lfs) }
        return state
    }

    static func isPatchFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "patch" || ext == "diff"
    }

    static func isInsideAdminDirectory(_ path: String) -> Bool {
        path.split(separator: "/").contains(".git")
    }

    private static func samePath(_ a: PangolinPath, _ b: PangolinPath) -> Bool {
        a.url.standardizedFileURL.path == b.url.standardizedFileURL.path
    }

    /// `HasStashDir`: a loose `refs/stash` or an entry in `packed-refs`.
    static func hasStash(_ commonDir: PangolinPath) -> Bool {
        if FileManager.default.fileExists(atPath: commonDir.appendingPathComponent("refs/stash").rawPath) { return true }
        guard let packed = try? String(contentsOfFile: commonDir.appendingPathComponent("packed-refs").rawPath, encoding: .utf8) else {
            return false
        }
        return packed.split(separator: "\n").contains { $0.hasSuffix(" refs/stash") }
    }

    static func usesLFS(root: PangolinPath, commonDir: PangolinPath) -> Bool {
        if FileManager.default.fileExists(atPath: commonDir.appendingPathComponent("lfs").rawPath) { return true }
        guard let attributes = try? String(contentsOfFile: root.appendingPathComponent(".gitattributes").rawPath, encoding: .utf8) else {
            return false
        }
        return attributes.contains("filter=lfs")
    }

    /// `CTGitPath::IsRegisteredSubmoduleOfParentProject`: the parent working tree lists this folder in `.gitmodules`.
    static func isRegisteredSubmodule(_ root: PangolinPath) -> Bool {
        let parent = root.deletingLastPathComponent
        guard parent.rawPath != root.rawPath,
              let outer = GitAdminDir.findRepository(startingAt: parent), !outer.isBare,
              let relative = root.relative(to: outer.workingTreeRoot), !relative.isEmpty,
              let modules = try? String(contentsOfFile: outer.workingTreeRoot.appendingPathComponent(".gitmodules").rawPath, encoding: .utf8)
        else { return false }
        return modules.split(separator: "\n").contains { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == "path" && parts[1] == relative
        }
    }
}
