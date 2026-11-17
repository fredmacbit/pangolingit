import Foundation
import Cocoa
import PangolinGitCore

/// Controller for exporting clean repository snapshots without .git metadata (`ExportDlg.cpp` in TortoiseGit).
/// Exports the whole project or only the items selected in Finder (`git archive <rev> <paths>`), at
/// any revision (also opened with a preset revision from the Revision Graph), and asks before overwriting.
public final class ExportWindowController: NSWindowController {
    
    public enum ExportFormat: Int {
        case directory = 0
        case zip = 1
        case tarGz = 2
    }
    
    public let repositoryPath: PangolinPath
    
    private var refChooser: RevisionChooserView!
    private var destField: NSTextField!
    private var formatSegment: NSSegmentedControl!
    private var prefixField: NSTextField!
    private var statusLabel: NSTextField!
    private var selectionCheck: NSButton!
    /// Repository-relative paths chosen in Finder; empty = whole project.
    private let paths: [String]
    private let initialRevision: String

    /// - Parameters:
    ///   - revision: preselected version (e.g. *Export this version…* from the Log or Revision Graph).
    ///   - paths: repository-relative items to export instead of the whole project.
    public init(repositoryPath: PangolinPath, revision: String = "HEAD", paths: [String] = []) {
        self.repositoryPath = repositoryPath
        self.paths = paths.filter { !$0.isEmpty }
        self.initialRevision = revision

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Export — \(repositoryPath.url.lastPathComponent)"
        
        super.init(window: window)
        setupUI()
    }
    
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = self.window else { return }
        
        let container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        
        // Revision / Branch
        let refLbl = NSTextField(labelWithString: "Export Version:")
        refLbl.frame = NSRect(x: 25, y: 485, width: 250, height: 20)
        container.addSubview(refLbl)
        
        refChooser = RevisionChooserView(repository: repositoryPath, initialRevision: initialRevision)
        container.addSubview(refChooser)
        NSLayoutConstraint.activate([
            refChooser.topAnchor.constraint(equalTo: container.topAnchor, constant: 42),
            refChooser.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 37),
            refChooser.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -25)
        ])
        
        // Whole project vs. the Finder selection (TortoiseGit exports the clicked folder).
        selectionCheck = NSButton(checkboxWithTitle: "Only the selected items", target: nil, action: nil)
        selectionCheck.frame = NSRect(x: 25, y: 290, width: 570, height: 20)
        if paths.isEmpty {
            selectionCheck.title = "Whole project"
            selectionCheck.state = .on
            selectionCheck.isEnabled = false
        } else {
            selectionCheck.title = "Only the selected items: " + self.paths.joined(separator: ", ")
            selectionCheck.state = .on
            selectionCheck.lineBreakMode = .byTruncatingMiddle
        }
        container.addSubview(selectionCheck)

        // Format
        let fmtLbl = NSTextField(labelWithString: "Export Format:")
        fmtLbl.frame = NSRect(x: 25, y: 255, width: 250, height: 20)
        container.addSubview(fmtLbl)
        
        formatSegment = NSSegmentedControl(labels: ["Directory", "Zip Archive (.zip)", "Tarball (.tar.gz)"], trackingMode: .selectOne, target: self, action: #selector(formatChanged))
        formatSegment.frame = NSRect(x: 25, y: 225, width: 440, height: 28)
        formatSegment.selectedSegment = 1
        container.addSubview(formatSegment)
        
        // Destination
        let destLbl = NSTextField(labelWithString: "Destination Path:")
        destLbl.frame = NSRect(x: 25, y: 185, width: 250, height: 20)
        container.addSubview(destLbl)
        
        destField = NSTextField(frame: NSRect(x: 25, y: 155, width: 440, height: 24))
        destField.placeholderString = "Select destination file or directory..."
        container.addSubview(destField)
        
        let browseBtn = NSButton(title: "Browse...", target: self, action: #selector(browseClicked))
        browseBtn.frame = NSRect(x: 475, y: 153, width: 110, height: 28)
        browseBtn.bezelStyle = .rounded
        container.addSubview(browseBtn)
        
        // Root Prefix
        let prefixLbl = NSTextField(labelWithString: "Archive Root Directory Prefix (optional):")
        prefixLbl.frame = NSRect(x: 25, y: 115, width: 350, height: 20)
        container.addSubview(prefixLbl)
        
        prefixField = NSTextField(frame: NSRect(x: 25, y: 85, width: 440, height: 24))
        prefixField.placeholderString = "\(repositoryPath.url.lastPathComponent)/"
        container.addSubview(prefixField)
        
        // Bottom controls
        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.frame = NSRect(x: 25, y: 22, width: 350, height: 20)
        statusLabel.textColor = .secondaryLabelColor
        container.addSubview(statusLabel)
        
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelBtn.frame = NSRect(x: 390, y: 18, width: 95, height: 28)
        cancelBtn.bezelStyle = .rounded
        container.addSubview(cancelBtn)
        
        let exportBtn = NSButton(title: "Export", target: self, action: #selector(exportClicked))
        exportBtn.frame = NSRect(x: 495, y: 18, width: 95, height: 28)
        exportBtn.bezelStyle = .rounded
        exportBtn.keyEquivalent = "\r"
        container.addSubview(exportBtn)
    }
    
    @objc private func formatChanged() {
        destField.stringValue = ""
    }
    
    @objc private func browseClicked() {
        if formatSegment.selectedSegment == 0 {
            let panel = NSOpenPanel()
            panel.title = "Select Export Destination Directory"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destField.stringValue = url.path
        } else {
            let panel = NSSavePanel()
            panel.title = "Save Export Archive"
            let ext = formatSegment.selectedSegment == 1 ? "zip" : "tar.gz"
            panel.nameFieldStringValue = "\(repositoryPath.url.lastPathComponent)-\(refChooser.revision.replacingOccurrences(of: "/", with: "-")).\(ext)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destField.stringValue = url.path
        }
    }
    
    @objc private func cancelClicked() {
        window?.close()
    }
    
    /// TortoiseGit asks before replacing an archive or writing into a folder that has content.
    private func confirmOverwrite(_ destination: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination, isDirectory: &isDirectory) else { return true }
        if isDirectory.boolValue {
            let contents = (try? fm.contentsOfDirectory(atPath: destination)) ?? []
            guard !contents.isEmpty else { return true }
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isDirectory.boolValue ? "The folder is not empty" : "The file already exists"
        alert.informativeText = isDirectory.boolValue
            ? "Exported files overwrite files with the same name in “\(destination)”."
            : "“\(destination)” will be replaced."
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func exportClicked() {
        let destination = destField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = refChooser.revision
        guard !destination.isEmpty && !ref.isEmpty else {
            browseClicked()
            return
        }
        
        guard confirmOverwrite(destination) else { return }
        let pathspec = (selectionCheck.state == .on) ? paths : []
        statusLabel.stringValue = "Exporting repository snapshot..."
        
        Task {
            do {
                var args = ["archive"]
                let prefix = prefixField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    args.append("--prefix=\(prefix)")
                }
                
                if formatSegment.selectedSegment == 1 {
                    args += ["--format=zip", "--output=\(destination)", ref] + pathspec
                    _ = try await GitCLIRunner.runAsync(arguments: args, workingDirectory: repositoryPath)
                } else if formatSegment.selectedSegment == 2 {
                    args += ["--format=tar.gz", "--output=\(destination)", ref] + pathspec
                    _ = try await GitCLIRunner.runAsync(arguments: args, workingDirectory: repositoryPath)
                } else {
                    // Directory export
                    let tarPath = destination + "/.export.tar"
                    try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
                    args += ["--format=tar", "--output=\(tarPath)", ref] + pathspec
                    _ = try await GitCLIRunner.runAsync(arguments: args, workingDirectory: repositoryPath)
                    
                    // Unpack off the main thread; large trees take a while.
                    let status = try await Task.detached {
                        let untarProc = Process()
                        untarProc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                        untarProc.arguments = ["-xf", tarPath, "-C", destination]
                        try untarProc.run()
                        untarProc.waitUntilExit()
                        try? FileManager.default.removeItem(atPath: tarPath)
                        return untarProc.terminationStatus
                    }.value
                    guard status == 0 else {
                        throw GitCLIError.processCrash("tar exited with status \(status) while unpacking the export")
                    }
                }
                
                await MainActor.run {
                    self.statusLabel.stringValue = "Export completed successfully!"
                    let alert = NSAlert()
                    alert.messageText = "Export Complete"
                    alert.informativeText = "Repository exported to:\n\(destination)"
                    alert.runModal()
                    self.window?.close()
                }
            } catch {
                await MainActor.run {
                    self.statusLabel.stringValue = "Export error: \(error.localizedDescription)"
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
}
