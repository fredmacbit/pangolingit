import Foundation
import ServiceManagement
import Security
import PangolinGitCore

/// Registers the bundled `PangolinGitAgent` status-cache launch agent with launchd.
/// The Finder extension can only obtain badges while this agent is registered.
///
/// Signed builds (with a Team ID) use `SMAppService`. Ad-hoc signed builds use a classic per-user
/// LaunchAgent in `~/Library/LaunchAgents` instead: for an executable without a Team ID, Background
/// Task Management pins the checksum it saw at registration in a launch constraint, so after a
/// reinstall launchd refuses to start the new binary ("Launch Constraint Violation").
enum AgentService {
    static let label = "be.macbit.pangolingit.agent"

    private static var service: SMAppService {
        SMAppService.agent(plistName: StatusCacheInterface.launchAgentPlistName)
    }

    private static var legacyPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var agentExecutablePath: String? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("PangolinGitAgent").path
    }

    static var status: SMAppService.Status { service.status }

    /// True when either registration mechanism is active.
    static var isRegistered: Bool {
        service.status == .enabled || FileManager.default.fileExists(atPath: legacyPlistURL.path)
    }

    /// Registers the agent if needed. Returns false when it could not be registered, or when the user
    /// still has to allow it under Login Items.
    /// - Parameter force: re-register even when the agent answers, so the registration points at this
    ///   copy of the app (the installer passes true: a reinstall can move or replace the binary).
    @discardableResult
    static func registerIfNeeded(force: Bool = false) -> Bool {
        if !hasTeamIdentifier {
            // Drop an SMAppService registration from an earlier version; its launch constraint
            // would keep the agent from starting.
            if service.status == .enabled || service.status == .requiresApproval {
                try? service.unregister()
            }
            if !force && isLegacyAgentCurrent && isResponding() {
                return true
            }
            return installLegacyAgent()
        }
        switch service.status {
        case .enabled:
            removeLegacyAgent()
            if !force && isLoadedInLaunchd && isResponding() {
                return true
            }
            // Enabled but not loaded (e.g. unloaded with `launchctl bootout`), or loaded but launchd
            // cannot start it (the registration points at an app copy that was moved or deleted):
            // register again from this copy.
            PangolinLog.general.notice("Status agent registered but not answering (or forced); re-registering.")
            try? service.unregister()
        case .requiresApproval:
            return false
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
        if isLegacyAgentCurrent {
            return true
        }
        do {
            try service.register()
            PangolinLog.general.info("Registered status agent with SMAppService.")
            if service.status == .enabled {
                removeLegacyAgent()
                return true
            }
            return false
        } catch {
            PangolinLog.general.error("SMAppService registration failed (\(error.localizedDescription, privacy: .public)); using a LaunchAgent plist.")
            return installLegacyAgent()
        }
    }

    static func unregister() {
        try? service.unregister()
        removeLegacyAgent()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether this app is signed with a Team ID (Developer ID or App Store), as opposed to ad-hoc.
    private static var hasTeamIdentifier: Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return false }
        return (dictionary[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
    }

    /// Whether the agent answers a ping over its Mach service within `timeout` seconds. launchd starts
    /// it on demand, so this also proves the registered program can actually be launched.
    static func isResponding(timeout: TimeInterval = 3) -> Bool {
        final class Box: @unchecked Sendable { var answered = false }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let connection = NSXPCConnection(machServiceName: StatusCacheInterface.machServiceName, options: [])
        connection.remoteObjectInterface = StatusCacheInterface.makeInterface()
        connection.resume()
        defer { connection.invalidate() }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in semaphore.signal() } as? PangolinGitStatusCacheProtocol
        proxy?.ping { _ in
            box.answered = true
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return box.answered
    }

    /// Whether launchd currently knows the agent job in this user's GUI domain.
    private static var isLoadedInLaunchd: Bool {
        launchctl(["print", "gui/\(getuid())/\(label)"])
    }
    
    // MARK: - Legacy LaunchAgent fallback

    /// The legacy plist exists and points at this copy of the app.
    private static var isLegacyAgentCurrent: Bool {
        guard let data = try? Data(contentsOf: legacyPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let program = plist["Program"] as? String else { return false }
        return program == agentExecutablePath
    }

    private static func installLegacyAgent() -> Bool {
        guard let program = agentExecutablePath, FileManager.default.isExecutableFile(atPath: program) else {
            return false
        }
        let plist: [String: Any] = [
            "Label": label,
            "Program": program,
            "MachServices": [StatusCacheInterface.machServiceName: true],
            "ProcessType": "Adaptive",
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "be.macbit.pangolingit"]
        ]
        do {
            try FileManager.default.createDirectory(at: legacyPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: legacyPlistURL, options: .atomic)
        } catch {
            PangolinLog.general.error("Writing LaunchAgent plist failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        // An SMAppService job with the same label may still be shutting down; retry once.
        for attempt in 0..<2 {
            launchctl(["bootout", "gui/\(getuid())/\(label)"])
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }
            if launchctl(["bootstrap", "gui/\(getuid())", legacyPlistURL.path]) {
                return isResponding()
            }
        }
        PangolinLog.general.error("launchctl bootstrap of the status agent failed.")
        return false
    }

    private static func removeLegacyAgent() {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else { return }
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: legacyPlistURL)
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
