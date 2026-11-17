import Foundation

/// Helpers for patch series: `git format-patch` (TortoiseGit's `FormatPatchCommand.cpp`),
/// `git am` (`ImportPatchDlg.cpp`) and mailing patches (`SendMailDlg.cpp`).
public enum GitPatchSeries {

    /// The three range modes of TortoiseGit's *Create Patch Serial* dialog.
    public enum Range: Equatable, Sendable {
        /// Every commit after `ref` up to HEAD (`git format-patch <ref>`).
        case since(String)
        /// The last `count` commits of HEAD (`git format-patch -<count>`).
        case last(Int)
        /// `from..to`.
        case between(from: String, to: String)
    }

    /// Arguments for `git format-patch`, mirroring `FormatPatchCommand.cpp`.
    public static func formatPatchArguments(range: Range, outputDirectory: String, noPrefix: Bool,
                                            binary: Bool = true) -> [String] {
        var args = ["format-patch"]
        if noPrefix { args.append("--no-prefix") }
        if binary { args.append("--binary") }
        args += ["-o", outputDirectory]
        switch range {
        case .since(let ref):
            args += ["--end-of-options", ref]
        case .last(let count):
            args.append("-\(max(1, count))")
        case .between(let from, let to):
            args += ["--end-of-options", "\(from)..\(to)"]
        }
        args.append("--")
        return args
    }

    /// `git format-patch -o` prints the path of each file it wrote, one per line.
    public static func writtenFiles(fromFormatPatchOutput output: String) -> [String] {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix(".patch") }
    }

    /// Arguments for `git am`, in the order TortoiseGit builds them (`ImportPatchDlg.cpp`).
    public static func amArguments(files: [String], threeWay: Bool, ignoreSpaceChange: Bool,
                                   signOff: Bool, keepCR: Bool) -> [String] {
        var args = ["am"]
        if signOff { args.append("--signoff") }
        if threeWay { args.append("--3way") }
        if ignoreSpaceChange { args.append("--ignore-space-change") }
        if keepCR { args.append("--keep-cr") }
        args.append("--")
        return args + files
    }

    /// True when `content` is an mbox patch from `git format-patch` (applied with `git am`)
    /// rather than a plain diff (applied with `git apply`).
    public static func isMailboxPatch(_ content: String) -> Bool {
        guard content.hasPrefix("From ") else { return false }
        let firstLine = content.prefix { $0 != "\n" }
        let token = firstLine.dropFirst(5).prefix { $0 != " " }
        return (token.count == 40 || token.count == 64) && token.allSatisfy(\.isHexDigit)
    }

    /// Mail headers of a format-patch file.
    public struct MailHeader: Equatable, Sendable {
        public var from: String = ""
        public var subject: String = ""
        public var date: String = ""

        /// Subject without the `[PATCH n/m]` prefix.
        public var strippedSubject: String {
            guard subject.hasPrefix("["), let close = subject.firstIndex(of: "]") else { return subject }
            return subject[subject.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
    }

    /// Reads From / Subject / Date from the header block (up to the first blank line), unfolding
    /// continuation lines and decoding RFC 2047 encoded words, as format-patch writes non-ASCII subjects.
    public static func mailHeader(of content: String) -> MailHeader {
        var header = MailHeader()
        var unfolded: [String] = []
        for line in content.components(separatedBy: "\n") {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if line.isEmpty { break }
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += line
            } else {
                unfolded.append(line)
            }
        }
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = decodeEncodedWords(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            switch name {
            case "from": header.from = value
            case "subject": header.subject = value
            case "date": header.date = value
            default: break
            }
        }
        return header
    }

    /// Decodes `=?charset?Q?...?=` / `=?charset?B?...?=` words (RFC 2047). Whitespace between two
    /// adjacent encoded words is dropped, as the RFC requires.
    public static func decodeEncodedWords(_ text: String) -> String {
        let pattern = #"=\?([^?]+)\?([QqBb])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        var previousWasEncoded = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !(previousWasEncoded && between.trimmingCharacters(in: .whitespaces).isEmpty) {
                result += between
            }
            let charset = ns.substring(with: match.range(at: 1))
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            if let decoded = decodeWord(payload, mode: mode, charset: charset) {
                result += decoded
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
            previousWasEncoded = true
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func decodeWord(_ payload: String, mode: String, charset: String) -> String? {
        let encoding: String.Encoding
        switch charset.lowercased() {
        case "utf-8", "utf8": encoding = .utf8
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "us-ascii": encoding = .ascii
        default: encoding = .utf8
        }
        if mode == "B" {
            guard let data = Data(base64Encoded: payload) else { return nil }
            return String(data: data, encoding: encoding)
        }
        var bytes: [UInt8] = []
        var chars = Array(payload.utf8)[...]
        while let byte = chars.popFirst() {
            if byte == UInt8(ascii: "_") {
                bytes.append(0x20)
            } else if byte == UInt8(ascii: "="), chars.count >= 2,
                      let value = UInt8(String(decoding: chars.prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(value)
                chars = chars.dropFirst(2)
            } else {
                bytes.append(byte)
            }
        }
        return String(data: Data(bytes), encoding: encoding)
    }
}

/// One entry of `git worktree list --porcelain` (TortoiseGit's `WorktreeListDlg` columns).
public struct GitWorktreeInfo: Equatable, Sendable {
    public var path: String = ""
    public var head: String = ""
    /// Short branch name; nil when detached or bare.
    public var branch: String?
    public var isBare = false
    public var isDetached = false
    public var isLocked = false
    public var lockReason = ""
    public var isPrunable = false
    public var prunableReason = ""
    /// The first entry is the main working tree.
    public var isMain = false

    public init() {}

    public static func parse(porcelain output: String) -> [GitWorktreeInfo] {
        var items: [GitWorktreeInfo] = []
        var current: GitWorktreeInfo?
        func flush() {
            if var item = current, !item.path.isEmpty {
                item.isMain = items.isEmpty
                items.append(item)
            }
            current = nil
        }
        for line in output.components(separatedBy: "\n") {
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("worktree ") {
                flush()
                current = GitWorktreeInfo()
                current?.path = String(line.dropFirst("worktree ".count))
                continue
            }
            guard current != nil else { continue }
            let (key, value) = split(line)
            switch key {
            case "HEAD": current?.head = value
            case "branch": current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
            case "bare": current?.isBare = true
            case "detached": current?.isDetached = true
            case "locked":
                current?.isLocked = true
                current?.lockReason = value
            case "prunable":
                current?.isPrunable = true
                current?.prunableReason = value
            default: break
            }
        }
        flush()
        return items
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}
