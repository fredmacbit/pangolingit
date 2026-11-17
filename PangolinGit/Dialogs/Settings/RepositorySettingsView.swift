import Cocoa
import PangolinGitCore

/// Per-repository commit options stored in git config / `.tgitconfig` (TortoiseGit's Settings ▸
/// Dialogs 3, `SetDialogs3.cpp`): minimum message length, width marker,
/// Signed-off-by warning, spell-check language and project logo. Read through `ProjectSettings`.
final class RepositorySettingsViewController: GitConfigPaneViewController {

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        paneTitle = "Repository Settings"
        paneDescription = "Commit-dialog options saved in git configuration, so they can be shared with the "
            + "project through .tgitconfig."
        var languages: [(String, String)] = [("Inherit / system language", ""), ("Spell checking off", "-1")]
        languages += NSSpellChecker.shared.availableLanguages.map { code in
            (Locale.current.localizedString(forIdentifier: code) ?? code, code)
        }.sorted { $0.0 < $1.0 }
        rows = [
            Row(key: ProjectSettings.Key.logMinSize.rawValue, label: "Minimum message length:", kind: .integer,
                tooltip: "The commit dialog refuses shorter messages."),
            Row(key: ProjectSettings.Key.logWidthMarker.rawValue, label: "Message width marker:", kind: .integer,
                tooltip: "Column of the right-margin guide in the commit message editor."),
            Row(key: ProjectSettings.Key.warnNoSignedOffBy.rawValue, label: "Warn when Signed-off-by is missing", kind: .bool,
                tooltip: "Ask before committing a message without a Signed-off-by line."),
            Row(key: ProjectSettings.Key.projectLanguage.rawValue, label: "Spell-check language:", kind: .choice(languages),
                tooltip: "Language for spell checking commit messages."),
            Row(key: ProjectSettings.Key.icon.rawValue, label: "Project logo:", kind: .text(placeholder: "path relative to the repository"),
                tooltip: "Image shown in the commit dialog.")
        ]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
