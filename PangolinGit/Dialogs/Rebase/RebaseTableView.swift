import Cocoa
import PangolinGitCore

/// Commit list of the rebase dialog with TortoiseGit's keyboard shortcuts (`CRebaseDlg::PreTranslateMessage`):
/// Space cycles pick → squash → edit → skip, P pick, Q squash, F fixup, E edit, R reword, S skip,
/// U / D move the selection up / down. ⌘A selects all (standard table behaviour).
@MainActor
final class RebaseTableView: NSTableView {

    enum KeyCommand {
        case cycle
        case set(GitRebaseTodoLine.Action)
        case moveUp, moveDown
    }

    /// Handles a shortcut; returns false to let the table handle the key.
    var onKeyCommand: ((KeyCommand) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, let command = Self.command(for: event.charactersIgnoringModifiers ?? ""),
           onKeyCommand?(command) == true {
            return
        }
        super.keyDown(with: event)
    }

    static func command(for characters: String) -> KeyCommand? {
        switch characters.lowercased() {
        case " ": return .cycle
        case "p": return .set(.pick)
        case "q": return .set(.squash)
        case "f": return .set(.fixup)
        case "e": return .set(.edit)
        case "r": return .set(.reword)
        case "s": return .set(.drop)
        case "u": return .moveUp
        case "d": return .moveDown
        default: return nil
        }
    }

    /// TortoiseGit's Space order: pick → squash → edit → skip → pick (fixup and reword fall back to pick).
    static func nextAction(after action: GitRebaseTodoLine.Action) -> GitRebaseTodoLine.Action {
        switch action {
        case .pick: return .squash
        case .squash: return .edit
        case .edit: return .drop
        case .drop, .fixup, .reword: return .pick
        }
    }
}

extension GitRebaseTodoLine.Action {
    /// Label in the list; `drop` is TortoiseGit's "skip".
    var title: String {
        switch self {
        case .pick: return "Pick"
        case .reword: return "Reword"
        case .edit: return "Edit"
        case .squash: return "Squash"
        case .fixup: return "Fixup"
        case .drop: return "Skip"
        }
    }

    var color: NSColor {
        switch self {
        case .pick: return .labelColor
        case .reword: return .systemBlue
        case .edit: return .systemOrange
        case .squash, .fixup: return .systemPurple
        case .drop: return .tertiaryLabelColor
        }
    }
}
