import Foundation

/// Parameters of an automation request beyond the command and its paths — the macOS form of
/// `TortoiseGitProc.exe /command:log /path:… /rev:… /closeonend:2` (`src/TortoiseProc/CmdLineParser.cpp`).
///
/// Requests arrive as `pangolingit://<command>?path=…&rev=…` URLs; the `pangolin` command-line shim
/// builds those URLs from `pangolin <command> [paths…] [--key value]` or TortoiseGitProc-style
/// `/command:x /key:value` arguments. Dialogs may read the values they understand; unknown keys are kept.
public struct CommandOptions: Equatable, Sendable {
    public var paths: [String] = []
    /// Lower-cased keys; flags without a value are stored as "true".
    public var values: [String: String] = [:]

    public init(paths: [String] = [], values: [String: String] = [:]) {
        self.paths = paths
        self.values = values
    }

    /// Keys whose values are file paths; the CLI shim makes them absolute.
    public static let pathKeys: Set<String> = [
        "path", "path2", "base", "mine", "theirs", "merged", "left", "right", "result", "overlay",
        "patchfile", "patchpath", "logmsgfile", "savepath", "outfile", "output", "exactpath", "pathfile"
    ]

    /// Reads `path` items as paths and every other query item as a value.
    public init(url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for item in items {
            let key = item.name.lowercased()
            if key == "path" {
                if let value = item.value, !value.isEmpty { paths.append(value) }
            } else {
                values[key] = item.value ?? "true"
            }
        }
    }

    /// `pangolingit://<command>?path=…&key=value`.
    public func url(command: String) -> URL? {
        var components = URLComponents()
        components.scheme = "pangolingit"
        components.host = command
        var items = paths.map { URLQueryItem(name: "path", value: $0) }
        items += values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    // MARK: - Typed accessors (names as in TortoiseGitProc)

    public func string(_ key: String) -> String? {
        values[key.lowercased()].flatMap { $0.isEmpty ? nil : $0 }
    }

    public func bool(_ key: String) -> Bool {
        guard let value = values[key.lowercased()] else { return false }
        return !["0", "false", "no", "off"].contains(value.lowercased())
    }

    public func int(_ key: String) -> Int? {
        string(key).flatMap { Int($0) }
    }

    public var revision: String? { string("rev") ?? string("revision") }
    public var startRevision: String? { string("startrev") ?? string("revision1") }
    public var endRevision: String? { string("endrev") ?? string("revision2") }
    public var range: String? { string("range") }
    public var line: Int? { int("line") }
    public var page: String? { string("page") }
    /// `/closeonend:0…2` — overrides the progress window's auto-close mode for this request.
    public var closeOnEnd: Int? { int("closeonend") }

    /// `/logmsg`, or the contents of `/logmsgfile`.
    public var logMessage: String? {
        if let message = string("logmsg") { return message }
        guard let file = string("logmsgfile") else { return nil }
        return try? String(contentsOfFile: file, encoding: .utf8)
    }

    // MARK: - Command line

    /// Parses the shim's arguments (without the program name) into a command and options.
    /// `pangolin log . --rev abc --limit=20 --unified`, or `pangolin /command:log /path:. /rev:abc`.
    public static func parseCommandLine(_ arguments: [String], currentDirectory: String) -> (command: String, options: CommandOptions)? {
        var command: String?
        var options = CommandOptions()
        var index = 0
        func absolute(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : URL(fileURLWithPath: currentDirectory).appendingPathComponent(expanded)
            return url.standardizedFileURL.path
        }
        func store(_ key: String, _ value: String) {
            let key = key.lowercased()
            if key == "command" {
                command = value.lowercased()
            } else if key == "path" {
                // TortoiseGitProc joins several paths with '*'.
                options.paths += value.split(separator: "*").map { absolute(String($0)) }
            } else {
                options.values[key] = pathKeys.contains(key) ? absolute(value) : value
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument.hasPrefix("--"), argument.count > 2 {
                let body = String(argument.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    store(String(body[..<equals]), String(body[body.index(after: equals)...]))
                } else if index < arguments.count, !arguments[index].hasPrefix("--") {
                    store(body, arguments[index])
                    index += 1
                } else {
                    store(body, "true")
                }
            } else if argument.hasPrefix("/"), let colon = argument.firstIndex(of: ":"),
                      !argument.dropFirst().prefix(while: { $0 != ":" }).contains("/") {
                // TortoiseGitProc style: /key:value (a bare absolute path has a '/' before any ':').
                store(String(argument[argument.index(after: argument.startIndex)..<colon]),
                      String(argument[argument.index(after: colon)...]))
            } else if argument.hasPrefix("/"), argument.count > 1,
                      !argument.dropFirst().contains("/"), !FileManager.default.fileExists(atPath: argument) {
                store(String(argument.dropFirst()), "true") // e.g. /closeonend or /unified
            } else if command == nil {
                command = argument.lowercased()
            } else {
                options.paths.append(absolute(argument))
            }
        }
        guard let command, !command.isEmpty else { return nil }
        // TortoiseGitIDiff's standalone form: `pangolin idiff --left a.png --right b.png`.
        return (command == "idiff" ? "imagediff" : command, options)
    }
}
