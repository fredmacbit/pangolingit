import Foundation

/// Status cache protocol exported by the `PangolinGitAgent` launch agent to the Finder Sync extension.
/// Equivalent to TortoiseGit's `CacheInterface.h` (`src/TGitCache/CacheInterface.h`).
///
/// The agent runs outside the sandbox (it must read arbitrary working trees and run git), and is
/// reached through a launchd Mach service whose name is prefixed with the App Group identifier —
/// the only kind of Mach service a sandboxed Finder extension is allowed to look up.
@objc(PangolinGitStatusCacheProtocol)
public protocol PangolinGitStatusCacheProtocol {

    /// Returns the badge (`GitBadgeKind` raw value), status (`GitItemStatus` raw value) and the
    /// enclosing working-tree root for a path. All three are empty strings outside a repository.
    func queryStatus(forPath path: String, withReply reply: @escaping (String, String, String) -> Void)

    /// Marks the cached status of the repository containing `path` as stale.
    func invalidateCache(forPath path: String, withReply reply: @escaping (Bool) -> Void)

    /// Context-menu visibility (`ConfigManager.contextMenuEntries`). Relayed by the agent because the
    /// sandboxed extension cannot read the app's preferences unless the App Group is provisioned.
    func contextMenuConfiguration(withReply reply: @escaping ([String: Bool]) -> Void)
    
    /// Liveness check; replies with the agent version.
    func ping(withReply reply: @escaping (String) -> Void)

    /// What a Finder selection is, for the state-dependent context menu (TortoiseGit evaluates this in
    /// `CShellExt::Initialize`). Replies with the `ShellItemState` raw value (without `.extended`, which
    /// only the extension can see), the working-tree root of the first item (empty outside a
    /// repository) and whether the first item lies inside a `.git` folder.
    func menuState(forPaths paths: [String], withReply reply: @escaping (UInt32, String, Bool) -> Void)

    /// The extension's preferences as JSON-encoded `FinderSettings` (context-menu layout, exclusions,
    /// watched folders, icon toggle).
    func finderSettings(withReply reply: @escaping (Data) -> Void)
}

/// Callback interface the Finder extension exports back to the agent.
@objc(PangolinGitStatusCacheClientProtocol)
public protocol PangolinGitStatusCacheClientProtocol {
    /// Sent when the status of a working tree changed and visible badges should be re-queried.
    func repositoryStatusDidChange(atRoot root: String)
}

public enum StatusCacheInterface {
    public static let appGroupIdentifier = "group.be.macbit.pangolingit"
    /// Allowed for the sandboxed extension via its `temporary-exception.mach-lookup.global-name` entitlement.
    public static let machServiceName = "group.be.macbit.pangolingit.agent"
    /// Launchd plist shipped in `PangolinGit.app/Contents/Library/LaunchAgents`.
    public static let launchAgentPlistName = "be.macbit.pangolingit.agent.plist"
    public static let agentVersion = "PangolinGitAgent-1.0"

    public static func makeInterface() -> NSXPCInterface {
        return NSXPCInterface(with: PangolinGitStatusCacheProtocol.self)
    }

    public static func makeClientInterface() -> NSXPCInterface {
        return NSXPCInterface(with: PangolinGitStatusCacheClientProtocol.self)
    }
}
