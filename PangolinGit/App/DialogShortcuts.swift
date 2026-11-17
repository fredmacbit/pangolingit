import Cocoa
import PangolinGitCore

/// Keyboard shortcuts every dialog gets through the responder chain (SH-19), the macOS form of
/// TortoiseGit's F5 (refresh), Ctrl+F (search), Ctrl+Return (OK from a text box) and Ctrl+C in lists.
/// The menu items live in `MainMenuBuilder`; their actions reach the key window through the
/// responder chain, so no dialog has to implement them.
extension NSWindow {

    /// ⌘R: reloads every window showing this window's repository and refreshes its Finder badges.
    @objc func pangolinRefresh(_ sender: Any?) {
        guard let url = representedURL else {
            NSSound.beep()
            return
        }
        RepositoryEvents.post(PangolinPath(url.path))
    }

    /// ⌘F: puts the cursor into the window's search/filter field.
    @objc func pangolinFocusSearchField(_ sender: Any?) {
        guard let field = contentView.flatMap(DialogShortcuts.firstSearchField(in:)) else {
            NSSound.beep()
            return
        }
        makeFirstResponder(field)
        field.selectText(nil)
    }

    /// ⌘↩: presses the default button even while a multi-line text view (e.g. a commit message) has
    /// the focus, where plain Return inserts a line break.
    @objc func pangolinPerformDefaultAction(_ sender: Any?) {
        guard let button = defaultButtonCell?.controlView as? NSButton, button.isEnabled else {
            NSSound.beep()
            return
        }
        button.performClick(sender)
    }
}

extension NSTableView {
    /// ⌘C in any list: copies the selected rows as the text shown in their cells, one row per line,
    /// columns separated by tabs (TortoiseGit's list controls copy their visible columns too).
    @objc func copy(_ sender: Any?) {
        let text = DialogShortcuts.text(ofRows: selectedRowIndexes, in: self)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
enum DialogShortcuts {

    /// Depth-first search for the first search field (filter fields of the lists and logs).
    static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField, !field.isHidden, field.isEnabled { return field }
        for subview in view.subviews {
            if let found = firstSearchField(in: subview) { return found }
        }
        return nil
    }

    static func text(ofRows rows: IndexSet, in tableView: NSTableView) -> String {
        rows.compactMap { row -> String? in
            let cells = tableView.tableColumns.indices.compactMap { column -> String? in
                guard let view = tableView.view(atColumn: column, row: row, makeIfNecessary: true) else { return nil }
                return cellText(view)
            }.filter { !$0.isEmpty }
            return cells.isEmpty ? nil : cells.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// The visible text of a cell view: a label, a text field inside a table cell or stack, or nothing
    /// for checkboxes and images.
    static func cellText(_ view: NSView) -> String? {
        if let field = view as? NSTextField { return field.stringValue }
        if let cell = view as? NSTableCellView, let field = cell.textField { return field.stringValue }
        if view is NSButton || view is NSImageView { return nil }
        for subview in view.subviews {
            if let text = cellText(subview), !text.isEmpty { return text }
        }
        return nil
    }
}
