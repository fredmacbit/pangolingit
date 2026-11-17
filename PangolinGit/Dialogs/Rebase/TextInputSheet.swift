import Cocoa

/// A small sheet asking for a (possibly multi-line) text: reword messages, branch descriptions,
/// rename targets. TortoiseGit uses separate small dialogs (`InputDlg`, the rebase message pane).
@MainActor
final class TextInputSheet: NSWindowController {

    private let textView = NSTextView()
    private let field = NSTextField()
    private let multiline: Bool
    private let errorLabel = NSTextField(labelWithString: "")
    private var completion: ((String?) -> Void)?
    /// Returns an error message for an unacceptable value (shown under the field), or nil.
    var validator: ((String) -> String?)?

    /// - Parameter multiline: a text view (messages, descriptions) instead of a single-line field (names).
    init(title: String, prompt: String, initialText: String, okTitle: String = "OK", multiline: Bool) {
        self.multiline = multiline
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: multiline ? 300 : 140),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = title
        super.init(window: window)
        buildUI(prompt: prompt, initialText: initialText, okTitle: okTitle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String {
        multiline ? textView.string : field.stringValue
    }

    private func buildUI(prompt: String, initialText: String, okTitle: String) {
        guard let content = window?.contentView else { return }
        let label = NSTextField(wrappingLabelWithString: prompt)
        label.translatesAutoresizingMaskIntoConstraints = false

        let editor: NSView
        if multiline {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            textView.isRichText = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.string = initialText
            textView.autoresizingMask = [.width]
            textView.isVerticallyResizable = true
            scroll.documentView = textView
            editor = scroll
        } else {
            field.stringValue = initialText
            editor = field
        }
        editor.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .systemRed
        errorLabel.font = NSFont.systemFont(ofSize: 11)

        let ok = NSButton(title: okTitle, target: self, action: #selector(okClicked))
        ok.keyEquivalent = "\r"
        if multiline { ok.keyEquivalentModifierMask = .command }
        ok.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel, ok])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(label)
        content.addSubview(editor)
        content.addSubview(errorLabel)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            editor.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            errorLabel.topAnchor.constraint(equalTo: editor.bottomAnchor, constant: 4),
            errorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        if multiline {
            editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
            if let first = initialText.split(separator: "\n").first {
                textView.setSelectedRange(NSRange(location: 0, length: (String(first) as NSString).length))
            }
        }
    }

    /// Shows the sheet on `parent` (or as a modal window) and calls `completion` with the text, or nil on Cancel.
    func begin(on parent: NSWindow?, completion: @escaping (String?) -> Void) {
        self.completion = completion
        guard let window else { return }
        // Nothing else owns the sheet while it is up.
        Self.active.insert(self)
        window.makeFirstResponder(multiline ? textView : field)
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            NSApp.runModal(for: window)
        }
    }

    private static var active = Set<TextInputSheet>()

    @objc private func okClicked() {
        if let error = validator?(text) {
            errorLabel.stringValue = error
            return
        }
        finish(text)
    }

    @objc private func cancelClicked() {
        finish(nil)
    }

    private func finish(_ value: String?) {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            NSApp.stopModal()
            window.orderOut(nil)
        }
        let completion = self.completion
        self.completion = nil
        Self.active.remove(self)
        completion?(value)
    }
}
