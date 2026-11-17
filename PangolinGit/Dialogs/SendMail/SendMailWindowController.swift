import Cocoa
import PangolinGitCore

/// *Send Mail…* (TortoiseGit's `SendMailDlg.cpp` / `CSendMailPatch`): mails patch files, as
/// attachments or inline, one mail per patch or combined. TortoiseGit talks SMTP or MAPI; on macOS
/// the mail is composed in the default mail app (`NSSharingService.composeEmail` / `mailto:`), or
/// sent with `git send-email` using the repository's `sendemail.*` configuration.
@MainActor
public final class SendMailWindowController: NSWindowController {

    public let repositoryPath: PangolinPath?

    private let toField = NSTextField()
    private let ccField = NSTextField()
    private let subjectField = NSTextField()
    private let bodyView = NSTextView()
    private let fileList = PatchFileListView()
    private let attachmentCheck = NSButton(checkboxWithTitle: "Patch as attachment", target: nil, action: nil)
    private let combineCheck = NSButton(checkboxWithTitle: "Combine into one mail", target: nil, action: nil)
    private let deliveryPopup = NSPopUpButton()

    public init(repositoryPath: PangolinPath?, patches: [URL], subject: String = "", body: String = "") {
        self.repositoryPath = repositoryPath
        super.init(window: ToolDialog.window(title: "Send Mail", repository: repositoryPath, width: 720, height: 600))
        setupUI()
        fileList.setFiles(patches)
        subjectField.stringValue = subject
        bodyView.string = body
        updateState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func present(repository: PangolinPath?, patches: [URL], subject: String = "", body: String = "") {
        WindowRegistry.shared.present({ SendMailWindowController(repositoryPath: repository, patches: patches, subject: subject, body: body) },
                                      repository: repository)
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }
        let config = ConfigManager.shared
        toField.stringValue = config.sendMailTo
        ccField.stringValue = config.sendMailCC
        toField.placeholderString = "maintainer@example.com, list@example.org"
        ccField.placeholderString = "Optional"
        subjectField.placeholderString = "Subject of the combined mail (each separate mail uses its patch's subject)"
        attachmentCheck.state = config.sendMailAsAttachment ? .on : .off
        combineCheck.state = config.sendMailCombine ? .on : .off
        combineCheck.target = self
        combineCheck.action = #selector(optionChanged)
        attachmentCheck.target = self
        attachmentCheck.action = #selector(optionChanged)
        deliveryPopup.addItems(withTitles: ["Compose in Mail app", "Send with git send-email"])
        deliveryPopup.selectItem(at: min(config.sendMailDelivery, 1))
        deliveryPopup.target = self
        deliveryPopup.action = #selector(optionChanged)
        deliveryPopup.toolTip = "git send-email uses the SMTP settings in the sendemail.* git configuration"

        let grid = NSGridView(views: [
            [ToolDialog.label("To:"), toField],
            [ToolDialog.label("CC:"), ccField],
            [ToolDialog.label("Subject:"), subjectField]
        ])
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        toField.widthAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true

        bodyView.isRichText = false
        bodyView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        bodyView.isVerticallyResizable = true
        bodyView.autoresizingMask = [.width]
        let bodyScroll = NSScrollView()
        bodyScroll.hasVerticalScroller = true
        bodyScroll.borderType = .bezelBorder
        bodyScroll.documentView = bodyView
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false

        fileList.onOpen = { url in PatchViewerWindowController.present(url) }
        fileList.onChange = { [weak self] in self?.updateState() }

        let options = NSStackView(views: [attachmentCheck, combineCheck, deliveryPopup])
        options.spacing = 16

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let send = NSButton(title: "Send", target: self, action: #selector(sendClicked))
        send.keyEquivalent = "\r"
        let buttons = ToolDialog.buttonRow([cancel, send])

        let stack = NSStackView(views: [grid, ToolDialog.label("Message (text before the patches):"), bodyScroll,
                                        ToolDialog.label("Patches:"), fileList, options, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate(LayoutHelper.pinEdges(stack, to: content) + [
            bodyScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fileList.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            fileList.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
    }

    @objc private func optionChanged() {
        updateState()
    }

    private func updateState() {
        let viaGit = deliveryPopup.indexOfSelectedItem == 1
        attachmentCheck.isEnabled = !viaGit
        combineCheck.isEnabled = !viaGit && !fileList.files.isEmpty
        subjectField.isEnabled = fileList.files.isEmpty || combineCheck.state == .on || viaGit
    }

    @objc private func cancelClicked() {
        window?.close()
    }

    private func addresses(_ field: NSTextField) -> [String] {
        field.stringValue.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @objc private func sendClicked() {
        let to = addresses(toField)
        guard !to.isEmpty else {
            ToolDialog.showMessage("No recipient", "Enter at least one address in To.", in: window, style: .warning)
            return
        }
        let config = ConfigManager.shared
        config.sendMailTo = toField.stringValue
        config.sendMailCC = ccField.stringValue
        config.sendMailAsAttachment = attachmentCheck.state == .on
        config.sendMailCombine = combineCheck.state == .on
        config.sendMailDelivery = deliveryPopup.indexOfSelectedItem

        if deliveryPopup.indexOfSelectedItem == 1 {
            sendWithGit(to: to, cc: addresses(ccField))
        } else if composeInMailApp(to: to, cc: addresses(ccField)) {
            window?.close()
        }
    }

    /// `git send-email --confirm=never`; needs `sendemail.smtpServer` etc. in the git config.
    private func sendWithGit(to: [String], cc: [String]) {
        guard !fileList.files.isEmpty else {
            ToolDialog.showMessage("No patches", "git send-email sends patch files; add at least one.", in: window, style: .warning)
            return
        }
        var args = ["send-email", "--confirm=never"]
        args += to.map { "--to=\($0)" }
        args += cc.map { "--cc=\($0)" }
        let subject = subjectField.stringValue.trimmingCharacters(in: .whitespaces)
        if fileList.files.count > 1, !subject.isEmpty {
            args.append("--subject=\(subject)")
        }
        args.append("--")
        args += fileList.files.map(\.path)
        window?.close()
        ProgressWindowController.run(title: "Send Mail", commands: [args], workingDirectory: repositoryPath)
    }

    /// One compose window per patch, or one combined mail (TortoiseGit's *Combine one mail*).
    private func composeInMailApp(to: [String], cc: [String]) -> Bool {
        let intro = bodyView.string
        let asAttachment = attachmentCheck.state == .on
        let patches = fileList.files.map { url -> (url: URL, text: String) in
            (url, (try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }

        var mails: [(subject: String, body: String, attachments: [URL])] = []
        if patches.isEmpty || combineCheck.state == .on {
            let subject = subjectField.stringValue.isEmpty
                ? (patches.first.map { GitPatchSeries.mailHeader(of: $0.text).subject } ?? "")
                : subjectField.stringValue
            let inline = asAttachment ? "" : patches.map(\.text).joined(separator: "\n")
            mails.append((subject, [intro, inline].filter { !$0.isEmpty }.joined(separator: "\n\n"), asAttachment ? patches.map(\.url) : []))
        } else {
            for patch in patches {
                let header = GitPatchSeries.mailHeader(of: patch.text)
                let subject = header.subject.isEmpty ? patch.url.deletingPathExtension().lastPathComponent : header.subject
                let body = asAttachment ? intro : [intro, patch.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                mails.append((subject, body, asAttachment ? [patch.url] : []))
            }
        }

        for mail in mails {
            if mail.attachments.isEmpty, let url = Self.mailtoURL(to: to, cc: cc, subject: mail.subject, body: mail.body),
               url.absoluteString.count < 60_000 {
                NSWorkspace.shared.open(url)
                continue
            }
            guard let service = NSSharingService(named: .composeEmail) else {
                ToolDialog.showMessage("No mail app", "No mail app is set up to compose messages.", in: window, style: .warning)
                return false
            }
            // The compose service has no CC field; CC addresses are added as recipients.
            service.recipients = to + cc
            service.subject = mail.subject
            let items: [Any] = [mail.body as NSString] + mail.attachments.map { $0 as NSURL }
            guard service.canPerform(withItems: items) else {
                ToolDialog.showMessage("Cannot compose mail", "The mail app cannot create this message.", in: window, style: .warning)
                return false
            }
            service.perform(withItems: items)
        }
        return true
    }

    static func mailtoURL(to: [String], cc: [String], subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.joined(separator: ",")
        var query = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if !cc.isEmpty { query.append(URLQueryItem(name: "cc", value: cc.joined(separator: ","))) }
        components.queryItems = query
        return components.url
    }
}
