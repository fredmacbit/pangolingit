import Foundation
import CryptoKit

/// Named groups of changed files, local to this Mac (TortoiseGit's changelists in the status list:
/// *Move to changelist*, *Remove from changelist*, the special `ignore-on-commit` list whose files
/// the Commit dialog leaves unchecked). Stored per repository as JSON in Application Support,
/// never in the repository itself.
public final class ChangelistStore {
    /// Files in this changelist are not checked by default in the Commit dialog.
    public static let ignoreOnCommit = "ignore-on-commit"

    public let fileURL: URL
    /// Repository-relative path → changelist name.
    public private(set) var assignments: [String: String] = [:]

    /// - Parameter directory: folder holding one JSON file per repository (overridable for tests).
    public init(repositoryRoot: PangolinPath, directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PangolinGit/changelists", isDirectory: true)
        let digest = SHA256.hash(data: Data(repositoryRoot.rawPath.utf8)).map { String(format: "%02x", $0) }.joined()
        fileURL = folder.appendingPathComponent(String(digest.prefix(32)) + ".json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            assignments = decoded
        }
    }

    public func changelist(for path: String) -> String? {
        assignments[path]
    }

    /// Changelist names in use, `ignore-on-commit` last (it is always offered in menus anyway).
    public var names: [String] {
        let used = Set(assignments.values)
        return used.filter { $0 != Self.ignoreOnCommit }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            + (used.contains(Self.ignoreOnCommit) ? [Self.ignoreOnCommit] : [])
    }

    public func move(_ paths: [String], to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for path in paths { assignments[path] = trimmed }
        save()
    }

    public func remove(_ paths: [String]) {
        for path in paths { assignments.removeValue(forKey: path) }
        save()
    }

    /// Forgets files that no longer show up as changed (e.g. after they were committed elsewhere).
    /// Only call with a complete, unfiltered list of changed paths.
    public func prune(keeping changedPaths: Set<String>) {
        let before = assignments.count
        assignments = assignments.filter { changedPaths.contains($0.key) }
        if assignments.count != before { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if assignments.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                try JSONEncoder().encode(assignments).write(to: fileURL, options: .atomic)
            }
        } catch {
            PangolinLog.general.error("Could not save changelists: \(error.localizedDescription, privacy: .public)")
        }
    }
}
