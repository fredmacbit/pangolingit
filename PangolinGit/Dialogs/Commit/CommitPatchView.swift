import Cocoa
import PangolinGitCore

/// The commit dialog's patch pane (TortoiseGit's *View Patch>>* / *Partial Staging>>*): the
/// selected file's changes, hunk by hunk. With staging support each hunk has a Stage or Unstage
/// button that applies just that hunk to the index.
final class CommitPatchView: NSView {

    /// Applies one hunk to the index; `reverse` unstages it.
    var onApplyHunk: ((_ patch: String, _ reverse: Bool) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        titleLabel.font = NSFont.boldSystemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack

        addSubview(titleLabel)
        addSubview(scrollView)
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: clip.widthAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor)
        ])
        showMessage("Select a file to see its changes.")
    }

    /// Replaces the contents with a hint.
    func showMessage(_ text: String, title: String = "Patch") {
        titleLabel.stringValue = title
        clear()
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        stack.addArrangedSubview(label)
    }

    /// Shows a file's diffs.
    /// - Parameters:
    ///   - unstaged: working tree against the index (or the whole change when not staging).
    ///   - staged: index against HEAD; nil hides that section (no staging support).
    ///   - canStage: offer per-hunk buttons.
    func show(path: String, unstaged: String, staged: String?, canStage: Bool) {
        titleLabel.stringValue = path
        clear()
        if let staged {
            addSection("Staged changes", diff: staged, buttonTitle: canStage ? "Unstage Hunk" : nil, reverse: true)
            addSection("Unstaged changes", diff: unstaged, buttonTitle: canStage ? "Stage Hunk" : nil, reverse: false)
        } else {
            addSection(nil, diff: unstaged, buttonTitle: nil, reverse: false)
        }
        scrollView.contentView.scroll(to: .zero)
    }

    private func clear() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private func addSection(_ title: String?, diff: String, buttonTitle: String?, reverse: Bool) {
        if let title {
            let header = NSTextField(labelWithString: title)
            header.font = NSFont.boldSystemFont(ofSize: 12)
            stack.addArrangedSubview(header)
        }
        guard let patch = FileHunkPatch(unifiedDiff: diff) else {
            let empty = NSTextField(labelWithString: diff.contains("Binary files") ? "Binary file" : "No changes")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }
        for (index, hunk) in patch.hunks.enumerated() {
            let headerLabel = NSTextField(labelWithString: hunk.header)
            headerLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
            headerLabel.textColor = .secondaryLabelColor
            var row: [NSView] = [headerLabel]
            if let buttonTitle {
                let hunkPatch = patch.patch(forHunk: index)
                let button = ClosureButton(title: buttonTitle) { [weak self] in
                    self?.onApplyHunk?(hunkPatch, reverse)
                }
                button.bezelStyle = .inline
                button.controlSize = .small
                row.insert(button, at: 0)
            }
            let headerRow = NSStackView(views: row)
            headerRow.orientation = .horizontal
            headerRow.spacing = 8
            stack.addArrangedSubview(headerRow)
            stack.setCustomSpacing(2, after: headerRow)

            let body = NSTextField(labelWithAttributedString: Self.render(hunk.lines))
            body.lineBreakMode = .byClipping
            body.isSelectable = true
            stack.addArrangedSubview(body)
            stack.setCustomSpacing(10, after: body)
        }
    }

    /// Hunk lines coloured like the diff viewer (added green, removed red).
    private static func render(_ lines: [String]) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let added = DiffColors.added.withAlphaComponent(0.22)
        let deleted = DiffColors.deleted.withAlphaComponent(0.22)
        let text = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            switch line.first {
            case "+": attributes[.backgroundColor] = added
            case "-": attributes[.backgroundColor] = deleted
            case "\\": attributes[.foregroundColor] = NSColor.secondaryLabelColor
            default: break
            }
            text.append(NSAttributedString(string: line + (i < lines.count - 1 ? "\n" : ""), attributes: attributes))
        }
        return text
    }
}
