import Foundation

/// Log of the state-changing git commands PangolinGit ran, one line each with time, repository and
/// command line (TortoiseGit's action log, `%APPDATA%\TortoiseGit\logfile.txt`, shown and cleared from
/// Settings ▸ Saved Data). Stored in `~/Library/Logs/PangolinGit/action.log`.
public final class ActionLog: @unchecked Sendable {
    public static let shared = ActionLog()

    public let fileURL: URL
    private let queue = DispatchQueue(label: "be.macbit.pangolingit.actionlog")

    /// Lines kept when the file is trimmed (TortoiseGit's `MaxLinesInLogfile`, default 4000; 0 = off).
    public var maxLines: Int {
        ConfigManager.shared.advancedInt(.maxActionLogLines)
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PangolinGit/action.log")
    }

    /// Appends one entry; trims the file to `maxLines` now and then. Never throws or blocks the caller.
    public func record(repository: String, command: String, date: Date = Date()) {
        let limit = maxLines
        // Unit tests run many git commands; keep them out of the user's log.
        guard limit > 0, fileURL != Self.shared.fileURL || NSClassFromString("XCTestCase") == nil else { return }
        let stamp = Self.formatter.string(from: date)
        let line = "\(stamp)  \(repository)  \(command)\n"
        queue.async { [fileURL] in
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                let size = handle.offsetInFile
                try? handle.close()
                // Trim only when the file is clearly over the limit (~200 bytes a line).
                if size > UInt64(limit) * 300 { Self.trim(fileURL, to: limit) }
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    /// Current contents (empty when nothing was logged yet).
    public func contents() -> String {
        queue.sync { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }
    }

    public var lineCount: Int {
        contents().split(separator: "\n").count
    }

    public func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    static func trim(_ url: URL, to limit: Int) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > limit else { return }
        try? (lines.suffix(limit).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
