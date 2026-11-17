import Cocoa

// Explicit entry point: the app has no main nib, so `@main`/NSApplicationMain would never attach the delegate.
MainActor.assumeIsolated {
    // Headless modes used by the installer (postinstall) and the uninstaller; they run as the console user.
    let arguments = CommandLine.arguments.dropFirst()
    if arguments.contains("--register-services") {
        let problems = ExtensionHelper.shared.registerServices()
        problems.forEach { FileHandle.standardError.write(Data("PangolinGit: \($0)\n".utf8)) }
        exit(problems.isEmpty ? 0 : 2)
    }
    if arguments.contains("--unregister-services") {
        ExtensionHelper.shared.unregisterServices()
        exit(0)
    }

    RepositoryEvents.installGitHook()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Background process: no Dock icon or menu bar until a dialog opens (see AppPresence).
    AppPresence.shared.start()
    app.run()
}
