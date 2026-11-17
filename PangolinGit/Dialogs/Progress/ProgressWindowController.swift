import Cocoa
import PangolinGitCore

/// Live git progress window mirroring TortoiseGit's `CProgressDlg` / `CGitProgressDlg`
/// (`src/TortoiseProc/ProgressDlg.cpp`): streams git's output, colours errors, can abort the run,
/// reports the elapsed time and offers the natural next step ("post actions") when it finishes.
@MainActor
public final class ProgressWindowController: NSWindowController, NSWindowDelegate {

    /// A follow-up button shown when the run finishes (TortoiseGit's `PostCmdList`).
    public struct PostAction {
        public let title: String
        public let handler: @MainActor () -> Void

        public init(_ title: String, handler: @escaping @MainActor () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    /// How a run ended, handed to `postActions` and `onFinish`.
    public struct Outcome {
        public let succeeded: Bool
        public let cancelled: Bool
        /// Result of the last command that ran (nil if git could not be started).
        public let result: GitCLIResult?
        /// Everything git printed, stdout and stderr interleaved.
        public let output: String
    }

    private let commands: [[String]]
    private let workingDirectory: PangolinPath?
    private let environment: [String: String]?
    /// Repository to refresh afterwards (open windows and Finder badges).
    private let repository: PangolinPath?

    /// Builds the follow-up buttons for the finished run. Retry is added automatically on failure.
    public var postActions: ((Outcome) -> [PostAction])?
    /// Called once the run finished, before auto-close.
    public var onFinish: ((Outcome) -> Void)?

    private let outputTextView = NSTextView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Running…")
    private let actionStack = NSStackView()
    private let closeButton = NSButton(title: "Abort", target: nil, action: nil)

    private var task: Task<Void, Never>?
    private var isRunning = false
    /// Start of the line currently being written, and whether git sent a carriage return that
    /// means the next text overwrites that line (its progress counters).
    private var currentLineStart = 0
    private var overwritePending = false
    private var transcript = ""

    /// - Parameters:
    ///   - title: shown in the window title, e.g. "Push".
    ///   - commands: git argument lists run one after another; the run stops at the first failure.
    public init(title: String, commands: [[String]], workingDirectory: PangolinPath?,
                repository: PangolinPath? = nil, environment: [String: String]? = nil) {
        self.commands = commands
        self.workingDirectory = workingDirectory
        self.repository = repository ?? workingDirectory
        self.environment = environment
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let place = (repository ?? workingDirectory)?.filename
        window.title = place.map { "\(title) — \($0)" } ?? title
        window.minSize = NSSize(width: 480, height: 280)
        super.init(window: window)
        window.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Creates, shows and starts a progress window.
    @discardableResult
    public static func run(title: String, commands: [[String]], workingDirectory: PangolinPath?,
                           repository: PangolinPath? = nil, environment: [String: String]? = nil,
                           postActions: ((Outcome) -> [PostAction])? = nil,
                           onFinish: ((Outcome) -> Void)? = nil) -> ProgressWindowController {
        let controller = ProgressWindowController(title: title, commands: commands, workingDirectory: workingDirectory,
                                                  repository: repository, environment: environment)
        controller.postActions = postActions
        controller.onFinish = onFinish
        WindowRegistry.shared.present({ controller }, repository: repository ?? workingDirectory)
        controller.start()
        return controller
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.boldSystemFont(ofSize: 13)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = outputTextView
        outputTextView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        outputTextView.minSize = NSSize(width: 0, height: 0)
        outputTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputTextView.isVerticallyResizable = true
        outputTextView.autoresizingMask = [.width]
        outputTextView.textContainer?.widthTracksTextView = true
        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.font = Self.font
        outputTextView.textContainerInset = NSSize(width: 4, height: 4)

        actionStack.orientation = .horizontal
        actionStack.spacing = 8
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(onCloseClicked)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        [spinner, statusLabel, scroll, actionStack, closeButton].forEach(contentView.addSubview)

        NSLayoutConstraint.activate([
            spinner.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            spinner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            statusLabel.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),

            actionStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            actionStack.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            actionStack.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }

    // MARK: - Running

    /// Starts (or restarts, for Retry) the commands.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        closeButton.title = "Abort"
        closeButton.keyEquivalent = "\u{1b}"
        statusLabel.stringValue = "Running…"
        statusLabel.textColor = .labelColor
        spinner.startAnimation(nil)
        let started = Date()

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let runner = GitCLIRunner()
            var last: GitCLIResult?
            var startError: Error?
            for arguments in self.commands {
                self.appendHeader(GitCLIRunner.commandLine(arguments))
                do {
                    let result = try await runner.stream(arguments: arguments, workingDirectory: self.workingDirectory,
                                                         environment: self.environment) { [weak self] text, isError in
                        // The main queue is FIFO, so chunks arrive in order and before the summary.
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(text, isError: isError) } }
                    }
                    last = result
                    if !result.isSuccess || Task.isCancelled { break }
                } catch {
                    startError = error
                    break
                }
            }
            // Let output still queued on the main queue land before the summary.
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            self.finish(result: last, startError: startError, cancelled: Task.isCancelled,
                        elapsed: Date().timeIntervalSince(started))
        }
    }

    private func finish(result: GitCLIResult?, startError: Error?, cancelled: Bool, elapsed: TimeInterval) {
        isRunning = false
        task = nil
        spinner.stopAnimation(nil)
        let succeeded = !cancelled && startError == nil && (result?.isSuccess ?? false)
        let seconds = String(format: "%.1f s", elapsed)

        if let startError {
            append(startError.localizedDescription + "\n", isError: true)
        }
        let summary: String
        if cancelled {
            summary = "Aborted after \(seconds)"
            statusLabel.textColor = .systemOrange
        } else if succeeded {
            summary = "Success (\(seconds))"
            statusLabel.textColor = .systemGreen
        } else {
            summary = "Failed with exit code \(result?.exitCode ?? -1) (\(seconds))"
            statusLabel.textColor = .systemRed
        }
        statusLabel.stringValue = summary
        appendHeader(summary)

        closeButton.title = "Close"
        closeButton.keyEquivalent = "\r"

        let outcome = Outcome(succeeded: succeeded, cancelled: cancelled, result: result, output: transcript)
        var actions = postActions?(outcome) ?? []
        if !succeeded {
            actions.append(PostAction("Retry") { [weak self] in self?.start() })
        }
        for action in actions {
            let button = ClosureButton(title: action.title, handler: action.handler)
            button.bezelStyle = .rounded
            actionStack.addArrangedSubview(button)
        }

        if let repository {
            RepositoryEvents.post(repository)
        }
        onFinish?(outcome)

        let followUps = actions.count
        switch ConfigManager.shared.progressAutoClose {
        case .ifNoErrors where succeeded,
             .ifNoFurtherOptions where succeeded && followUps == 0:
            close()
        default:
            break
        }
    }

    @objc private func onCloseClicked() {
        if isRunning {
            task?.cancel()
        } else {
            close()
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window while git runs aborts it, like TortoiseGit's Abort button.
        task?.cancel()
        return true
    }

    // MARK: - Output

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private func appendHeader(_ text: String) {
        guard let storage = outputTextView.textStorage else { return }
        if storage.length > 0 && !storage.string.hasSuffix("\n") {
            storage.append(NSAttributedString(string: "\n"))
        }
        storage.append(NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]))
        transcript += text + "\n"
        currentLineStart = storage.length
        overwritePending = false
        outputTextView.scrollToEndOfDocument(nil)
    }

    /// Appends git output. A carriage return (git's progress counters) makes the next text replace
    /// the current line; each finished line is coloured by its content.
    private func append(_ text: String, isError: Bool) {
        guard let storage = outputTextView.textStorage else { return }
        transcript += text
        let base: NSColor = isError ? .secondaryLabelColor : .labelColor
        var segment = ""

        func flushSegment() {
            guard !segment.isEmpty else { return }
            if overwritePending {
                storage.deleteCharacters(in: NSRange(location: currentLineStart, length: storage.length - currentLineStart))
                overwritePending = false
            }
            storage.append(NSAttributedString(string: segment, attributes: [.font: Self.font, .foregroundColor: base]))
            segment = ""
        }

        for character in text {
            switch character {
            case "\r\n", "\n":
                flushSegment()
                storage.append(NSAttributedString(string: "\n", attributes: [.font: Self.font]))
                colourLine(in: storage, from: currentLineStart)
                currentLineStart = storage.length
                overwritePending = false
            case "\r":
                flushSegment()
                overwritePending = true
            default:
                segment.append(character)
            }
        }
        flushSegment()
        if storage.length > currentLineStart {
            colourLine(in: storage, from: currentLineStart)
        }
        outputTextView.scrollToEndOfDocument(nil)
    }

    private func colourLine(in storage: NSTextStorage, from start: Int) {
        let range = NSRange(location: start, length: storage.length - start)
        // Settings ▸ Advanced ▸ StyleGitOutput.
        guard range.length > 0, ConfigManager.shared.advancedBool(.styleGitOutput) else { return }
        let line = (storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
        if let colour = Self.colour(forLine: line) {
            storage.addAttribute(.foregroundColor, value: colour, range: range)
        }
    }

    /// Colour for well-known git message prefixes (TortoiseGit's `StyleGitOutput`).
    private static func colour(forLine line: String) -> NSColor? {
        let lower = line.lowercased()
        if lower.hasPrefix("error") || lower.hasPrefix("fatal") || lower.hasPrefix("! [rejected]")
            || lower.hasPrefix("! [remote rejected]") || lower.hasPrefix("conflict") {
            return .systemRed
        }
        if lower.hasPrefix("warning") || lower.hasPrefix("hint") {
            return .systemOrange
        }
        return nil
    }
}

/// Push button that runs a closure; used for post actions.
final class ClosureButton: NSButton {
    private var handler: (@MainActor () -> Void)?

    convenience init(title: String, handler: @escaping @MainActor () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        target = self
        action = #selector(run)
    }

    @objc private func run() {
        handler?()
    }
}
