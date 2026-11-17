import Foundation
import Cocoa
import CryptoKit
import PangolinGitCore

/// Update check (TortoiseGit's `CCheckForUpdatesDlg`): reads a GitHub-compatible releases feed,
/// offers the newest release of the chosen channel in a window with the changelog, a download list,
/// Download / Skip This Version / Remind Me Later, and runs weekly at launch when enabled.
/// This is a plain HTTPS check, not the Sparkle framework; downloads are verified against a
/// `<asset>.sha256` file when the release provides one.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private init() {}

    private var isChecking = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Feed URL: the Advanced option / managed preference `UpdateCheckURL`, else the official releases.
    var feedURL: URL {
        let custom = ConfigManager.shared.advancedString(.updateCheckURL)
        return URL(string: custom).flatMap { $0.scheme == nil ? nil : $0 } ?? UpdateCheck.defaultFeedURL
    }

    /// Weekly check at launch (Settings ▸ General). Silent unless an update is found.
    func checkAutomaticallyIfDue() {
        let config = ConfigManager.shared
        guard config.automaticUpdateCheck, config.advancedBool(.versionCheck),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              UpdateCheck.isAutomaticCheckDue(lastCheck: config.lastUpdateCheck, remindAfter: config.updateRemindAfter) else { return }
        checkForUpdates(userInitiated: false)
    }

    /// Checks now. A user-initiated check reports "up to date" and errors and ignores a skipped version.
    func checkForUpdates(userInitiated: Bool) {
        guard ConfigManager.shared.advancedBool(.versionCheck) else {
            if userInitiated {
                showAlert("Update checks are turned off", "The VersionCheck option (Settings ▸ Advanced or a configuration profile) disables them.")
            }
            return
        }
        guard !isChecking else { return }
        isChecking = true
        let url = feedURL
        let version = currentVersion
        Task {
            defer { isChecking = false }
            do {
                var request = URLRequest(url: url)
                request.setValue("PangolinGit/\(version)", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let releases = UpdateCheck.parseReleases(data)
                ConfigManager.shared.lastUpdateCheck = Date()
                guard let update = UpdateCheck.availableUpdate(in: releases, currentVersion: version,
                                                               includePrereleases: ConfigManager.shared.updateIncludesPrereleases) else {
                    if userInitiated {
                        showAlert("You're up to date", "PangolinGit \(version) is the newest version available.")
                    }
                    return
                }
                let skipped = StoredDecisions.shared.decision(for: StoredDecisions.Key.skippedUpdatePrefix + update.version) == 1
                guard userInitiated || !skipped else { return }
                WindowRegistry.shared.present({ UpdateWindowController(release: update, currentVersion: version) }, key: "update")
            } catch {
                if userInitiated {
                    showAlert("Couldn't check for updates", "\(url.host ?? url.absoluteString): \(error.localizedDescription)")
                }
            }
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// The "new version available" window: versions, changelog, downloads and the three choices.
@MainActor
final class UpdateWindowController: NSWindowController {
    private let release: ReleaseInfo
    private let assetPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let downloadButton = NSButton(title: "Download", target: nil, action: nil)
    private var downloadTask: Task<Void, Never>?

    init(release: ReleaseInfo, currentVersion: String) {
        self.release = release
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Software Update"
        window.minSize = NSSize(width: 480, height: 340)
        super.init(window: window)
        setupUI(currentVersion: currentVersion)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI(currentVersion: String) {
        guard let content = window?.contentView else { return }
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "PangolinGit \(release.version) is available"
                                + (release.isPrerelease ? " (preview)" : ""))
        title.font = .boldSystemFont(ofSize: 15)
        let subtitle = NSTextField(labelWithString: "You have version \(currentVersion)."
                                   + (release.publishedAt.map { " Released \(DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none))." } ?? ""))
        subtitle.textColor = .secondaryLabelColor

        let notesScroll = NSScrollView()
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .bezelBorder
        let notes = NSTextView()
        notes.isEditable = false
        notes.autoresizingMask = [.width]
        notes.textContainerInset = NSSize(width: 6, height: 6)
        let markdown = (try? NSAttributedString(markdown: release.notes.isEmpty ? "_No release notes._" : release.notes,
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? NSAttributedString(string: release.notes)
        let styled = NSMutableAttributedString(attributedString: markdown)
        styled.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: styled.length))
        notes.textStorage?.setAttributedString(styled)
        notesScroll.documentView = notes

        for asset in release.assets {
            let megabytes = Double(asset.size) / 1_048_576
            assetPopup.addItem(withTitle: asset.size > 0 ? "\(asset.name) (\(String(format: "%.1f", megabytes)) MB)" : asset.name)
            assetPopup.lastItem?.representedObject = asset.name
        }
        if let preferred = UpdateCheck.preferredAsset(of: release),
           let index = release.assets.firstIndex(of: preferred) {
            assetPopup.selectItem(at: index)
        }
        assetPopup.isHidden = release.assets.isEmpty
        downloadButton.target = self
        downloadButton.action = #selector(download)
        downloadButton.keyEquivalent = "\r"
        downloadButton.isEnabled = !release.assets.isEmpty
        let page = NSButton(title: "Release Page", target: self, action: #selector(openPage))
        page.isEnabled = release.pageURL != nil
        let skip = NSButton(title: "Skip This Version", target: self, action: #selector(skipVersion))
        skip.toolTip = "Don't offer \(release.version) again (a manual check still shows it)."
        let later = NSButton(title: "Remind Me Later", target: self, action: #selector(remindLater))
        later.keyEquivalent = "\u{1b}"
        later.toolTip = "Ask again in a day."
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        let top = NSStackView(views: [icon, header])
        top.spacing = 12
        let downloadRow = NSStackView(views: [NSTextField(labelWithString: "Download:"), assetPopup, downloadButton, page])
        downloadRow.spacing = 8
        let bottom = NSStackView(views: [statusLabel, NSView(), skip, later])
        bottom.spacing = 8
        for button in [downloadButton, page, skip, later] { button.bezelStyle = .rounded }

        for view in [top, notesScroll, downloadRow, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            notesScroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            notesScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            notesScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            notesScroll.bottomAnchor.constraint(equalTo: downloadRow.topAnchor, constant: -12),
            downloadRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            downloadRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            downloadRow.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    @objc private func openPage() {
        if let url = release.pageURL { NSWorkspace.shared.open(url) }
    }

    @objc private func skipVersion() {
        StoredDecisions.shared.store(1, for: StoredDecisions.Key.skippedUpdatePrefix + release.version)
        close()
    }

    @objc private func remindLater() {
        ConfigManager.shared.updateRemindAfter = Date().addingTimeInterval(24 * 60 * 60)
        close()
    }

    /// Downloads the chosen file to ~/Downloads, checks it against `<name>.sha256` when published,
    /// then shows it in Finder (and opens a disk image).
    @objc private func download() {
        guard downloadTask == nil,
              let name = assetPopup.selectedItem?.representedObject as? String,
              let asset = release.assets.first(where: { $0.name == name }) else { return }
        let checksumAsset = release.assets.first { $0.name.lowercased() == name.lowercased() + ".sha256" }
        downloadButton.isEnabled = false
        statusLabel.stringValue = "Downloading \(asset.name)…"
        downloadTask = Task { [weak self] in
            do {
                let (temporary, _) = try await URLSession.shared.download(from: asset.downloadURL)
                if let checksumAsset {
                    let (data, _) = try await URLSession.shared.data(from: checksumAsset.downloadURL)
                    let expected = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
                    let actual = SHA256.hash(data: try Data(contentsOf: temporary)).map { String(format: "%02x", $0) }.joined()
                    guard expected == actual else {
                        throw NSError(domain: "PangolinGit", code: 1, userInfo: [NSLocalizedDescriptionKey:
                            "The download does not match its published SHA-256 checksum and was discarded."])
                    }
                }
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                var destination = downloads.appendingPathComponent(asset.name)
                var counter = 1
                while FileManager.default.fileExists(atPath: destination.path) {
                    counter += 1
                    let base = (asset.name as NSString).deletingPathExtension
                    let ext = (asset.name as NSString).pathExtension
                    destination = downloads.appendingPathComponent("\(base) \(counter)" + (ext.isEmpty ? "" : ".\(ext)"))
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                await MainActor.run {
                    self?.statusLabel.stringValue = "Saved to \(destination.path)" + (checksumAsset != nil ? " (checksum verified)" : "")
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    if destination.pathExtension.lowercased() == "dmg" { NSWorkspace.shared.open(destination) }
                }
            } catch {
                await MainActor.run {
                    self?.statusLabel.stringValue = "Download failed: \(error.localizedDescription)"
                    self?.statusLabel.textColor = .systemRed
                }
            }
            await MainActor.run {
                self?.downloadTask = nil
                self?.downloadButton.isEnabled = true
            }
        }
    }
}
