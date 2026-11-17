import Foundation
import Cocoa
import PangolinGitCore

/// Dialog for generating pull request summaries via `git request-pull` (`RequestPullDlg.cpp` in TortoiseGit).
/// Start defaults to the upstream, both ends have `…` pickers, and the result can be mailed
/// (*Send mail after create*).
public final class RequestPullWindowController: NSWindowController {
    
    public let repositoryPath: PangolinPath
    
    private var startRefField: NSTextField!
    private var repoUrlField: NSTextField!
    private var endRefField: NSTextField!
    private var resultTextView: NSTextView!
    private var generateButton: NSButton!
    private var copyButton: NSButton!
    private var statusLabel: NSTextField!
    private var sendMailButton: NSButton!
    private let sendMailCheck = NSButton(checkboxWithTitle: "Send mail after create", target: nil, action: nil)
    private let initialStart: String?
    private let initialEnd: String?

    /// - Parameters:
    ///   - start/end: preset revisions (e.g. from a push post-action: the remote branch and the pushed branch).
    public init(repositoryPath: PangolinPath, start: String? = nil, end: String? = nil) {
        self.repositoryPath = repositoryPath
        self.initialStart = start
        self.initialEnd = end
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Request Pull — \(repositoryPath.url.lastPathComponent)"
        window.minSize = NSSize(width: 500, height: 400)
        
        super.init(window: window)
        setupUI()
        populateDefaults()
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = self.window else { return }
        
        let container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        
        // Start commit / upstream
        let startLabel = NSTextField(labelWithString: "Start Revision (upstream / base branch):")
        startLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(startLabel)
        
        startRefField = NSTextField()
        startRefField.placeholderString = "e.g. origin/main, v1.0, master"
        startRefField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(startRefField)
        
        // Remote repository URL
        let urlLabel = NSTextField(labelWithString: "Public Repository URL:")
        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(urlLabel)
        
        repoUrlField = NSTextField()
        repoUrlField.placeholderString = "https://github.com/user/repo.git or git@github.com:user/repo.git"
        repoUrlField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(repoUrlField)
        
        // End commit / local branch
        let endLabel = NSTextField(labelWithString: "End Revision (local branch or commit):")
        endLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(endLabel)
        
        endRefField = NSTextField()
        endRefField.stringValue = initialEnd ?? "HEAD"
        endRefField.placeholderString = "HEAD or branch name"
        endRefField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(endRefField)
        
        // Output text view
        let outputLabel = NSTextField(labelWithString: "Generated Request Pull Summary:")
        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(outputLabel)
        
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        resultTextView = NSTextView()
        resultTextView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        resultTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        resultTextView.isVerticallyResizable = true
        resultTextView.autoresizingMask = [.width]
        resultTextView.textContainer?.widthTracksTextView = true
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scrollView.documentView = resultTextView
        container.addSubview(scrollView)
        
        // Status label
        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)
        
        // Buttons
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(closeButton)
        
        copyButton = NSButton(title: "Copy to Clipboard", target: self, action: #selector(copyClicked))
        copyButton.bezelStyle = .rounded
        copyButton.isEnabled = false
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(copyButton)
        
        sendMailButton = NSButton(title: "Send Mail…", target: self, action: #selector(sendMailClicked))
        sendMailButton.bezelStyle = .rounded
        sendMailButton.isEnabled = false
        sendMailButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sendMailButton)

        sendMailCheck.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sendMailCheck)

        let startPicker = RevisionPickerButton(repository: repositoryPath) { [weak self] in self?.startRefField.stringValue = $0 }
        let endPicker = RevisionPickerButton(repository: repositoryPath) { [weak self] in self?.endRefField.stringValue = $0 }
        for picker in [startPicker, endPicker] {
            picker.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(picker)
        }

        generateButton = NSButton(title: "Generate", target: self, action: #selector(generateClicked))
        generateButton.bezelStyle = .rounded
        generateButton.keyEquivalent = "\r"
        generateButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(generateButton)
        
        NSLayoutConstraint.activate([
            startLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            startLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            startLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            startRefField.topAnchor.constraint(equalTo: startLabel.bottomAnchor, constant: 6),
            startRefField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            startRefField.trailingAnchor.constraint(equalTo: startPicker.leadingAnchor, constant: -6),
            startPicker.centerYAnchor.constraint(equalTo: startRefField.centerYAnchor),
            startPicker.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            urlLabel.topAnchor.constraint(equalTo: startRefField.bottomAnchor, constant: 12),
            urlLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            urlLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            repoUrlField.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 6),
            repoUrlField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            repoUrlField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            endLabel.topAnchor.constraint(equalTo: repoUrlField.bottomAnchor, constant: 12),
            endLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            endLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            endRefField.topAnchor.constraint(equalTo: endLabel.bottomAnchor, constant: 6),
            endRefField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            endRefField.trailingAnchor.constraint(equalTo: endPicker.leadingAnchor, constant: -6),
            endPicker.centerYAnchor.constraint(equalTo: endRefField.centerYAnchor),
            endPicker.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            outputLabel.topAnchor.constraint(equalTo: endRefField.bottomAnchor, constant: 14),
            outputLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            outputLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            scrollView.topAnchor.constraint(equalTo: outputLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
            
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: sendMailCheck.leadingAnchor, constant: -8),

            sendMailCheck.centerYAnchor.constraint(equalTo: generateButton.centerYAnchor),
            sendMailCheck.trailingAnchor.constraint(equalTo: generateButton.leadingAnchor, constant: -12),

            sendMailButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            sendMailButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            
            closeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 80),
            
            copyButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            copyButton.trailingAnchor.constraint(equalTo: sendMailButton.leadingAnchor, constant: -8),
            
            generateButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            generateButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            generateButton.widthAnchor.constraint(equalToConstant: 95)
        ])
    }
    
    /// Start = the current branch's upstream (TortoiseGit uses the tracked remote branch); URL = that remote's URL.
    private func populateDefaults() {
        if let initialStart {
            startRefField.stringValue = initialStart
        }
        Task { @MainActor in
            let upstream = (try? await GitCLIRunner.runAsync(
                arguments: ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], workingDirectory: repositoryPath
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !upstream.isEmpty, self.startRefField.stringValue.isEmpty {
                self.startRefField.stringValue = upstream
            }
            // "origin/main" → remote "origin"; fall back to origin when there is no upstream.
            let startRemote = self.initialStart.flatMap { $0.split(separator: "/").first.map(String.init) }
            let remote = startRemote ?? upstream.split(separator: "/").first.map(String.init) ?? "origin"
            let remoteUrl = (try? await GitCLIRunner.runAsync(
                arguments: ["config", "--get", "remote.\(remote).url"], workingDirectory: repositoryPath
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !remoteUrl.isEmpty {
                self.repoUrlField.stringValue = remoteUrl
            }
        }
    }
    
    @objc private func closeClicked() {
        window?.close()
    }
    
    @objc private func copyClicked() {
        let text = resultTextView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "Copied to clipboard!"
    }
    
    /// Opens Send Mail with the summary as the message body (TortoiseGit's *Send mail after create*).
    @objc private func sendMailClicked() {
        let text = resultTextView.string
        guard !text.isEmpty else { return }
        let end = endRefField.stringValue.trimmingCharacters(in: .whitespaces)
        SendMailWindowController.present(repository: repositoryPath, patches: [],
                                         subject: "[GIT PULL] \(repositoryPath.filename) \(end.isEmpty ? "HEAD" : end)", body: text)
    }

    @objc private func generateClicked() {
        let start = startRefField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = repoUrlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = endRefField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !start.isEmpty else {
            statusLabel.stringValue = "Start revision cannot be empty."
            return
        }
        guard !url.isEmpty else {
            statusLabel.stringValue = "Repository URL cannot be empty."
            return
        }
        
        statusLabel.stringValue = "Running git request-pull..."
        generateButton.isEnabled = false
        
        Task {
            do {
                var args = ["request-pull", start, url]
                if !end.isEmpty {
                    args.append(end)
                }
                
                let output = try await GitCLIRunner.runAsync(arguments: args, workingDirectory: repositoryPath)
                
                await MainActor.run {
                    self.generateButton.isEnabled = true
                    self.resultTextView.string = output
                    self.copyButton.isEnabled = !output.isEmpty
                    self.sendMailButton.isEnabled = !output.isEmpty
                    self.statusLabel.stringValue = "Generated successfully."
                    if !output.isEmpty, self.sendMailCheck.state == .on {
                        self.sendMailClicked()
                    }
                }
            } catch {
                await MainActor.run {
                    self.generateButton.isEnabled = true
                    self.statusLabel.stringValue = "Error running request-pull."
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
}
