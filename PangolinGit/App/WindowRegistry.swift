import Cocoa
import PangolinGitCore

/// Keeps dialog window controllers alive while their windows are open and remembers which
/// repository each window belongs to (TortoiseGitProc runs one process per dialog; here one app hosts them all).
@MainActor
final class WindowRegistry: NSObject {
    static let shared = WindowRegistry()
    
    private struct Record {
        let controller: NSWindowController
        let key: String?
        let repository: PangolinPath?
    }
    
    private var records: [ObjectIdentifier: Record] = [:]
    
    /// Shows `controller`, or brings forward an existing window registered under the same `key`.
    func present(_ makeController: () -> NSWindowController, key: String? = nil, repository: PangolinPath? = nil) {
        if let key, let existing = records.values.first(where: { $0.key == key }) {
            AppPresence.shared.becomeVisible()
            existing.controller.showWindow(nil)
            existing.controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = makeController()
        guard let window = controller.window else { return }
        records[ObjectIdentifier(window)] = Record(controller: controller, key: key, repository: repository)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
        if repository != nil, window.representedURL == nil {
            window.representedURL = repository?.url
        }
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Remember each dialog's size and position (TortoiseGit's EnableSaveRestore), per dialog type;
        // Settings ▸ Saved Data clears them. A second window of the same type keeps the default frame.
        var restored = false
        if window.frameAutosaveName.isEmpty, window.styleMask.contains(.resizable) {
            let name = "PangolinGit.\(String(describing: type(of: controller)))"
            let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") != nil
            restored = window.setFrameAutosaveName(name) && hasSavedFrame
        }
        if !window.isVisible && !restored { window.center() }
        AppPresence.shared.becomeVisible()
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    /// Repository of the frontmost dialog, used by the Repository menu.
    var currentRepository: PangolinPath? {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let repo = records[ObjectIdentifier(window)]?.repository {
                return repo
            }
        }
        return nil
    }
    
    var hasOpenWindows: Bool { !records.isEmpty }
    
    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        // Defer release so AppKit finishes closing before the controller goes away.
        let id = ObjectIdentifier(window)
        DispatchQueue.main.async { self.records.removeValue(forKey: id) }
    }
}
