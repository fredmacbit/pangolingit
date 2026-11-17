import Foundation
import PangolinGitCore

/// pangolin-wcrev — working-tree revision substitution, the macOS counterpart of TortoiseGit's
/// `GitWCRev.exe` (`src/GitWCRev/GitWCRev.cpp`). Options, keywords and exit codes follow GitWCRev;
/// see `WCRevOptions` / `WCRevTemplate` in PangolinGitCore.
///
///   pangolin-wcrev Path [SrcVersionFile DstVersionFile] [-mMuUdqsFf] [--json]
@main
struct PangolinWCRev {
    static func main() {
        guard let options = WCRevOptions.parse(Array(CommandLine.arguments.dropFirst())) else {
            print(helpText)
            exit(WCRevExitCode.syntax.rawValue)
        }
        exit(run(options).rawValue)
    }

    static func run(_ options: WCRevOptions) -> WCRevExitCode {
        let fm = FileManager.default
        let workingTree = URL(fileURLWithPath: options.workingTreePath).standardizedFileURL.path
        guard fm.fileExists(atPath: workingTree) else {
            print("Directory or file '\(workingTree)' does not exist")
            return .fileNotFound
        }

        var template: String?
        if let source = options.templatePath, let destination = options.outputPath {
            guard fm.fileExists(atPath: source) else {
                print("File '\(source)' does not exist")
                return .fileNotFound
            }
            if options.failIfOutputExists && fm.fileExists(atPath: destination) {
                print("File '\(destination)' already exists")
                return .outputExists
            }
            guard let data = fm.contents(atPath: source) else {
                print("Unable to open input file '\(source)'")
                return .openFailed
            }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                print("Could not read the file '\(source)'")
                return .readWriteFailed
            }
            template = text
        }

        let info: WCRevInfo
        do {
            info = try WCRevCollector.collect(path: workingTree, options: options)
        } catch WCRevCollector.Failure.notAWorkingTree {
            print("'\(workingTree)' is not inside a Git working tree")
            return .notAWorkingTree
        } catch WCRevCollector.Failure.gitFailed(let message) {
            fputs("Git error: \(message)\n", stderr)
            return .gitError
        } catch {
            fputs("Git error: \(error.localizedDescription)\n", stderr)
            return .gitError
        }

        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(info) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else if !options.quiet {
            print("GitWCRev: '\(workingTree)'")
        }

        let submoduleMods = options.recursive && info.hasSubmoduleModifications
        if options.errorOnModifications && (info.hasModifications || info.hasSubmoduleNewCommits || submoduleMods) {
            if !options.quiet { print("Working tree has uncommitted modifications!") }
            return .modificationsFound
        }
        if options.errorOnUnversioned && (info.hasUnversioned || (options.recursive && info.hasSubmoduleUnversioned)) {
            if !options.quiet { print("Working tree has unversioned items!") }
            return .unversionedFound
        }
        if !options.quiet && !options.json {
            print("HEAD is \(info.headHash)")
            if info.hasModifications { print("Uncommitted modifications found") }
            if info.hasUnversioned { print("Unversioned items found") }
        }

        guard let template, let destination = options.outputPath else { return .ok }
        let output = WCRevTemplate.substitute(template, info: info)
        // Like GitWCRev, leave an identical file untouched so its timestamp does not trigger rebuilds.
        if !options.force, let existing = fm.contents(atPath: destination), existing == Data(output.utf8) {
            return .ok
        }
        do {
            try output.write(toFile: destination, atomically: true, encoding: .utf8)
        } catch {
            print("Unable to open output file '\(destination)' for writing")
            return .openFailed
        }
        return .ok
    }

    static let helpText = """
    pangolin-wcrev — GitWCRev for macOS

    Usage: pangolin-wcrev Path [SrcVersionFile DstVersionFile] [-mMuUdqsFf] [--json]

    Params:
    Path               :   path to a Git working tree OR
                           a directory/file inside a working tree.
    SrcVersionFile     :   path to a template file containing keywords.
    DstVersionFile     :   path to save the resulting parsed file.
    -m                 :   exit with code 7 if the path contains local modifications.
    -M                 :   same as above, including modifications inside submodules.
    -u                 :   exit with code 11 if the path contains unversioned items.
    -U                 :   same as above, including submodules.
    -d                 :   exit with code 9 (and do nothing) if DstVersionFile exists.
    -q                 :   no status output on stdout.
    -s                 :   do not check submodules (faster).
    -F                 :   ignore the .gitwcrevignore file.
    -f                 :   rewrite DstVersionFile even when its content is unchanged.
    --json             :   print the collected working-tree information as JSON.

    Keywords:
    $WCREV$  $WCREV=n$     HEAD commit id, optionally truncated to n characters ($WCHASH$ is an alias)
    $WCDATE$ $WCDATEUTC$   author date of HEAD (yyyy/mm/dd hh:mm:ss), local time or UTC
    $WCDATE=fmt$ $WCDATEUTC=fmt$   same with a strftime format
    $WCNOW$ $WCNOWUTC$ $WCNOW=fmt$ $WCNOWUTC=fmt$   current date and time
    $WCLOGCOUNT$           number of first-parent commits; $WCLOGCOUNT&n$ $WCLOGCOUNT+n$ $WCLOGCOUNT-n$
    $WCBRANCH$             current branch, commit id if HEAD is detached
    $WCURL$ $WCAUTHOR$ $WCEMAIL$   upstream remote URL, author and e-mail of HEAD
    $WCxxx?TrueText:FalseText$ with xxx one of MODS, FILEMODS, UNVER, ISTAGGED, INGIT, SUBMODULE,
        SUBMODULEUP2DATE, MODSINSUBMODULE, UNVERINSUBMODULE, MODSFULL, UNVERFULL

    Paths listed in .gitwcrevignore (working-tree root, one pathspec per line) are not checked.

    Exit codes: 1 syntax, 2 file not found, 3 open error, 5 read/write error, 6 git error,
    7 modifications found (-m/-M), 9 output exists (-d), 10 not a working tree, 11 unversioned found (-u/-U).
    """
}
