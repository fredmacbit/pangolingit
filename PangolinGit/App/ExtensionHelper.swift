import Cocoa
import FinderSync
import PangolinGitCore

/// Registers and verifies the Finder Sync extension and its status agent, and points the user to
/// System Settings when something still needs their approval (Phase 12.7).
@MainActor
final class ExtensionHelper {
    static let shared = ExtensionHelper()

    static let extensionBundleIdentifier = "be.macbit.pangolingit.finder"
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    private init() {}

    var isFinderExtensionEnabled: Bool {
        FIFinderSyncController.isExtensionEnabled
    }

    private var extensionURL: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("PangolinGitFinder.appex")
    }

    // MARK: - Registration (used by the installer via `--register-services`, and on first run)

    /// Makes this copy of the app the one macOS uses: registers it with LaunchServices (URL scheme),
    /// registers and enables its Finder extension, and registers the status agent.
    /// Stale registrations of other copies (e.g. Xcode build folders) are removed so Finder does not
    /// load an outdated extension. Returns a human-readable list of problems, empty on success.
    @discardableResult
    func registerServices() -> [String] {
        var problems: [String] = []
        let appURL = Bundle.main.bundleURL.standardizedFileURL

        for other in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other.standardizedFileURL != appURL {
            Self.run(Self.lsregister, ["-u", other.path])
        }
        Self.run(Self.lsregister, ["-f", appURL.path])

        if let extensionURL {
            for path in registeredExtensionPaths() where path != extensionURL.standardizedFileURL.path {
                Self.run("/usr/bin/pluginkit", ["-r", path])
            }
            Self.run("/usr/bin/pluginkit", ["-a", extensionURL.path])
            if !Self.run("/usr/bin/pluginkit", ["-e", "use", "-i", Self.extensionBundleIdentifier]) {
                problems.append("The Finder extension could not be enabled; enable it in System Settings ▸ General ▸ Login Items & Extensions.")
            }
        } else {
            problems.append("The Finder extension is missing from the app bundle.")
        }

        if !AgentService.registerIfNeeded(force: true) {
            problems.append("The status agent needs approval: allow “PangolinGit” in System Settings ▸ General ▸ Login Items & Extensions.")
        }
        return problems
    }

    /// Reverses `registerServices()` for this copy; used by the uninstaller.
    func unregisterServices() {
        AgentService.unregister()
        if let extensionURL {
            Self.run("/usr/bin/pluginkit", ["-e", "ignore", "-i", Self.extensionBundleIdentifier])
            Self.run("/usr/bin/pluginkit", ["-r", extensionURL.path])
        }
        Self.run(Self.lsregister, ["-u", Bundle.main.bundleURL.path])
    }

    /// Paths of every copy of the extension PlugInKit knows about.
    private func registeredExtensionPaths() -> [String] {
        let output = Self.output("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", Self.extensionBundleIdentifier])
        // Lines look like: "+    be.macbit.pangolingit.finder(1.0.0)\t<uuid>\t<date>\t/path/PangolinGitFinder.appex"
        return output.split(separator: "\n").compactMap { line in
            guard let path = line.split(separator: "\t").last.map(String.init), path.hasSuffix(".appex") else { return nil }
            return URL(fileURLWithPath: path.trimmingCharacters(in: .whitespaces)).standardizedFileURL.path
        }
    }

    // MARK: - Startup check

    /// Checks extension and agent state on startup and offers to fix whichever is off.
    func promptIfNeeded() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        // Only the installed copy repairs the agent registration; a build launched from Xcode
        // must not point the agent at itself.
        let isInstalledCopy = Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
        let agentReady = isInstalledCopy ? AgentService.registerIfNeeded() : AgentService.isResponding()
        let extensionReady = isFinderExtensionEnabled
        guard !(agentReady && extensionReady) else { return }
        // "Don't ask again" (Settings ▸ Saved Data ▸ stored decisions brings the prompt back).
        guard StoredDecisions.shared.decision(for: StoredDecisions.Key.finderExtensionPrompt) == nil else { return }

        let alert = NSAlert()
        alert.messageText = "Finish setting up Finder integration"
        var steps: [String] = []
        if !extensionReady {
            steps.append("• Enable “PangolinGit” under Finder extensions (System Settings ▸ General ▸ Login Items & Extensions).")
        }
        if !agentReady {
            steps.append("• Allow “PangolinGit” to run in the background (System Settings ▸ General ▸ Login Items & Extensions).")
        }
        alert.informativeText = "Overlay badges and context menus need:\n\n" + steps.joined(separator: "\n")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            StoredDecisions.shared.store(response == .alertFirstButtonReturn ? 1 : 2, for: StoredDecisions.Key.finderExtensionPrompt)
        }
        if response == .alertFirstButtonReturn {
            if !extensionReady {
                FIFinderSyncController.showExtensionManagementInterface()
            } else {
                AgentService.openLoginItemsSettings()
            }
        }
    }

    // MARK: - Process helpers

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func output(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
