import Foundation

/// A submodule as listed by `git submodule status` plus its `.gitmodules` entry
/// (TortoiseGit's submodule dialogs read the same two sources).
public struct GitSubmoduleInfo: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case upToDate, uninitialized, modifiedCommit, conflict
    }

    public let name: String
    public let path: String
    public let commit: String
    public let url: String
    public let branch: String
    public let state: State

    public init(name: String, path: String, commit: String, url: String, branch: String = "", state: State) {
        self.name = name
        self.path = path
        self.commit = commit
        self.url = url
        self.branch = branch
        self.state = state
    }

    /// Parses `git submodule status` together with
    /// `git config -f .gitmodules --get-regexp '^submodule\..*\.(url|path|branch)$'`.
    public static func parse(status: String, gitmodules: String) -> [GitSubmoduleInfo] {
        var valuesByName: [String: [String: String]] = [:]
        var nameByPath: [String: String] = [:]
        for line in gitmodules.components(separatedBy: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space])
            let value = String(line[line.index(after: space)...])
            guard key.hasPrefix("submodule."), let dot = key.lastIndex(of: ".") else { continue }
            let name = String(key[key.index(key.startIndex, offsetBy: "submodule.".count)..<dot])
            let field = String(key[key.index(after: dot)...])
            valuesByName[name, default: [:]][field] = value
            if field == "path" { nameByPath[value] = name }
        }

        var items: [GitSubmoduleInfo] = []
        for line in status.components(separatedBy: "\n") where !line.isEmpty {
            // <flag><sha> <path>[ (<describe>)]; the path may contain spaces.
            let flag = line.first ?? " "
            let body = line.dropFirst()
            guard let space = body.firstIndex(of: " ") else { continue }
            let commit = String(body[..<space])
            var path = String(body[body.index(after: space)...])
            if path.hasSuffix(")"), let paren = path.range(of: " (", options: .backwards) {
                path = String(path[..<paren.lowerBound])
            }
            guard !path.isEmpty else { continue }
            let name = nameByPath[path] ?? path
            let state: State
            switch flag {
            case "-": state = .uninitialized
            case "+": state = .modifiedCommit
            case "U": state = .conflict
            default: state = .upToDate
            }
            let values = valuesByName[name] ?? [:]
            items.append(GitSubmoduleInfo(name: name, path: path, commit: commit, url: values["url"] ?? "",
                                          branch: values["branch"] ?? "", state: state))
        }
        return items
    }

    /// Submodules at or below `folder` (repository-relative; empty = all), for TortoiseGit's
    /// "update the submodules under the clicked folder".
    public static func filter(_ items: [GitSubmoduleInfo], under folders: [String]) -> [GitSubmoduleInfo] {
        let folders = folders.filter { !$0.isEmpty }
        guard !folders.isEmpty else { return items }
        return items.filter { item in
            folders.contains { folder in item.path == folder || item.path.hasPrefix(folder + "/") || folder.hasPrefix(item.path + "/") }
        }
    }

    /// Arguments of `git submodule update` for the Update dialog's options.
    public struct UpdateOptions: Equatable, Sendable {
        public enum Mode: Int, Sendable { case checkout, merge, rebase }
        public var initialize = true
        public var recursive = true
        public var force = false
        public var noFetch = false
        public var remote = false
        public var mode: Mode = .checkout

        public init() {}

        public func arguments(paths: [String]) -> [String] {
            var args = ["submodule", "update"]
            if initialize { args.append("--init") }
            if recursive { args.append("--recursive") }
            if force { args.append("--force") }
            if noFetch { args.append("--no-fetch") }
            if remote { args.append("--remote") }
            switch mode {
            case .checkout: break
            case .merge: args.append("--merge")
            case .rebase: args.append("--rebase")
            }
            args.append("--")
            return args + paths
        }
    }
}

/// How a submodule pointer changed between two commits (TortoiseGit's `SubmoduleDiffDlg` labels).
public enum GitSubmoduleChange: String, Equatable, Sendable {
    case newSubmodule = "New submodule"
    case deleted = "Deleted"
    case unchanged = "Unchanged"
    case fastForward = "Fast-forward"
    case rewind = "Rewind"
    case newerTime = "Newer (diverged)"
    case olderTime = "Older (diverged)"
    case sameTime = "Same time (diverged)"

    /// - Parameters:
    ///   - fromIsAncestor: `from` is an ancestor of `to` (`merge-base --is-ancestor from to`).
    ///   - toIsAncestor: `to` is an ancestor of `from`.
    public static func classify(from: String?, to: String?, fromIsAncestor: Bool, toIsAncestor: Bool,
                                fromTime: TimeInterval, toTime: TimeInterval) -> GitSubmoduleChange {
        guard let from, !from.isEmpty else { return .newSubmodule }
        guard let to, !to.isEmpty else { return .deleted }
        if from == to { return .unchanged }
        if fromIsAncestor { return .fastForward }
        if toIsAncestor { return .rewind }
        if toTime > fromTime { return .newerTime }
        if toTime < fromTime { return .olderTime }
        return .sameTime
    }
}
