import Foundation
import Security

/// One request/response of git's credential-helper protocol (`git help credential`): `key=value`
/// lines such as `protocol=https`, `host=github.com`, `username=…`, `password=…`.
public struct GitCredentialRequest: Equatable, Sendable {
    public var fields: [(key: String, value: String)]

    public init(fields: [(key: String, value: String)] = []) {
        self.fields = fields
    }

    public static func == (lhs: GitCredentialRequest, rhs: GitCredentialRequest) -> Bool {
        lhs.fields.map(\.key) == rhs.fields.map(\.key) && lhs.fields.map(\.value) == rhs.fields.map(\.value)
    }

    /// Parses helper input; stops at the first blank line like git does.
    public static func parse(_ text: String) -> GitCredentialRequest {
        var fields: [(String, String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.hasSuffix("\r") ? line.dropLast() : line
            if trimmed.isEmpty { break }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            fields.append((String(trimmed[..<eq]), String(trimmed[trimmed.index(after: eq)...])))
        }
        return GitCredentialRequest(fields: fields)
    }

    public subscript(key: String) -> String? {
        get { fields.last { $0.key == key }?.value }
        set {
            fields.removeAll { $0.key == key }
            if let newValue { fields.append((key, newValue)) }
        }
    }

    public var protocolName: String { self["protocol"] ?? "https" }
    public var host: String { self["host"] ?? "" }
    public var path: String? { self["path"] }
    public var username: String? { self["username"].flatMap { $0.isEmpty ? nil : $0 } }
    public var password: String? { self["password"] }

    /// `https://github.com` (plus `/path` when git sends one, i.e. `credential.useHttpPath`).
    public var location: String {
        var text = "\(protocolName)://\(host)"
        if let path, !path.isEmpty { text += "/" + path }
        return text
    }

    /// Helper output: `key=value` lines followed by a blank line.
    public func serialized() -> String {
        fields.map { "\($0.key)=\($0.value)\n" }.joined() + "\n"
    }
}

/// Logins remembered by PangolinGit's own credential prompt, kept in the login Keychain
/// (the macOS counterpart of TortoiseGit's credential manager integration). Each item's account is
/// `<username>@<location>` so several users per host can coexist.
public enum GitCredentialStore {

    public static let service = "be.macbit.pangolingit.credential"

    public struct Login: Equatable, Sendable {
        public let username: String
        public let location: String
    }

    static func account(username: String, location: String) -> String {
        "\(username)@\(location)"
    }

    /// Splits an account back into username and location (`user@x@https://host` keeps the `@`s of the username).
    static func parseAccount(_ account: String) -> Login? {
        guard let range = account.range(of: "@", options: .backwards, range: account.startIndex..<(account.range(of: "://")?.lowerBound ?? account.endIndex)) else { return nil }
        let username = String(account[..<range.lowerBound])
        let location = String(account[range.upperBound...])
        return username.isEmpty || location.isEmpty ? nil : Login(username: username, location: location)
    }

    /// Every login saved by PangolinGit.
    public static func allLogins() -> [Login] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(parseAccount) }
    }

    /// The saved login for a location; with no username given, the first one saved for it.
    public static func lookup(location: String, username: String?) -> (username: String, password: String)? {
        let candidates = allLogins().filter { $0.location == location && (username == nil || $0.username == username) }
        for login in candidates {
            if let password = password(account: account(username: login.username, location: location)) {
                return (login.username, password)
            }
        }
        return nil
    }

    private static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var data: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(username: String, password: String, location: String) -> Bool {
        let accountName = account(username: username, location: location)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "PangolinGit: \(location)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the saved login(s) for a location (git calls `erase` after a rejected password).
    public static func erase(location: String, username: String?) {
        for login in allLogins() where login.location == location && (username == nil || login.username == username) {
            delete(account: account(username: login.username, location: location))
        }
    }

    /// Removes every login PangolinGit saved (Settings ▸ Credentials ▸ Forget).
    @discardableResult
    public static func eraseAll() -> Int {
        let logins = allLogins()
        for login in logins {
            delete(account: account(username: login.username, location: login.location))
        }
        return logins.count
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
