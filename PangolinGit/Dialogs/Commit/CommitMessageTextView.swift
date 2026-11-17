import Cocoa
import PangolinGitCore

/// The commit message editor (TortoiseGit's `CSciEdit` in the commit dialog): monospaced text with
/// a line-width marker (`tgit.logwidthmarker`), `*bold*` / `^italic^` / `_underline_` markup,
/// word completion from the changed files (`autolist.txt`) and snippets, ⌘/⌃-Return to commit and
/// extra context-menu entries.
final class CommitMessageTextView: NSTextView {

    /// Commit from the keyboard (TortoiseGit's Ctrl+Return).
    var onSubmit: (() -> Void)?
    /// Called after every edit (styling has been applied by then).
    var onTextChange: (() -> Void)?
    /// Entries put at the top of the right-click menu.
    var extraMenuItems: (() -> [NSMenuItem])?
    /// Words offered while typing: changed file names and the identifiers declared in them.
    var completionWords: Set<String> = []
    /// `snippet.txt`: typing the name offers the expansion.
    var snippets: [String: String] = [:]
    /// Characters typed before the completion list pops up by itself (TortoiseGit's `AutoCompleteMinChars`).
    var autoCompletionMinimumLength = 3

    /// Column of the vertical guide; 0 hides it.
    var widthMarkerColumn = 0 {
        didSet { needsDisplay = true }
    }

    static let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var isCompleting = false

    /// Plain-text editor setup; `NSTextView()` gives a text system with a container that tracks the width.
    func configure() {
        font = Self.baseFont
        isRichText = false
        allowsUndo = true
        isContinuousSpellCheckingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        textContainerInset = NSSize(width: 4, height: 4)
        typingAttributes = [.font: Self.baseFont, .foregroundColor: NSColor.textColor]
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && (flags.contains(.command) || flags.contains(.control)) {
            onSubmit?()
            return
        }
        // Ctrl+Space opens the completion list, as in TortoiseGit.
        if event.keyCode == 49 && flags == .control {
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard !isCompleting, let typed = string as? String, typed.count == 1,
              let char = typed.first, char.isLetter || char.isNumber || char == "_" else { return }
        let partial = partialWord()
        guard partial.count >= autoCompletionMinimumLength, !candidates(for: partial).isEmpty else { return }
        // Pop up after the keystroke has been processed.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self else { return }
            self.complete(nil)
        }
    }

    // MARK: - Completion

    private func partialWord() -> String {
        let range = rangeForUserCompletion
        guard range.location != NSNotFound, range.length > 0 else { return "" }
        return (string as NSString).substring(with: range)
    }

    private func candidates(for partial: String) -> [String] {
        var result: [String] = []
        if let expansion = snippets[partial] { result.append(expansion) }
        result += CommitAutoCompletion.completions(for: partial, in: completionWords.union(snippets.keys))
        return result
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let partial = (string as NSString).substring(with: charRange)
        let own = candidates(for: partial)
        guard !own.isEmpty else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        index.pointee = 0
        return own
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        isCompleting = true
        defer { isCompleting = false }
        // A snippet name chosen from the list expands to its text.
        let replacement = flag ? (snippets[word] ?? word) : word
        super.insertCompletion(replacement, forPartialWordRange: charRange, movement: movement, isFinal: flag)
    }

    // MARK: - Styling

    override func didChangeText() {
        super.didChangeText()
        applyMarkup()
        onTextChange?()
    }

    /// Re-applies the `*bold*` markup styling to the whole message.
    func applyMarkup() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let base = Self.baseFont
        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: full)
        storage.addAttribute(.font, value: base, range: full)
        for (range, style) in CommitMessage.markupRanges(in: storage.string) {
            switch style {
            case .bold:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .bold), range: range)
            case .italic:
                let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                storage.addAttribute(.font, value: italic, range: range)
            case .underline:
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        storage.endEditing()
    }

    // MARK: - Width marker

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard widthMarkerColumn > 0 else { return }
        let charWidth = ("M" as NSString).size(withAttributes: [.font: Self.baseFont]).width
        let padding = textContainer?.lineFragmentPadding ?? 0
        let x = (textContainerOrigin.x + padding + CGFloat(widthMarkerColumn) * charWidth).rounded() + 0.5
        guard x < bounds.maxX else { return }
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: rect.minY))
        path.line(to: NSPoint(x: x, y: rect.maxY))
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let extras = extraMenuItems?() ?? []
        guard !extras.isEmpty else { return menu }
        menu.insertItem(.separator(), at: 0)
        for item in extras.reversed() {
            menu.insertItem(item, at: 0)
        }
        return menu
    }
}
