import Cocoa

/// PangolinGit runs as a background process, like TortoiseGitProc on Windows: Finder starts it on
/// demand through `pangolingit://` URLs, and it shows nothing of its own (`LSUIElement`).
/// While at least one dialog is open it becomes a regular app, so the dialogs get a Dock icon,
/// ⌘-Tab and the menu bar (Edit ▸ Copy/Paste, Window). When the last one closes it goes back to the
/// background and stays resident, so the next context-menu command opens instantly.
@MainActor
final class AppPresence: NSObject {
    static let shared = AppPresence()

    private override init() {}

    func start() {
        NSApp.setActivationPolicy(.accessory)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowDidAppear(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    /// Called just before a dialog is shown, so it opens with the Dock icon and menu bar in place.
    func becomeVisible() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Covers windows that do not go through `WindowRegistry` (alerts, About, open panels).
    @objc private func windowDidAppear(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, Self.isDialog(window) else { return }
        becomeVisible()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        // The closing window is still visible during willClose; check once AppKit has finished.
        DispatchQueue.main.async {
            let remaining = NSApp.windows.filter { $0 !== closing && $0.isVisible && Self.isDialog($0) }
            if remaining.isEmpty, NSApp.modalWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Titled, user-facing windows; ignores the menu bar's and the status bar's own windows.
    private static func isDialog(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) || window is NSPanel || window.isModalPanel
    }
}
