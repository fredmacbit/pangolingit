import Cocoa
import PangolinGitCore
import SystemConfiguration

/// Serves the repository read-only over `git://` with `git daemon` (TortoiseGit's `DaemonCommand.cpp`):
/// a security warning first, then a window listing the clone URLs of this Mac and git's output,
/// with a Stop button that ends the daemon.
@MainActor
final class DaemonWindowController: NSWindowController, NSWindowDelegate {

    private let repository: PangolinPath
    private let port: Int
    private let urlsLabel = NSTextField(wrappingLabelWithString: "")
    private let outputView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private var task: Task<Void, Never>?

    /// Shows the security warning and starts serving `repository`.
    static func start(repository: PangolinPath) {
        guard confirmSecurityWarning() else { return }
        WindowRegistry.shared.present({ DaemonWindowController(repository: repository) },
                                      key: "daemon|\(repository.rawPath)", repository: repository)
    }

    /// TortoiseGit's `IDS_DAEMON_SECURITY_WARN`, with "Don't show again" (`DaemonNoSecurityWarning`).
    /// Only a "Proceed" answer is remembered.
    static func confirmSecurityWarning() -> Bool {
        let key = StoredDecisions.Key.daemonSecurityWarning
        if StoredDecisions.shared.decision(for: key) == 1 { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Start Git daemon?"
        alert.informativeText = "The daemon serves this repository without authentication to everybody who can reach "
            + "this Mac on the network (git://, port \(ConfigManager.shared.advancedInt(.daemonPort))). "
            + "Anyone can clone it while the daemon runs. macOS may ask whether git may accept incoming connections."
        alert.addButton(withTitle: "Proceed")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this warning again"
        let proceed = alert.runModal() == .alertFirstButtonReturn
        if proceed, alert.suppressionButton?.state == .on {
            StoredDecisions.shared.store(1, for: key)
        }
        return proceed
    }

    init(repository: PangolinPath) {
        self.repository = repository
        self.port = ConfigManager.shared.advancedInt(.daemonPort)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Git Daemon — \(repository.filename)"
        window.minSize = NSSize(width: 460, height: 280)
        super.init(window: window)
        window.delegate = self
        setupUI()
        startDaemon()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: "Others can clone this repository with:")
        heading.font = .boldSystemFont(ofSize: 13)
        urlsLabel.isSelectable = true
        urlsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlsLabel.stringValue = Self.cloneURLs(port: port).joined(separator: "\n")

        let copyButton = NSButton(title: "Copy URL", target: self, action: #selector(copyURL))
        copyButton.bezelStyle = .rounded
        copyButton.toolTip = "Copy the first clone URL to the clipboard"

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = outputView
        outputView.isEditable = false
        outputView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputView.autoresizingMask = [.width]
        outputView.isVerticallyResizable = true
        outputView.textContainer?.widthTracksTextView = true

        statusLabel.textColor = .secondaryLabelColor
        stopButton.target = self
        stopButton.action = #selector(stopOrClose)
        stopButton.bezelStyle = .rounded
        stopButton.keyEquivalent = "\u{1b}"

        for view in [heading, urlsLabel, copyButton, scroll, statusLabel, stopButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            urlsLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            urlsLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            urlsLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),
            copyButton.topAnchor.constraint(equalTo: urlsLabel.topAnchor, constant: -4),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: urlsLabel.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: stopButton.topAnchor, constant: -12),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: stopButton.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stopButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            stopButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }

    private func startDaemon() {
        let arguments = ["daemon", "--verbose", "--export-all", "--reuseaddr",
                         "--base-path=\(repository.rawPath)", "--port=\(port)"]
        append(GitCLIRunner.commandLine(arguments) + "\n")
        statusLabel.stringValue = "Serving… (Stop ends the daemon)"
        task = Task { [weak self, repository] in
            let result = try? await GitCLIRunner().stream(arguments: arguments, workingDirectory: repository) { text, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(text) } }
            }
            await MainActor.run {
                guard let self else { return }
                self.task = nil
                self.stopButton.title = "Close"
                if Task.isCancelled || result == nil {
                    self.statusLabel.stringValue = "Stopped."
                } else {
                    self.statusLabel.stringValue = "The daemon exited with code \(result?.exitCode ?? -1)."
                    self.statusLabel.textColor = .systemRed
                }
            }
        }
    }

    private func append(_ text: String) {
        outputView.textStorage?.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]))
        outputView.scrollToEndOfDocument(nil)
    }

    @objc private func copyURL() {
        guard let first = Self.cloneURLs(port: port).first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(first, forType: .string)
    }

    @objc private func stopOrClose() {
        if let task {
            task.cancel()
            stopButton.title = "Close"
        } else {
            close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
    }

    /// `git://<address>[:port]/` for every non-loopback IPv4/IPv6 address plus the Bonjour host name.
    static func cloneURLs(port: Int) -> [String] {
        let portSuffix = port == 9418 ? "" : ":\(port)"
        var hosts: [String] = []
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? {
            let bonjour = name + ".local"
            hosts.append(bonjour)
        }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addresses) == 0, let first = addresses {
            var pointer: UnsafeMutablePointer<ifaddrs>? = first
            while let current = pointer {
                defer { pointer = current.pointee.ifa_next }
                let flags = Int32(current.pointee.ifa_flags)
                guard let address = current.pointee.ifa_addr,
                      flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
                let family = address.pointee.sa_family
                guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(family == UInt8(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                var host = String(cString: buffer)
                if family == UInt8(AF_INET6) {
                    if host.hasPrefix("fe80:") { continue } // link-local needs an interface suffix; skip it
                    host = "[\(host)]"
                }
                if !hosts.contains(host) { hosts.append(host) }
            }
            freeifaddrs(addresses)
        }
        if hosts.isEmpty { hosts = ["localhost"] }
        return hosts.map { "git://\($0)\(portSuffix)/" }
    }
}
