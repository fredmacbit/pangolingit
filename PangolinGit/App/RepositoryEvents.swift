import Foundation
import PangolinGitCore

/// In-app "repository changed" broadcast. Dialogs post it after an operation that changes commits,
/// refs, the index or ignore rules; open windows for the same repository reload and Finder badges
/// are refreshed (TortoiseGit's dialogs refresh their lists and TGitCache after an action the same way).
@MainActor
enum RepositoryEvents {
    private static let didChange = Notification.Name("be.macbit.pangolingit.repositoryDidChange")
    private static let rootKey = "root"

    /// Roots announced since the last flush; posts are coalesced so a burst of commands reloads once.
    private static var pendingRoots = Set<String>()

    /// Announces that the repository containing `path` changed.
    static func post(_ path: PangolinPath) {
        let root = GitAdminDir.findRepository(startingAt: path)?.workingTreeRoot ?? path
        let isFirst = pendingRoots.isEmpty
        pendingRoots.insert(root.rawPath)
        guard isFirst else { return }
        DispatchQueue.main.async { flush() }
    }

    private static func flush() {
        let roots = pendingRoots
        pendingRoots.removeAll()
        for root in roots {
            NotificationCenter.default.post(name: didChange, object: nil, userInfo: [rootKey: root])
            StatusAgentClient.invalidate(PangolinPath(root))
        }
    }

    /// Announces every state-changing git command the app runs, wherever it is run from
    /// (TortoiseGit refreshes its dialogs and the overlay cache after each command).
    static func installGitHook() {
        GitCLIRunner.mutationObserver = { workingDirectory, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { post(workingDirectory) }
            }
        }
    }

    /// Calls `handler` whenever the repository rooted at `repositoryRoot` changes. The observation
    /// lives as long as `owner`.
    static func observe(_ repositoryRoot: PangolinPath, owner: AnyObject, handler: @escaping @MainActor () -> Void) {
        let token = NotificationCenter.default.addObserver(forName: didChange, object: nil, queue: .main) { notification in
            guard notification.userInfo?[rootKey] as? String == repositoryRoot.rawPath else { return }
            MainActor.assumeIsolated { handler() }
        }
        objc_setAssociatedObject(owner, Unmanaged.passUnretained(token as AnyObject).toOpaque(),
                                 ObserverToken(token), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Removes the observer when the owning window controller is released.
    private final class ObserverToken {
        let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        deinit { NotificationCenter.default.removeObserver(token) }
    }
}
