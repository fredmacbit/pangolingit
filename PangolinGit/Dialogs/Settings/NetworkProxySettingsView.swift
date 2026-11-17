import Cocoa
import PangolinGitCore

/// Settings pane for HTTP/HTTPS proxy and network SSL configuration (`SettingsNetwork.cpp` in TortoiseGit).
public final class NetworkProxySettingsViewController: NSViewController {
    
    private var httpProxyField: NSTextField!
    private var httpsProxyField: NSTextField!
    private var noProxyField: NSTextField!
    private var sslVerifyCheckbox: NSButton!
    
    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 380))
        setupUI()
        loadData()
    }
    
    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Network & Proxy Settings")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        
        let httpLabel = NSTextField(labelWithString: "HTTP Proxy (http://host:port):")
        httpLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(httpLabel)
        
        httpProxyField = NSTextField()
        httpProxyField.placeholderString = "http://proxy.example.com:8080"
        httpProxyField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(httpProxyField)
        
        let httpsLabel = NSTextField(labelWithString: "HTTPS Proxy (http://host:port):")
        httpsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(httpsLabel)
        
        httpsProxyField = NSTextField()
        httpsProxyField.placeholderString = "http://proxy.example.com:8080"
        httpsProxyField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(httpsProxyField)
        
        let noProxyLabel = NSTextField(labelWithString: "Bypass Proxy for Hosts (comma-separated):")
        noProxyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noProxyLabel)
        
        noProxyField = NSTextField()
        noProxyField.placeholderString = "localhost,127.0.0.1,.local"
        noProxyField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noProxyField)
        
        sslVerifyCheckbox = NSButton(checkboxWithTitle: "Verify SSL certificates (http.sslVerify)", target: self, action: #selector(settingChanged))
        sslVerifyCheckbox.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sslVerifyCheckbox)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            httpLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            httpLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            httpProxyField.topAnchor.constraint(equalTo: httpLabel.bottomAnchor, constant: 4),
            httpProxyField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            httpProxyField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            httpsLabel.topAnchor.constraint(equalTo: httpProxyField.bottomAnchor, constant: 14),
            httpsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            httpsProxyField.topAnchor.constraint(equalTo: httpsLabel.bottomAnchor, constant: 4),
            httpsProxyField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            httpsProxyField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            noProxyLabel.topAnchor.constraint(equalTo: httpsProxyField.bottomAnchor, constant: 14),
            noProxyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            
            noProxyField.topAnchor.constraint(equalTo: noProxyLabel.bottomAnchor, constant: 4),
            noProxyField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            noProxyField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            sslVerifyCheckbox.topAnchor.constraint(equalTo: noProxyField.bottomAnchor, constant: 16),
            sslVerifyCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20)
        ])
        setupGitConfigSection(below: sslVerifyCheckbox)
    }

    // MARK: - Global git config (DA-03)

    private let gitConfigLabel = NSTextField(wrappingLabelWithString: "")

    /// PangolinGit passes these settings to every git it runs. TortoiseGit also writes them to git's
    /// own configuration so git in Terminal and other tools use the same proxy; offer that here.
    private func setupGitConfigSection(below anchor: NSView) {
        let note = NSTextField(wrappingLabelWithString: "These settings apply to every git command PangolinGit runs. To use them in Terminal and other Git tools too, write them to the global Git configuration.")
        note.textColor = .secondaryLabelColor
        let writeButton = NSButton(title: "Write to Global Git Config (~/.gitconfig)", target: self, action: #selector(writeToGitConfig))
        writeButton.bezelStyle = .rounded
        gitConfigLabel.textColor = .secondaryLabelColor
        gitConfigLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [note, writeButton, gitConfigLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: anchor.bottomAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            gitConfigLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        showGitConfig()
    }

    private func showGitConfig() {
        Task { @MainActor in
            let proxy = try? await GitCLIRunner.runAsync(arguments: ["config", "--global", "--get", "http.proxy"])
            let verify = try? await GitCLIRunner.runAsync(arguments: ["config", "--global", "--get", "http.sslVerify"])
            let trim = { (value: String?) in value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            self.gitConfigLabel.stringValue = "Global git config now: http.proxy = \(trim(proxy).isEmpty ? "(not set)" : trim(proxy)), " +
                "http.sslVerify = \(trim(verify).isEmpty ? "(not set)" : trim(verify))"
        }
    }

    /// git has one `http.proxy` for both schemes; the HTTPS proxy wins because most remotes use HTTPS.
    /// git has no bypass list setting (it reads `no_proxy` from the environment only).
    @objc private func writeToGitConfig() {
        save()
        let config = ConfigManager.shared
        let proxy = config.httpsProxy.isEmpty ? config.httpProxy : config.httpsProxy
        let commands: [[String]] = [
            proxy.isEmpty ? ["config", "--global", "--unset", "http.proxy"] : ["config", "--global", "http.proxy", proxy],
            config.sslVerify ? ["config", "--global", "--unset", "http.sslVerify"] : ["config", "--global", "http.sslVerify", "false"],
        ]
        Task { @MainActor in
            for arguments in commands {
                _ = try? await GitCLIRunner().run(arguments: arguments)
            }
            self.showGitConfig()
        }
    }
    
    public func loadData() {
        let config = ConfigManager.shared
        httpProxyField.stringValue = config.httpProxy
        httpsProxyField.stringValue = config.httpsProxy
        noProxyField.stringValue = config.noProxy
        sslVerifyCheckbox.state = config.sslVerify ? .on : .off
    }
    
    public func save() {
        let config = ConfigManager.shared
        config.httpProxy = httpProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.httpsProxy = httpsProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.noProxy = noProxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.sslVerify = (sslVerifyCheckbox.state == .on)
    }
    
    @objc private func settingChanged() {
        save()
    }
}
