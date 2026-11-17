import Foundation
import PangolinGitCore

/// `pangolin` — command-line entry to PangolinGit's dialogs, the counterpart of `TortoiseGitProc.exe`.
/// It turns its arguments into a `pangolingit://<command>?path=…&key=value` request and hands it to
/// the PangolinGit app this tool belongs to. Both styles work:
///
///   pangolin log . --rev HEAD~10
///   pangolin /command:commit /path:/repo /logmsg:"Fix typo" /closeonend:2
///   pangolin idiff --left old.png --right new.png
@main
struct PangolinCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.contains(where: { ["-h", "--help", "help", "/?"].contains($0) }) {
            print(usage)
            exit(arguments.isEmpty ? 1 : 0)
        }
        guard let parsed = CommandOptions.parseCommandLine(arguments, currentDirectory: FileManager.default.currentDirectoryPath) else {
            print(usage)
            exit(1)
        }
        let command = parsed.command
        var options = parsed.options
        // TortoiseGitMerge style: the merged file is the one the conflict editor opens.
        if command == "merge", options.paths.isEmpty, let merged = options.string("merged") {
            options.paths = [merged]
        }
        // Most commands work on the current folder when no path is given, like TortoiseGitProc in Explorer.
        if options.paths.isEmpty, !["clone", "settings", "about", "ssh", "firstrun", "updatecheck", "imagediff"].contains(command) {
            options.paths = [FileManager.default.currentDirectoryPath]
        }
        guard let url = options.url(command: command) else {
            fputs("pangolin: could not build a request for '\(command)'\n", stderr)
            exit(1)
        }
        exit(open(url))
    }

    /// Opens the URL with the app bundle this tool lives in (`PangolinGit.app/Contents/MacOS/pangolin`),
    /// following a Homebrew symlink; falls back to whichever app handles `pangolingit://`.
    static func open(_ url: URL) -> Int32 {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var arguments = [url.absoluteString]
        if bundle.pathExtension == "app" {
            arguments = ["-a", bundle.path] + arguments
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("pangolin: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    static let usage = """
    pangolin — open PangolinGit dialogs from the command line (TortoiseGitProc for macOS)

    Usage: pangolin <command> [path…] [--key value | --flag]
           pangolin /command:<command> [/path:<path>[*<path>…]] [/key:value]

    Commands: commit add diff log blame pull push sync clone branch switch merge rebase stash changed
              browserefs revert reset worktree submodule patch imagediff ssh stats ignore export reflog
              bisect repobrowser remotes settings about rename remove requestpull lfslocks lfslock lfsunlock
              daemon svnfetch svnrebase svndcommit svnignore updatecheck firstrun (and newer ones the app knows)

    Paths default to the current folder. Common options (passed to the dialog that understands them):
      --rev --startrev --endrev --range   revisions (log, diff, branch/tag, reset)
      --logmsg TEXT  --logmsgfile FILE    commit message
      --closeonend 0|1|2                  progress window auto-close
      --page NAME                         settings page, e.g. --page hooks
      --url URL                           clone source
      --force                             e.g. lfsunlock --force
    Standalone tools:
      pangolin idiff --left A.png --right B.png       compare two images
      pangolin merge --base B --mine M --theirs T --merged R
    """
}
