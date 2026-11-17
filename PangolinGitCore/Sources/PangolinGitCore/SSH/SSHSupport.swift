import Foundation

/// Helpers for the SSH key window (the macOS counterpart of TortoiseGit's PuTTYgen / Pageant
/// integration): key types, key generation without exposing the passphrase, known_hosts parsing.
public enum SSHSupport {

    public enum KeyType: String, CaseIterable, Sendable {
        case ed25519, ecdsa, rsa

        public var title: String {
            switch self {
            case .ed25519: return "Ed25519 (recommended)"
            case .ecdsa: return "ECDSA"
            case .rsa: return "RSA"
            }
        }

        /// Selectable sizes; the first is the default. Ed25519 has a fixed size.
        public var bitSizes: [Int] {
            switch self {
            case .ed25519: return []
            case .ecdsa: return [256, 384, 521]
            case .rsa: return [4096, 3072, 2048]
            }
        }

        public var defaultFileName: String { "id_\(rawValue)" }
    }

    /// `ssh-keygen` arguments for a new key. There is deliberately no `-N`: the passphrase is
    /// answered through `SSH_ASKPASS` (see `askPassEnvironment`) so it never appears in the process list.
    public static func keygenArguments(type: KeyType, bits: Int?, comment: String, path: String) -> [String] {
        var arguments = ["-q", "-t", type.rawValue]
        if let bits, type != .ed25519 { arguments += ["-b", String(bits)] }
        arguments += ["-C", comment, "-f", path]
        return arguments
    }

    /// Writes an askpass helper that answers the first `answers` prompts with `secret` and then an
    /// empty line (so a wrong passphrase makes ssh-add give up instead of asking forever), returning
    /// the environment that makes ssh-keygen / ssh-add use it (`SSH_ASKPASS_REQUIRE=force`, OpenSSH ≥ 8.4)
    /// and the folder to delete afterwards. The secret lives in 0600 files in a 0700 folder.
    /// ssh-keygen asks twice for a new key (enter + confirm), ssh-add and `ssh-keygen -y` once.
    public static func askPassEnvironment(secret: String, answers: Int = 2) throws -> (environment: [String: String], cleanup: URL) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("pangolin-ssh-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for index in 1...max(1, answers) {
            fm.createFile(atPath: folder.appendingPathComponent("answer\(index)").path, contents: Data(secret.utf8),
                          attributes: [.posixPermissions: 0o600])
        }
        let script = folder.appendingPathComponent("askpass.sh")
        let body = "#!/bin/sh\nfor f in '\(folder.path)'/answer*; do [ -f \"$f\" ] || break; /bin/cat \"$f\"; /bin/rm -f \"$f\"; exit 0; done\nexit 0\n"
        fm.createFile(atPath: script.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700])
        let environment = [
            "SSH_ASKPASS": script.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0"
        ]
        return (environment, folder)
    }

    /// One `~/.ssh/known_hosts` entry.
    public struct KnownHost: Equatable, Sendable {
        /// Host patterns as written (`github.com,140.82.112.3`, `[host]:2222`); hashed entries start with `|1|`.
        public let hosts: String
        public let keyType: String
        public let lineNumber: Int

        public var isHashed: Bool { hosts.hasPrefix("|1|") }
        /// First host name usable with `ssh-keygen -R`, nil for hashed entries.
        public var primaryHost: String? {
            isHashed ? nil : hosts.split(separator: ",").first.map(String.init)
        }
    }

    /// Parses known_hosts (comments, blank lines and `@cert-authority` / `@revoked` markers handled).
    public static func parseKnownHosts(_ text: String) -> [KnownHost] {
        var result: [KnownHost] = []
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if fields.first?.hasPrefix("@") == true { fields.removeFirst() }
            guard fields.count >= 3 else { continue }
            result.append(KnownHost(hosts: fields[0], keyType: fields[1], lineNumber: index + 1))
        }
        return result
    }

    /// `ssh -i <key> -o IdentitiesOnly=yes`, the `core.sshCommand` that pins a repository to one key
    /// (TortoiseGit's per-remote "PuTTY key").
    public static func sshCommand(forKey path: String) -> String {
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        return "ssh -i \(quoted) -o IdentitiesOnly=yes"
    }

    /// The key file named in a `core.sshCommand` built by `sshCommand(forKey:)`, if any.
    public static func keyPath(fromSSHCommand command: String) -> String? {
        guard let range = command.range(of: "-i ") else { return nil }
        let rest = command[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") {
            return rest.dropFirst().split(separator: "\"", maxSplits: 1).first.map(String.init)
        }
        return rest.split(separator: " ").first.map(String.init)
    }
}
