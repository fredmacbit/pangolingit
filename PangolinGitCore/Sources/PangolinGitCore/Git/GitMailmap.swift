import Foundation

/// Git mailmap parser for mapping author names and email aliases.
/// Equivalent to TortoiseGit's `CGitMailmap` (`src/Git/GitMailmap.cpp`).
///
/// Supported forms (see gitmailmap(5)):
///   Proper Name <commit@email>
///   <proper@email> <commit@email>
///   Proper Name <proper@email> <commit@email>
///   Proper Name <proper@email> Commit Name <commit@email>
public final class GitMailmap: Sendable {
    private struct Entry: Sendable {
        let properName: String?
        let properEmail: String?
        let commitName: String?
    }

    private let mappings: [String: [Entry]]

    public init(content: String = "") {
        var map: [String: [Entry]] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Split into alternating "name" / "<email>" tokens.
            var names: [String] = []
            var emails: [String] = []
            var rest = Substring(line)
            while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
                names.append(rest[..<open].trimmingCharacters(in: .whitespaces))
                emails.append(String(rest[rest.index(after: open)..<close]))
                rest = rest[rest.index(after: close)...]
            }
            guard let commitEmail = emails.last else { continue }

            let entry: Entry
            if emails.count == 1 {
                entry = Entry(properName: names[0].nilIfEmpty, properEmail: nil, commitName: nil)
            } else {
                entry = Entry(properName: names[0].nilIfEmpty, properEmail: emails[0], commitName: names[1].nilIfEmpty)
            }
            map[commitEmail.lowercased(), default: []].append(entry)
        }
        self.mappings = map
    }

    public func resolve(name: String, email: String) -> (name: String, email: String) {
        guard let entries = mappings[email.lowercased()] else { return (name, email) }
        // An entry that also names the commit author wins over a bare email match.
        let match = entries.first(where: { $0.commitName?.caseInsensitiveCompare(name) == .orderedSame })
            ?? entries.first(where: { $0.commitName == nil })
        guard let match else { return (name, email) }
        return (match.properName ?? name, match.properEmail ?? email)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
