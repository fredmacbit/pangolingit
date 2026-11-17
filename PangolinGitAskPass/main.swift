import AppKit
import PangolinGitCore

/// `pangolin-askpass` — GIT_ASKPASS / SSH_ASKPASS helper (TortoiseGit's `SshAskPass.exe`) and git
/// credential helper.
///
/// - As askpass, git/ssh run it with the prompt as argv[1]; it shows a dialog and prints the answer
///   to stdout. Exit status 1 means the user cancelled, which makes git abort the operation cleanly.
/// - As a credential helper (`pangolin-askpass get|store|erase`, appended to `credential.helper` by
///   PangolinGit) it asks for username and password in one form and can remember them in the
///   Keychain; git calls `erase` when the server rejects them, so a wrong password never sticks.

let arguments = Array(CommandLine.arguments.dropFirst())

/// Shows the app's icon rather than a generic one (the tool lives in PangolinGit.app/Contents/MacOS).
func makeAlert() -> NSAlert {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    let appBundle = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if let appBundle, appBundle.pathExtension == "app" {
        alert.icon = NSWorkspace.shared.icon(forFile: appBundle.path)
    }
    return alert
}

/// A label + field row for the login form.
func row(_ title: String, _ field: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: title)
    label.alignment = .right
    label.widthAnchor.constraint(equalToConstant: 80).isActive = true
    field.widthAnchor.constraint(equalToConstant: 240).isActive = true
    let stack = NSStackView(views: [label, field])
    stack.orientation = .horizontal
    stack.spacing = 8
    return stack
}

// MARK: - Credential helper mode

func runCredentialHelper(action: String) -> Never {
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    var request = GitCredentialRequest.parse(input)
    let location = request.location

    switch action {
    case "erase":
        GitCredentialStore.erase(location: location, username: request.username)
        exit(0)
    case "store":
        // Keep a remembered login current when another helper supplied a newer password.
        if let username = request.username, let password = request.password,
           let saved = GitCredentialStore.lookup(location: location, username: username), saved.password != password {
            GitCredentialStore.save(username: username, password: password, location: location)
        }
        exit(0)
    default:
        break
    }

    // get: an earlier helper may already have answered.
    if request.username != nil, request.password != nil { exit(0) }
    if let saved = GitCredentialStore.lookup(location: location, username: request.username) {
        request["username"] = saved.username
        request["password"] = saved.password
        print(request.serialized(), terminator: "")
        exit(0)
    }

    let alert = makeAlert()
    alert.messageText = "Log in to \(request.host)"
    alert.informativeText = "Git needs a username and password (or personal access token) for\n\(location)"
    let userField = NSTextField()
    userField.stringValue = request.username ?? ""
    userField.placeholderString = "Username"
    let passwordField = NSSecureTextField()
    passwordField.placeholderString = "Password or token"
    let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
    remember.state = .on
    let form = NSStackView(views: [row("Username:", userField), row("Password:", passwordField), remember])
    form.orientation = .vertical
    form.alignment = .leading
    form.spacing = 8
    form.frame = NSRect(x: 0, y: 0, width: 330, height: 86)
    alert.accessoryView = form
    alert.addButton(withTitle: "Log In")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = (request.username == nil) ? userField : passwordField

    guard alert.runModal() == .alertFirstButtonReturn, !userField.stringValue.isEmpty else {
        // `quit` stops git from falling back to separate username/password prompts.
        print("quit=1\n")
        exit(0)
    }
    request["username"] = userField.stringValue
    request["password"] = passwordField.stringValue
    if remember.state == .on {
        GitCredentialStore.save(username: userField.stringValue, password: passwordField.stringValue, location: location)
    }
    print(request.serialized(), terminator: "")
    exit(0)
}

if arguments.count == 1, AskPassHelper.credentialActions.contains(arguments[0]) {
    runCredentialHelper(action: arguments[0])
}

// MARK: - Askpass mode

let prompt = arguments.joined(separator: " ")
let kind = AskPassHelper.classify(prompt: prompt)
let alert = makeAlert()
let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

var field: NSTextField?
switch kind {
case .confirmation:
    if let hostKey = AskPassHelper.parseHostKeyPrompt(prompt) {
        // Put the fingerprint where it can be compared at a glance with the one the host publishes.
        alert.messageText = hostKey.changed ? "The host key of \(hostKey.host) has CHANGED" : "Unknown host \(hostKey.host)"
        alert.alertStyle = hostKey.changed ? .critical : .warning
        alert.informativeText = "Compare this \(hostKey.keyType) key fingerprint with the one published by the server before connecting:"
        let fingerprint = NSTextField(wrappingLabelWithString: hostKey.fingerprint)
        fingerprint.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        fingerprint.isSelectable = true
        let details = NSTextField(wrappingLabelWithString: trimmedPrompt)
        details.font = .systemFont(ofSize: 10)
        details.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [fingerprint, details])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        fingerprint.preferredMaxLayoutWidth = 320
        details.preferredMaxLayoutWidth = 320
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 330, height: stack.fittingSize.height))
        alert.accessoryView = stack
    } else {
        alert.messageText = "Confirm Connection"
        alert.informativeText = trimmedPrompt
    }
    alert.addButton(withTitle: "Connect")
    alert.addButton(withTitle: "Cancel")
case .username:
    alert.messageText = "PangolinGit Authentication"
    alert.informativeText = trimmedPrompt
    field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
case .password, .passphrase:
    alert.messageText = kind == .passphrase ? "SSH Key Passphrase" : "PangolinGit Authentication"
    alert.informativeText = trimmedPrompt
    field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
}
if let field {
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
}

guard alert.runModal() == .alertFirstButtonReturn else {
    exit(1)
}
print(kind == .confirmation ? "yes" : (field?.stringValue ?? ""))
exit(0)
