import Foundation
import PangolinGitCore

/// The app's connection to `PangolinGitAgent`, used to refresh Finder badges right after an in-app
/// action instead of waiting for FSEvents (TortoiseGit's dialogs notify TGitCache the same way).
@MainActor
enum StatusAgentClient {
    private static var connection: NSXPCConnection?

    /// Marks the repository containing `path` stale; the agent re-reads it and tells Finder to re-badge.
    static func invalidate(_ path: PangolinPath) {
        proxy()?.invalidateCache(forPath: path.rawPath) { _ in }
    }

    private static func proxy() -> PangolinGitStatusCacheProtocol? {
        if connection == nil {
            let newConnection = NSXPCConnection(machServiceName: StatusCacheInterface.machServiceName, options: [])
            newConnection.remoteObjectInterface = StatusCacheInterface.makeInterface()
            newConnection.invalidationHandler = {
                DispatchQueue.main.async { StatusAgentClient.connection = nil }
            }
            newConnection.resume()
            connection = newConnection
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            PangolinLog.general.error("Status agent unavailable: \(error.localizedDescription, privacy: .public)")
        } as? PangolinGitStatusCacheProtocol
    }
}
