import Cocoa
import PangolinGitCore

/// About PangolinGit (TortoiseGit's `CAboutDlg`): app, git, git-lfs and macOS versions, credits,
/// website/support links and a *Check for Updates…* button; the version text can be copied for bug reports.
@MainActor
final class AboutWindowController: NSWindowController {

    private let versionsLabel = NSTextField(wrappingLabelWithString: "")
    private var versions: [String] = []

    static func show() {
        WindowRegistry.shared.present({ AboutWindowController() }, key: "about")
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About PangolinGit"
        super.init(window: window)
        setupUI()
        loadVersions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: "PangolinGit")
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        let version = NSTextField(labelWithString: "Version \(appVersion)")
        version.textColor = .secondaryLabelColor

        versionsLabel.isSelectable = true
        versionsLabel.alignment = .center
        versionsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        versionsLabel.textColor = .secondaryLabelColor

        let credits = NSTextField(labelWithAttributedString: Self.credits)
        credits.isSelectable = true
        credits.allowsEditingTextAttributes = true
        credits.alignment = .center

        let update = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdates))
        let copy = NSButton(title: "Copy Version Info", target: self, action: #selector(copyVersions))
        copy.toolTip = "Copy the versions above, e.g. for a bug report."
        let ok = NSButton(title: "OK", target: self, action: #selector(closeWindow))
        ok.keyEquivalent = "\r"
        for button in [update, copy, ok] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views: [update, copy, ok])
        buttons.spacing = 8

        let stack = NSStackView(views: [icon, name, version, versionsLabel, credits, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: credits)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            versionsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            credits.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    /// git and git-lfs versions are read off the main thread.
    private func loadVersions() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        versions = ["PangolinGit \(appVersion)", "macOS \(os)"]
        versionsLabel.stringValue = (versions + ["git …"]).joined(separator: "\n")
        Task { @MainActor in
            let runner = GitCLIRunner()
            let git = (try? await runner.run(arguments: ["--version"]))
                .flatMap { $0.isSuccess ? $0.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
                ?? "git not found"
            let lfs = (try? await runner.run(arguments: ["lfs", "version"]))
                .flatMap { $0.isSuccess ? $0.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
                ?? "git-lfs not installed"
            versions += ["\(git) — \(runner.executablePath)", lfs]
            versionsLabel.stringValue = versions.joined(separator: "\n")
        }
    }

    /// Credits shown under the versions.
    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let text = NSMutableAttributedString(
            string: "Git in Finder: status badges, context-menu commands and a full set of Git dialogs.\n\nBy Frederik Vande Rieviere. A macOS port of ",
            attributes: body)
        var link = body
        link[.link] = URL(string: "https://tortoisegit.org")!
        text.append(NSAttributedString(string: "TortoiseGit", attributes: link))
        text.append(NSAttributedString(string: ". Licensed under the GNU GPL v2.\n\n", attributes: body))
        link[.link] = URL(string: "https://github.com/fredmacbit/pangolingit")!
        text.append(NSAttributedString(string: "Website", attributes: link))
        text.append(NSAttributedString(string: "  ·  ", attributes: body))
        link[.link] = URL(string: "https://github.com/fredmacbit/pangolingit/issues")!
        text.append(NSAttributedString(string: "Support & bug reports", attributes: link))
        text.append(NSAttributedString(string: "  ·  ", attributes: body))
        link[.link] = URL(string: "https://github.com/fredmacbit/pangolingit/graphs/contributors")!
        text.append(NSAttributedString(string: "Contributors", attributes: link))
        return text
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkForUpdates(userInitiated: true)
    }

    @objc private func copyVersions() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(versions.joined(separator: "\n"), forType: .string)
    }

    @objc private func closeWindow() {
        close()
    }
}
