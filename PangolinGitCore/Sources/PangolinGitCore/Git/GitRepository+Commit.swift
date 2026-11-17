import Foundation

/// Queries and index operations used by the Commit dialog (TortoiseGit's `CommitDlg.cpp`).
extension GitRepository {

    @discardableResult
    private func runGit(_ arguments: [String]) async throws -> String {
        try await GitCLIRunner.runAsync(arguments: arguments, workingDirectory: workingDirectory)
    }

    /// Output of a git command, nil when it fails (missing config key, unknown ref, …).
    private func optionalGit(_ arguments: [String]) async -> String? {
        guard let result = try? await GitCLIRunner().run(arguments: arguments, workingDirectory: workingDirectory),
              result.isSuccess else { return nil }
        return result.standardOutput
    }

    // MARK: - Messages

    /// Full message of `revision` (`git log -1 --format=%B`), used by Amend and "Pick commit message".
    public func commitMessage(of revision: String = "HEAD") async throws -> String {
        let output = try await runGit(["log", "-1", "--format=%B", revision, "--"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Contents of `commit.template` (`~/` expanded, relative paths taken from the working tree root),
    /// or nil when none is configured or it cannot be read.
    public func commitTemplate() async -> String? {
        guard let raw = await configValue("commit.template"), !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                                          : workingDirectory.url.appendingPathComponent(expanded)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The prepared merge message while a merge (or cherry-pick/revert) waits to be committed.
    public var pendingMergeMessage: String? {
        for name in ["MERGE_MSG"] {
            let url = gitDirectory.url.appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return text }
        }
        return nil
    }

    /// True while a merge is waiting for its commit (`MERGE_HEAD` exists); git then refuses partial commits.
    public var isMergeInProgress: Bool {
        FileManager.default.fileExists(atPath: gitDirectory.url.appendingPathComponent("MERGE_HEAD").path)
    }

    // MARK: - Config and identity

    /// `git config --get key`, nil when unset.
    public func configValue(_ key: String) async -> String? {
        await optionalGit(["config", "--get", key])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Boolean config value (`git config --type=bool`), `fallback` when unset or invalid.
    public func configBool(_ key: String, default fallback: Bool) async -> Bool {
        guard let value = await optionalGit(["config", "--type=bool", "--get", key]) else { return fallback }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// `core.commentChar` (`#` by default or with `auto`).
    public func commentChar() async -> Character {
        guard let value = await configValue("core.commentChar"), value.count == 1, let char = value.first else { return "#" }
        return char
    }

    /// `bugtraq.*` settings from the repository config, falling back to the versioned `.tgitconfig`.
    public func bugtraqSettings() async -> BugtraqSettings? {
        func parse(_ output: String?) -> [String: String] {
            var values: [String: String] = [:]
            for line in (output ?? "").split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                values[parts[0].lowercased()] = parts.count > 1 ? String(parts[1]) : ""
            }
            return values
        }
        var config = parse(await optionalGit(["config", "-f", ".tgitconfig", "--get-regexp", "^bugtraq\\."]))
        config.merge(parse(await optionalGit(["config", "--get-regexp", "^bugtraq\\."]))) { _, repository in repository }
        return BugtraqSettings(config: config)
    }

    /// Name and email git would record as committer (`git var GIT_COMMITTER_IDENT`).
    public func committerIdentity() async -> (name: String, email: String)? {
        guard let ident = await optionalGit(["var", "GIT_COMMITTER_IDENT"]) else { return nil }
        return CommitMessage.identity(fromIdent: ident)
    }

    /// `Name <email>` of the author git would use, or of HEAD's author when amending.
    public func authorString(ofHead: Bool) async -> String? {
        if ofHead {
            return await optionalGit(["log", "-1", "--format=%an <%ae>", "HEAD", "--"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let ident = await optionalGit(["var", "GIT_AUTHOR_IDENT"]),
              let identity = CommitMessage.identity(fromIdent: ident) else { return nil }
        return "\(identity.name) <\(identity.email)>"
    }

    // MARK: - Branches

    /// True when HEAD does not point at a branch (`git symbolic-ref` fails; an unborn branch still counts as a branch).
    public func isHeadDetached() async -> Bool {
        await optionalGit(["symbolic-ref", "-q", "HEAD"]) == nil
    }

    /// `git check-ref-format --branch`.
    public func isValidBranchName(_ name: String) async -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }
        return await optionalGit(["check-ref-format", "--branch", name]) != nil
    }

    /// True when the fully qualified ref (e.g. `refs/heads/x`) exists.
    public func refExists(_ fullRef: String) async -> Bool {
        await optionalGit(["show-ref", "--verify", "-q", fullRef]) != nil
    }

    /// Upstream of the current branch (`origin/main`), nil when none is configured.
    public func headUpstream() async -> String? {
        await optionalGit(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Index

    /// Diff of one file: working tree against the index, or (`staged`) the index against HEAD.
    public func fileDiff(_ path: String, staged: Bool) async throws -> String {
        var args = ["diff", "--no-color", "--no-ext-diff"]
        if staged { args.append("--cached") }
        args += ["--", path]
        return try await runGit(args)
    }

    /// Applies `patch` to the index only (`git apply --cached`); `reverse` unstages it.
    public func applyToIndex(patch: String, reverse: Bool) async throws {
        var args = ["apply", "--cached", "--whitespace=nowarn"]
        if reverse { args.append("-R") }
        args.append("-")
        let directory = workingDirectory
        let input = Data(patch.utf8)
        let result = try await Task.detached {
            try GitCLIRunner().runSync(arguments: args, workingDirectory: directory, standardInput: input)
        }.value
        _ = try GitCLIRunner.checked(result, arguments: args)
    }

    /// True when the submodule at `path` has uncommitted changes of its own.
    public func isSubmoduleDirty(_ path: String) async -> Bool {
        let output = await optionalGit(["-C", path, "status", "--porcelain"])
        return !(output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
