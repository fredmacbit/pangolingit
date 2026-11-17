import Cocoa
import PangolinGitCore

/// Issue-tracker integration (`bugtraq.*`), TortoiseGit's Settings ▸ Issue Tracker Config page, with
/// the regex tester (`CBugtraqRegexTestDlg`). The commit dialog and log read the result through
/// `GitConfigStore.bugtraq()`.
final class IssueTrackerSettingsViewController: GitConfigPaneViewController {

    private let previewLabel = NSTextField(wrappingLabelWithString: "")

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        paneTitle = "Issue Tracker"
        paneDescription = "Link commits to an issue tracker: a Bug-ID field in the commit dialog and clickable issue references in the log."
        rows = [
            Row(key: BugtraqConfig.Key.url.rawValue, label: "URL:", kind: .text(placeholder: "https://tracker/issues/%BUGID%"),
                tooltip: "Issue page; %BUGID% is replaced by the issue number."),
            Row(key: BugtraqConfig.Key.message.rawValue, label: "Message:", kind: .text(placeholder: "Issue: %BUGID%"),
                tooltip: "Line added to the commit message when a Bug-ID is entered."),
            Row(key: BugtraqConfig.Key.label.rawValue, label: "Field label:", kind: .text(placeholder: "Bug-ID / Issue-Nr:"),
                tooltip: "Label of the Bug-ID field in the commit dialog."),
            Row(key: BugtraqConfig.Key.logRegex.rawValue, label: "Log regex:", kind: .text(placeholder: "#(\\d+)"),
                tooltip: "Finds issue references in log messages: one regex whose group 1 is the id, or two regexes separated by a newline (Option-Return)."),
            Row(key: BugtraqConfig.Key.number.rawValue, label: "Bug-ID is numeric", kind: .bool,
                tooltip: "Only digits and commas are accepted in the Bug-ID field."),
            Row(key: BugtraqConfig.Key.append.rawValue, label: "Add the message line at the end (otherwise at the top)", kind: .bool,
                tooltip: "Where the message line goes."),
            Row(key: BugtraqConfig.Key.warnIfNoIssue.rawValue, label: "Warn when committing without a Bug-ID", kind: .bool,
                tooltip: "Ask before committing with an empty Bug-ID field.")
        ]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        super.loadView()
        let testButton = NSButton(title: "Test Regex…", target: self, action: #selector(testRegex))
        testButton.bezelStyle = .rounded
        testButton.toolTip = "Try the log regex on sample text."
        previewLabel.textColor = .secondaryLabelColor
        let row = NSStackView(views: [testButton, previewLabel])
        row.spacing = 12
        contentStack.addArrangedSubview(row)
    }

    override func valuesDidLoad() {
        updatePreview()
    }

    override func controlChanged() {
        super.controlChanged()
        updatePreview()
    }

    override func controlTextDidEndEditing(_ obj: Notification) {
        super.controlTextDidEndEditing(obj)
        updatePreview()
    }

    private var currentConfig: BugtraqConfig {
        BugtraqConfig(values: Dictionary(uniqueKeysWithValues: BugtraqConfig.Key.allCases.map { ($0.rawValue, value($0.rawValue)) }))
    }

    private func updatePreview() {
        let config = currentConfig
        guard config.message.contains("%BUGID%") else {
            previewLabel.stringValue = config.isActive ? "" : "Not configured."
            return
        }
        let sample = config.messageWithBugID("Fix the crash", bugID: "123").replacingOccurrences(of: "\n", with: " ⏎ ")
        previewLabel.stringValue = "Example: \(sample)"
    }

    /// Regex tester: shows which issue ids the current settings find in sample text.
    @objc private func testRegex() {
        let config = currentConfig
        let alert = NSAlert()
        alert.messageText = "Test issue references"
        alert.informativeText = "Enter a log message; the ids found with the current settings are listed below."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.stringValue = "Fixes #12 and Issue: 34"
        alert.accessoryView = input
        alert.addButton(withTitle: "Test")
        alert.addButton(withTitle: "Close")
        while alert.runModal() == .alertFirstButtonReturn {
            let references = config.issueReferences(in: input.stringValue)
            alert.informativeText = references.isEmpty
                ? "No issue references found."
                : references.map { "\($0.id)" + ($0.url.map { " → \($0.absoluteString)" } ?? "") }.joined(separator: "\n")
        }
    }
}
