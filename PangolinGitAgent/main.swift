import Foundation
import PangolinGitCore

/// Launch agent hosting the status cache, started on demand by launchd when the Finder extension
/// connects to its Mach service. Equivalent to TortoiseGit's `TGitCache.exe` (`src/TGitCache/TGITCache.cpp`).
final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [NSXPCConnection] = []
    
    override init() {
        super.init()
        StatusCache.shared.onRepositoryChanged = { [weak self] root in
            self?.broadcastChange(root: root)
        }
    }
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = StatusCacheInterface.makeInterface()
        newConnection.exportedObject = StatusCacheService()
        newConnection.remoteObjectInterface = StatusCacheInterface.makeClientInterface()
        
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.lock.lock()
            self.clients.removeAll { $0 === newConnection }
            self.lock.unlock()
        }
        lock.lock()
        clients.append(newConnection)
        lock.unlock()
        
        newConnection.resume()
        return true
    }
    
    private func broadcastChange(root: String) {
        lock.lock()
        let current = clients
        lock.unlock()
        for connection in current {
            (connection.remoteObjectProxy as? PangolinGitStatusCacheClientProtocol)?.repositoryStatusDidChange(atRoot: root)
        }
    }
}

final class StatusCacheService: NSObject, PangolinGitStatusCacheProtocol {
    func queryStatus(forPath path: String, withReply reply: @escaping (String, String, String) -> Void) {
        nonisolated(unsafe) let reply = reply
        StatusCache.shared.queryStatus(forPath: path) { badge, status, root in
            reply(badge.rawValue, status.rawValue, root)
        }
    }
    
    func invalidateCache(forPath path: String, withReply reply: @escaping (Bool) -> Void) {
        StatusCache.shared.invalidate(path: path)
        reply(true)
    }
    
    func contextMenuConfiguration(withReply reply: @escaping ([String: Bool]) -> Void) {
        reply(ConfigManager.shared.contextMenuEntries)
    }
    
    func ping(withReply reply: @escaping (String) -> Void) {
        reply(StatusCacheInterface.agentVersion)
    }

    func menuState(forPaths paths: [String], withReply reply: @escaping (UInt32, String, Bool) -> Void) {
        nonisolated(unsafe) let reply = reply
        DispatchQueue.global(qos: .userInteractive).async {
            let result = ShellItemStateEvaluator.evaluate(paths: paths) { path, _ in
                StatusCache.shared.itemStatus(forPath: path.rawPath)
            }
            reply(result.state.rawValue, result.root, result.isAdminDirectory)
        }
    }

    func finderSettings(withReply reply: @escaping (Data) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        reply(ConfigManager.shared.finderSettings(defaultRoots: [home, "/Volumes"]).encoded())
    }
}

let delegate = AgentListenerDelegate()
let listener = NSXPCListener(machServiceName: StatusCacheInterface.machServiceName)
listener.delegate = delegate
listener.resume()
PangolinLog.xpc.info("PangolinGitAgent listening on \(StatusCacheInterface.machServiceName, privacy: .public)")
RunLoop.main.run()
