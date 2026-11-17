# PangolinGit vs. TortoiseGit — End-User Feature Comparison

**Date:** 2026-10-28
**TortoiseGit reference:** 2.19.0 (`/Users/frederik/Documents/Repositories/TortoiseGit`, user guide `doc/source/en/**` cross-checked with `src/Resources/*.rc`, `src/TortoiseShell`, `src/TortoiseProc`, `src/TortoiseMerge`, `src/TortoiseIDiff`, `src/TortoiseUDiff`, `src/TortoiseGitBlame`)
**PangolinGit reference:** commit `2860c3b` on `main` (≈18 500 lines of Swift across `PangolinGit/`, `PangolinGitCore/`, `PangolinGitAgent/`, `PangolinGitFinder/`, `PangolinGitAskPass/`, `tools/`)
**Purpose:** an implementation backlog. Every deviation between what a TortoiseGit user can do and what a PangolinGit user can do today is listed with an ID, so items can be picked up one by one in later work.

---

## 0. How to read this document

### 0.1 Status legend

| Mark | Meaning |
|---|---|
| ❌ **Missing** | No code for this feature exists in PangolinGit. |
| ⚠️ **Partial** | Something exists but covers only part of the TortoiseGit behaviour (fewer options, single selection, hard-coded values, etc.). |
| 🐛 **Broken / dead** | Code exists but is unreachable, has no effect, or misbehaves (e.g. a setting that is stored but never read; a button that does nothing). |
| 🍎 **Platform** | The TortoiseGit feature is Windows-specific; the macOS equivalent (if any) is described. Listed so the decision is explicit, not forgotten. |
| ✅ **Present** | Comparable behaviour exists. Only mentioned in the per-area "already covered" lines; not a backlog item. |

### 0.2 Entry format

Each deviation has a stable ID (`<AREA>-<nn>`), a status mark, and five lines:

- **What it does** — the user-visible purpose.
- **How it works in TortoiseGit** — menu path / control / underlying git command.
- **Example** — a concrete situation in which a user reaches for it.
- **PangolinGit today** — what the code does now, with `file:line` evidence (paths relative to the repository root).
- **To implement** — the shortest sensible route to parity on macOS.

### 0.3 Ground rules used when deciding "present"

- "Present" requires that the feature is reachable from the UI (Finder menu, main menu, launcher or a dialog) **and** actually executes. A class that is never instantiated (e.g. `ProgressWindowController`, `CredentialPromptWindowController`) counts as 🐛, not ✅.
- Settings count as present only if some non-settings code reads them. A stored-but-unread key is 🐛.
- Git plumbing in `PangolinGitCore/Sources/PangolinGitCore/Git/GitRepository.swift` that no dialog calls (`push`, `pull`, `fetch`, `rebase`, `cherryPick`, `stash*`, `tagCreate`, `remoteAdd`, `worktreeAdd`, `submoduleUpdate`, `clean`, `revert`, `configSet`, …) is noted as a shortcut for implementation but does not make a feature present.

### 0.4 Areas

| § | Area | TortoiseGit surface | PangolinGit surface |
|---|---|---|---|
| 1 | Finder / shell integration (overlays, context menu, drag & drop, property page, shortcuts) | `TortoiseShell`, TGitCache, `dug_general`, `dug_wcstatus` | `PangolinGitFinder/FinderSync.swift`, `PangolinGitAgent/*` |
| 2 | Check for Modifications, shared file list, changelists | `ChangedDlg`, `GitStatusListCtrl` | `Dialogs/Changed`, `Views/StatusList` |
| 3 | Add, Delete, Rename, Ignore, Clean up | `AddDlg`, `RenameDlg`, `IgnoreDlg`, `CleanTypeDlg` | `Dialogs/Add`, `Remove`, `Rename`, `Ignore` |
| 4 | Commit | `CommitDlg` | `Dialogs/Commit` |
| 5 | Log and Statistics | `LogDlg`, `GitLogListBase`, `StatGraphDlg` | `Dialogs/Log`, `Dialogs/Statistics`, `Views/RevisionGraph` |
| 6 | Diff family: file diff, Compare Revisions, unified diff viewer, image diff, submodule diff, external tools | `TortoiseGitMerge` (2-pane), `FileDiffDlg`, `TortoiseGitUDiff`, `TortoiseGitIDiff`, `SubmoduleDiffDlg` | `Dialogs/Diff`, `Dialogs/FileDiff`, `Views/Diff`, `Views/ImageDiff` |
| 7 | Merge / conflict editor and patch application (TortoiseGitMerge 3-pane) | `TortoiseMerge` | `Dialogs/Merge`, `Core/Diff/MergeEngine.swift` |
| 8 | Revert, Reset, Resolve, Abort merge | `RevertDlg`, `ResetDlg`, `ResolveDlg`, `MergeAbortDlg` | `Dialogs/Revert`, `Dialogs/Reset` |
| 9 | Switch/Checkout, Create Branch/Tag, Browse References, Merge dialog | `GitSwitchDlg`, `CreateBranchTagDlg`, `BrowseRefsDlg`, `MergeDlg` | `Dialogs/Switch`, `Dialogs/Branch`, `Dialogs/BrowseRefs` |
| 10 | Rebase, Cherry-pick, Bisect, RefLog, Stash | `RebaseDlg`, `BisectStartDlg`, `RefLogDlg`, stash commands | `Dialogs/Rebase`, `Bisect`, `RefLog`, `Stash` |
| 11 | Pull/Fetch, Push, Sync, Clone, Create repository, Remotes | `PullFetchDlg`, `PushDlg`, `SyncDlg`, `CloneDlg`, `CreateRepoDlg`, settings remote page | `Dialogs/Pull`, `Push`, `Sync`, `Clone`, `Remotes` |
| 12 | Export, Create/Apply patch, Send mail, Request pull | `ExportDlg`, `FormatPatchDlg`, `ImportPatchDlg`, `SendMailDlg`, `RequestPullDlg` | `Dialogs/Export`, `Patch`, `RequestPull` |
| 13 | Submodules, Worktrees, Repository browser, Revision graph, Blame | `SubmoduleAddDlg`/`UpdateDlg`, `WorktreeListDlg`, `RepositoryBrowser`, `RevisionGraphDlg`, `TortoiseGitBlame` | `Dialogs/Submodule`, `Worktree`, `RepoBrowser`, `Blame` |
| 14 | LFS locking, Git daemon, git-svn, Bug-tracker integration | `LFSLocksDlg`, `DaemonCommand`, SVN commands, bugtraq | `Dialogs/LFS` |
| 15 | Settings (all pages), hooks, advanced | `Settings*` pages | `Dialogs/Settings/*`, `Core/Config/ConfigManager.swift` |
| 16 | Progress dialog, post-actions, cross-cutting behaviours | `GitProgressDlg`, `ProgressDlg` | `Dialogs/Progress` (unused) |
| 17 | Automation CLI, GitWCRev, SSH, update check, About, First-start wizard | `TortoiseGitProc /command:`, `GitWCRev`, PuTTY/Pageant, `CheckForUpdatesDlg`, `FirstStartWizard` | URL scheme, `tools/pangolin-wcrev.swift`, `Dialogs/SSH`, `App/SparkleUpdater.swift`, `Dialogs/FirstRun` |
| 18 | PangolinGit-internal defects that block parity (quick fixes) | — | — |
| 19 | Suggested implementation order | — | — |

---

## Implementation progress

Work follows the phase order in §19. An item is listed as **done** only when its "To implement" line is fully covered; otherwise it is **partial** with what remains.

### P0 — Foundations (2026-10-29)

| Item | State | Notes |
|---|---|---|
| SE-01 | done | Settings save on window close, on tab switch and whenever a text field finishes editing; General checkboxes wired; panes never opened are not saved (they would overwrite stored values with empty controls). No separate OK/Apply bar. |
| SE-02 | partial | Now read: proxy / no-proxy / SSL verify (environment of every git run), progress auto-close, diff colours (default = adaptive system colours), blame date format, `recentUrls` (Clone). Still unread, each resolved by its own item: `recursiveStatusDepth` (SH-07), external diff/merge tools (DF-14), hooks (SE-12), `credentialHelper` (DA-01), `advancedSettings` (SE-14). |
| PR-01 | partial | `GitCLIRunner.stream` + `ProgressWindowController`: live output with in-place progress counters, coloured error/warning lines, Abort (terminates git; stops waiting for child processes after 2 s), elapsed time, post-action buttons (+ Retry on failure), three auto-close modes. Used by Push, Pull, Fetch, Sync fetch, Clone, Reset. Remaining dialogs adopt it in their own phases. |
| PR-03 | done | `GitCLIRunner.mutationObserver` fires after every state-changing git command (classified by verb/subcommand, unit-tested); the app coalesces these per repository, reloads open windows and invalidates the agent's cache. |
| PR-07 | partial | Errors carry the full command line; the progress window is the error surface for the adopted dialogs. |
| SH-17 | partial | Badges refresh right after in-app actions (agent `invalidateCache`). The Finder *Refresh status* entry is part of SH-16 (P1). |
| CV-01 | partial | `RevisionChooserView` (HEAD / Branch incl. remote / Tag / Commit + `…` picker) in Create Branch/Tag, Switch, Reset, Export, Rebase; `…` pickers on Bisect and Compare Revisions fields. Worktree and the (missing) Merge dialog follow in WT-01/02 and BR-x. |
| LG-23 | done | `LogWindowController(pickerCompletion:)` with Select/Cancel; double-click selects. |
| BR-10 | partial | `BrowseRefsWindowController(pickerCompletion:)` returns one ref; two-ref range selection is open. |
| QF-01 (IG-02) | done | Exact-path choice disabled on the repository root. |
| QF-02 | done | Reset defaults to HEAD, chooser with working Log/References pickers, runs in the progress window. |
| QF-03 | done | Log file double-click diffs the commit against its first parent (empty tree for a root commit). |
| QF-04 (BR-01) | partial | Filter applies to ref name, message and commit id; the field menu (Refname/Subject/Authors/SHA-1) is open. |
| QF-05 (RBW-01) | partial | Real folder tree (folders first); split directory/file panes are open. |
| QF-06 | done | See SE-01. |
| QF-08 | partial | Progress window in use; `CredentialPromptWindowController` still unused (DA-01). |
| QF-10 (DF-09) | partial | Diffing an image (Finder Diff, status lists, Log) opens the image comparison with both revisions extracted. "Binary files differ" message for other binaries is open. |
| QF-11 (CN-02) | partial | Destination = chosen parent + repository name (until edited), URL history combo, clipboard URL, progress output, Show Log / Show in Finder afterwards. `/exactpath` and Browse-for-local-URL are open. |
| QF-12 | done | Sync shows the real upstream (or explains there is none); fetch errors appear in the progress window. |
| QF-13 | done | Request Pull starts from the upstream branch and uses that remote's URL. |
| QF-21 | done | Export unpacks off the main thread and reports tar failures. |

Also fixed on the way: committing a staged deletion or rename failed (`git add` rejected the vanished path).

### P1–P10 (2026-10-30, parallel implementation, merged on `tortoisegit-parity`)
Each area was implemented in its own worktree, built and tested, then merged; after the merge the full suite (253 tests) passes. "partial" notes say what remains.
Totals: 197 done, 83 partial, 9 skipped. Not yet started: CC-06 (localisation sweep across all dialogs), which needs the merged code.

#### P1 — Finder integration

12 done, 7 partial, 0 skipped.
Merge: the skip-worktree / assume-unchanged menu (SH-05) uses the Status area's implementation (ST-16); the Finder area's duplicate `IndexFlagActions` was dropped. Drag and drop in the file list maps table rows through changelist groups.

| Item | State | Notes |
|---|---|---|
| SH-01 | done | Menu now depends on the clicked item's state. The agent answers the new menuState XPC call with TortoiseGit's ITEMIS_* flags (status, folder, wcRoot, submodule, bare, merge/rebase/cherry-pick/bisect in progress, stash, .gitmodules, LFS, inaccessible). Each catalog entry carries TortoiseGit's MenuInfo.cpp yes/no rules. Waits up to 1 s for the agent, then falls back to known roots. |
| SH-02 | partial | File/folder/one/two/patch-file rules are in place, and a two-file Diff entry is offered. Remaining: the app's diff command only compares the first path, so the Diff area must handle two paths. |
| SH-03 | done | Shift + right-click shows the extended entries. Each command has a 'Shift only' checkbox in Settings; Stash Apply is Shift-only by default, as in TortoiseGit. |
| SH-04 | done | Watched folders are set in Settings > Overlays (empty means home and /Volumes). The agent relays them and the extension updates directoryURLs. Overlay exclusion paths are also supported. |
| SH-05 | done | The agent reads `git ls-files -v` into new badges: skip-worktree (.locked) and assume-unchanged (new GitBadgeKind.needsLock). Status lists get an 'Ignore Local Changes' submenu (assume unchanged / skip worktree / unflag). Showing flagged files in the list itself belongs to ST-03. |
| SH-06 | done | Two new settings, used when building status snapshots: 'unversioned files mark their folder as modified' and 'submodule changes mark parent folders'. |
| SH-07 | partial | Status cache mode added: full / tracked files only (-uno) / none. Remaining: recursiveStatusDepth (General pane) is still not read. |
| SH-09 | partial | Status lists (Commit, Add, Check for Modifications) can drag rows out as file URLs, and Commit accepts files dropped from Finder (git add, then checks them). Remaining: drag out of the Log file list and repo-browser export via NSFilePromiseProvider. |
| SH-12 | partial | 'Show icons in the menu' setting added and relayed to the extension. Remaining: optional key equivalents in the toolbar menu. |
| SH-14 | done | Each command can be placed Top level, Submenu or Hidden; top-level entries get a 'Git ' prefix. Restore Defaults is included. The old on/off map stays readable and is kept in sync. |
| SH-15 | done | Whether a path is in a repository now comes from the agent's menuState, not from earlier badge replies. New settings: 'hide the menu outside repositories' (Shift shows it) and menu exclusion paths (a trailing * matches everything below). |
| SH-16 | partial | Menu entries exist for every agreed command: fetch, mergebranch, createrepo, resolve, abortmerge, cleanup, stash pop/apply/list, formatpatch, applypatchserial, sendmail, daemon, revisiongraph, diffprevious, deletekeeplocal, deleteandignore, removefromignore, lfslock/unlock, refresh, help, about. createrepo, refresh (handled inside the extension and also routed) and help are implemented. Not separate entries yet because they have no agreed command names: bisect good/bad/skip/reset, submodule add/update/sync, Diff later, Review single patch. |
| SH-19 | partial | New View menu works in every dialog through the responder chain: Refresh (Cmd-R), Find (Cmd-F focuses the search field), Confirm Dialog (Cmd-Return presses the default button). Cmd-C copies selected table rows. Remaining: Cmd-Shift-C copy hash in Log, and Escape clearing filters. |
| SH-21 | done | The router accepts bare repositories for log, reflog, browse refs, repo browser, export, push and worktree. The menu offers the bare subset. A disabled 'Repository Inaccessible' hint appears for unreadable .git folders. |
| SE-05 | partial | New Overlays settings pane: cache mode, a switch per badge kind, unversioned/submodule-to-parent options, watched folders, excluded paths. Saving re-reads every repository only when something changed. Remaining: icon-set choice and drive-type (network volume) toggle. |
| SE-16 | done | Context Menu pane rewritten: every configurable catalog command with a placement popup and a Shift-only column, plus hide-outside-repositories, exclusions, icons toggle and Restore Defaults. |
| CR-01 | done | New pangolingit://createrepo and Dialogs/CreateRepo/CreateRepoWindowController: `git init [--bare]`; bare is pre-ticked for *.git folders. Warns on special folders, on a non-empty folder for bare, and on existing or nested repositories. Shows a success message, posts RepositoryEvents and refreshes the agent; the agent now re-detects new repositories and re-badges folders shown earlier. |
| QF-09 | done | Deleted MenuRules/MenuState (app) and PathRequirement (Core); PangolinGitCore/ShellMenu replaces them and is in use. Only the needsLock case was added to the GitFolderStatus switch; its own QF-09 decision is left to its owner. |
| QF-19 | done | The Context Menu pane now lists every configurable catalog command, including merge, rebase, filediff, branch and clone. firstrun is not a Finder menu command. |

Open follow-ups reported by this area:

- All areas: the Finder menu already sends pangolingit://fetch, mergebranch, resolve, abortmerge, cleanup, stashpop/stashapply/stashlist, formatpatch/applypatchserial/sendmail, daemon, revisiongraph, diffprevious, deletekeeplocal/deleteandignore/removefromignore, lfslock/lfsunlock. Until each owning area adds its PangolinCommand case, clicking one only logs 'Unknown command URL'. When adding one, also extend FinderIntegrationTests.testEveryFinderCommandHasARouteOrIsPending by removing it from the pending set.
- Diff area: Finder offers Diff for two selected files and sends both paths; the router's .diff only uses the first. Needs a two-file (git diff --no-index) view.
- Remote/Tools/Integrations areas: fetch, daemon and revisiongraph should be added to PangolinCommand.worksOnBareRepository (in CommandRouter.swift) when implemented, since the Finder offers them on bare repositories.
- Bisect/Submodule/Patch areas: TortoiseGit has separate Bisect good/bad/skip/reset, Submodule add/update/sync, Diff later and Review/apply single patch entries. They need agreed command names before the Finder catalog (PangolinGitCore/ShellMenu/ShellMenuCatalog.swift) can list them. Matching state flags already exist (.bisect, .submoduleContainer, .patchFile).
- Status area (ST-03): flagged (skip-worktree / assume-unchanged) files never appear in status lists, so 'Unflag' is only reachable for listed rows. Add a 'show flagged files' toggle using GitIndexFlags.parse.
- Settings/General pane: the 'Folder Status Scan Depth' field (recursiveStatusDepth) is still not read by anything (SH-07 remainder). Consider removing it in favour of the Overlays pane's cache mode.
- Log area (SH-09/SH-19): drag the Log file list out as files, and add Cmd-Shift-C copy hash. NSTableView now has a generic copy: (App/DialogShortcuts.swift); a Log-specific copy can override it in a subclass.
- Coordinator: an already-running old PangolinGitAgent does not know the new XPC methods. The extension falls back to the old coarse menu until the agent restarts (relaunch the app or log out and back in after updating).

#### P2a — Commit dialog

20 done, 4 partial, 1 skipped.

| Item | State | Notes |
|---|---|---|
| CM-01 | done | 'New branch' checkbox and name field. The name is checked with check-ref-format; an existing branch is refused and a tag with the same name asks first. The branch is created with git checkout -b before the commit. On a detached HEAD the dialog asks to create a branch. |
| CM-02 | done | 'Set author' field, prefilled from the author git would use, or from HEAD's author when amending; adds --author. 'Set date' picker adds --date (ISO with time-zone offset). 'Reset to now' adds --date=now when amending. |
| CM-03 | done | Sign-off button appends the line from git var GIT_COMMITTER_IDENT the way TortoiseGit does. When tgit.warnnosignedoffby is set, committing without it asks Add / Commit Without / Cancel. |
| CM-04 | done | 'Message only' checkbox: --allow-empty --only with no paths, and the 'no files checked' guard is skipped. |
| CM-05 | done | Ticking Amend loads git log -1 --format=%B; unticking brings back the typed message if the HEAD message was left unedited. 'Show diff to last commit' makes double-click and the patch pane diff against HEAD~1. |
| CM-06 | done | 'Recent Messages' pull-down with a history per repository (new ConfigManager API). Offers Paste Last Commit Message, delete an entry by holding Option, and Clear. Cancelling saves the typed message to the history. |
| CM-07 | done | The message box's right-click menu has Paste Filename List, Paste Last Commit Message, and Pick Commit Hash… / Pick Commit Message…, which open LogWindowController as a picker. |
| CM-08 | done | Suggestions for changed-file names and identifiers declared in them (regex table per language), plus snippet.txt from Application Support. The list pops up after 3 characters or on Ctrl+Space. The minimum length and on/off switch are not configurable yet (no Settings entry). |
| CM-09 | done | commit.template is read (~ and relative paths handled) and prefills the message. Committing it unedited asks for confirmation. |
| CM-10 | partial | Bug-ID field driven by bugtraq.message/label/number/append/warnifnoissue (git config, then .tgitconfig): checks the id, adds the line to the message, warns when no issue is given. Not done: issue-tracker plugin button, logregex, Log links (BG-01). |
| CM-11 | done | *bold*, ^italic^ and _underline_ are styled as you type; monospaced editor with a vertical guide at tgit.logwidthmarker; Commit stays disabled below tgit.logminsize. Comment lines (core.commentChar plus a space) are stripped, so '#123' survives; whitespace is cleaned up. |
| CM-12 | partial | 'Staging' checkbox (persisted as tgit.commitstagingsupport): check boxes show the index state (mixed = partly staged), ticking stages or unstages, and the commit uses the index. 'View Patch' pane shows staged and unstaged hunks with Stage/Unstage Hunk buttons (git apply --cached [-R]). Not done: staging single lines, as opposed to whole hunks. |
| CM-13 | done | 'Check' pull-down: All / None / Unversioned / Versioned / Added / Deleted / Modified / Files / Submodules. Adds to the current check marks like CGitStatusListCtrl::Check and respects 'Do not autoselect submodules'. |
| CM-14 | done | 'Show Unversioned Files', 'Whole Project' (shown when opened for a selection) and 'Do not autoselect submodules' (uses the porcelain v2 submodule flag); choices remembered. |
| CM-15 | done | Commit button plus a pull-down: Commit, Commit & Push, ReCommit; the choice is remembered. Commit & Push pushes HEAD to the configured upstream in a progress window, or opens the Push dialog when there is none. ReCommit keeps the dialog open and resets it. |
| CM-16 | done | Checks before committing: checked submodule with its own changes (Commit Submodule… / Ignore / Cancel), conflict markers in checked files, unresolved conflicts, file added then deleted on disk (dropped from the pathspec). During a merge: a banner, MERGE_MSG prefill and an index commit, because git refuses partial commits mid-merge. Unchecking is not disabled during a merge. |
| CM-17 | partial | git's own hooks (pre-commit, commit-msg, post-commit) run and their output appears in the progress window. TortoiseGit-style client hook scripts need SE-12. |
| CM-18 | done | Closing or cancelling with an edited message (not empty, template or amend text) asks first and saves the message to the history. It also offers to restore files marked 'Restore after commit'. |
| CM-19 | done | checkout -b, add and commit -F run in ProgressWindowController. After success it offers Push…, Pull…, ReCommit and Create Tag…. |
| CM-20 | partial | Message/list and list/patch splitters are resizable and remember their position, and the window frame is remembered. Customisable columns belong to ST-04 (StatusListView). |
| CM-21 | done | git's full output (hooks included) shows in the progress window, with Retry. The message file is kept until the commit succeeds so Retry works. |
| CM-22 | done | CommandRouter passes the Finder selection. The list is limited to those paths unless 'Whole Project' is on, and changes outside the selection start unchecked. |
| CM-23 | done | Cmd+Return and Ctrl+Return in the message box commit. Return elsewhere still triggers the default button. |
| ST-14 | done | File list right-click 'Restore after commit' keeps a copy, and 'Restore Now' puts it back. Copies are restored after a successful commit; cancelling asks Restore / Keep / Cancel. |
| PR-05 | skipped | Not specific to the commit dialog: it needs a bundled user guide and a ? button on every dialog, so it belongs to whoever owns PR-05 / the help command. |

Open follow-ups reported by this area:

- Settings area: no Settings entry exists for completion on/off or its minimum characters (fixed at 3). Saved Data still counts the global commit-message list only; it could show the per-repository history and offer to clear it.
- SE-12 (hooks): run TortoiseGit-style start-commit / pre-commit / post-commit client scripts around the commit. That completes CM-17.
- BG-01: issue-tracker plugin button, bugtraq.logregex, Bug-ID column and links in the Log. That completes CM-10.
- ST-04 (Status area): column chooser and remembered column widths in StatusListView. That completes CM-20's 'customisable columns'.
- CM-12 follow-up: staging single lines (not just whole hunks) in CommitPatchView.
- Coordinator: update doc/FEATURE_COMPARISON.md progress for CM-01 to CM-23 and ST-14. In the doc, DL-04's line reference to CommitWindowController.swift:196-200 is now stale. Also say in the doc that the commit dialog now uses the index when staging is on or a merge is in progress, and --only <paths> otherwise.
- Finder area: commit entries already send the selected paths; CM-22 relies on that, so keep passing every selected path in the commit URL.

#### P2b — File list, add/delete/ignore/clean, revert/resolve

35 done, 8 partial, 0 skipped.
Merge: the operation-in-progress model is shared with the Branching area (`GitOperationInProgress` in `GitSequencer.swift`).

| Item | State | Notes |
|---|---|---|
| ST-01 | done | Conflicted rows offer Edit Conflicts (merge editor), Resolved, and Resolve using Theirs/Mine with branch names. The labels follow rebase direction. If a side deleted the file, resolving with that side removes it. Double-click on a conflict in Changed Files opens the merge editor. No separate 'Three way diff' entry: the merge editor is the three-pane view. |
| ST-02 | done | ChangelistStore keeps changelists per repo as JSON in Application Support. The list shows group headers whose checkbox toggles the group. Menu: Move to Changelist (new, existing, ignore-on-commit) and Remove from Changelist. The Commit dialog leaves ignore-on-commit files unchecked. Entries are pruned when files are no longer changed. The 'Keep changelists' toggle on commit is a follow-up for the Commit area. |
| ST-03 | done | Changed Files now receives the Finder selection as a pathspec. Toggles: Unversioned, Ignored, Flagged (assume-unchanged/skip-worktree), Unmodified, and Whole project (remembered per repository). Added a Conflicted filter tab. |
| ST-04 | partial | Columns are sortable, can be shown or hidden from the header menu and are remembered per dialog (autosave). Added Lines Added, Lines Removed, Last Modified and Size columns. LFS lock owner column not done. |
| ST-05 | done | Modified, added and deleted rows use the Settings > Colors values (DiffColors). Conflicted, unversioned and ignored keep fixed system colours. |
| ST-06 | done | Footer shows 'Lines: +n −m · Files: N modified, N added, …' from git diff --numstat (StatusSummary, unit-tested). |
| ST-07 | partial | Save Diff… writes git diff HEAD (optionally --binary) for the listed scope to a file and reveals it in Finder. It does not open in a unified-diff viewer because none exists yet (DF-10). |
| ST-08 | done | Stash pull-down in Changed Files: Stash Changes… / List… open the Stash dialog; Pop and Apply run in the progress window. |
| ST-09 | done | Diff opens every checked file and asks first above 10. Compare Two Files (git diff --no-index) is offered when exactly two files are selected. |
| ST-10 | partial | Open, Open With (app list plus Other…) and Show in Finder added. 'View in alternative editor' waits for the SE-11 setting. |
| ST-11 | done | Copy submenu: Full Paths, Relative Paths, File Names, All Information. |
| ST-12 | done | Delete moves unversioned or ignored rows to the Trash. Holding Option shows Delete Permanently. |
| ST-13 | done | Revert… in the shared menu (Commit, Add, Changed, Revert, Resolve). Missing files are restored as part of it. |
| ST-15 | partial | Blame and Export Selection To… (keeps folder structure) added. Show log / log of submodule / log before rename need LogWindowController to accept a path (LG-04). |
| ST-16 | done | 'Ignore Local Changes' submenu: Skip Worktree, Assume Unchanged, Unflag (git update-index). Flagged files are listed via the Changed Files Flagged toggle. |
| ST-17 | done | LFS Lock and Unlock on tracked rows when .gitattributes uses filter=lfs; they run in the progress window. |
| ST-18 | partial | Holding Option shows 'Add as Executable' (add, then update-index --chmod=+x). 'Add as Symlink' skipped as 🍎 Platform: macOS checks out real symlinks, so git already records them as links. |
| ST-19 | done | Empty-list hint (with a filter-specific text), Space toggles the selected rows' checkboxes, changelist group headers check or uncheck their whole group. |
| AD-01 | done | 'Include ignored files' checkbox lists ignored files unchecked; they are added with -f. |
| AD-02 | done | Add runs `git add -v` in the progress window with Commit… and Add as Executable post-actions. |
| AD-03 | done | Empty-list hint explains that git tracks files only and suggests a .gitkeep placeholder. |
| DL-01 | done | Remove checks status first and warns about modified and unversioned content. It confirms before losing data, moves files to the Trash when the setting is on (git rm --cached, then trash), and runs in the progress window with Commit…. It shows one confirmation for the whole selection, not a per-item 'Yes to all'. |
| DL-02 | done | 'deletekeeplocal' command and a 'Delete (Keep Local)' list entry run git rm -r --cached directly in the progress window. |
| DL-03 | done | 'deleteandignore' command and list entry: choose by name or extension, which ignore file, recursive or not, and whether to keep the files locally. Then git rm --cached and, if not kept, Trash. |
| RN-01 | done | '…' chooser (save panel for one item, folder panel for several) and multi-item move into a folder. Checks that the destination is inside the working tree, not in .git, has no empty names or colons, and that sources are tracked (ls-files --error-unmatch). Submodules are moved by git mv. Runs in the progress window. |
| IG-01 | done | Ignore file: root .gitignore, .gitignore in the containing folder, or info/exclude. Match: only in the containing folder or recursively. Uses TortoiseGit's pattern rules (GitIgnoreFile+Scope, unit-tested). |
| IG-03 | done | Ignore dialog takes the whole Finder selection and writes each item's pattern to its own ignore file. |
| IG-04 | done | 'removefromignore' and 'Remove from Ignore List': git check-ignore -v finds the rule, which is removed. If the rule is broad, the user can add a !/path exception instead. The Ignore dialog warns when selected items are tracked and offers git rm --cached. |
| CU-01 | done | Clean Up dialog. Options: all/-x, non-ignored, ignored only/-X, -d, nested repos (-ff), submodules (recursive foreach), Do not use the Trash, Dry run; they are remembered. By default it dry-runs and moves each item to the Trash. Dry run offers Clean to Trash / Clean Permanently. 'cleanup' command. |
| RV-01 | done | Revert uses the Finder selection as pathspec and notes that unversioned files are not touched. |
| RV-02 | done | Revert is scoped to the selected folder (deletions and renames restore their originals, adds are unstaged). The Delete (keep local) shortcut exists. |
| RV-03 | done | Revert runs in the progress window. An 'Also check out reverted submodules' checkbox appears when submodules are listed. |
| RV-04 | done | New ConfigManager.useTrashOnRevert setting (default on), with a checkbox in Settings > Dialogs. Revert trashes a copy of each overwritten file; Delete, Clean up and Delete-and-ignore also use the Trash. |
| RV-05 | done | Revert reuses StatusListView (colours, filter, context menu, readable status names), refreshes through RepositoryEvents, leaves conflicted rows unchecked and warns before reverting them. |
| RV-06 | done | Resolve dialog: checked list of conflicted files, Select All/None, Edit Conflicts…, Use Mine, Use Theirs, Resolved, and a hint to commit or continue. The progress window offers Commit… once no conflict is left. 'resolve' command. |
| RV-07 | partial | Abort Merge dialog: Merge/Mixed/Hard reset, Show Modified Files, hard-reset confirmation, Update Submodules post-action. A stopped cherry-pick, revert, rebase or am gets its own --abort option. 'abortmerge' command. Still open: a Finder menu entry shown only while MERGE_HEAD exists (Finder area, SH-01). |
| RS-01 | done | Already fixed in P0 (chooser, HEAD default, pickers). The dialog now uses a stack-view layout. |
| RS-02 | partial | 'Show Modified Files' opens Check for Modifications, i.e. working tree against HEAD. Compare Revisions cannot diff against the working tree yet (DF-08). |
| RS-03 | done | Post-actions: Update Submodules (when .gitmodules exists), Bisect Good/Bad/Skip/Reset (while bisecting), Clean Up… after a hard reset. Refresh comes from the P0 mutation hook. |
| RS-04 | done | Added Merge mode (Keep stays). When opened on files or folders, a 'Reset only the selected paths' checkbox runs git reset <rev> -- <paths>. |
| RS-05 | done | The hard-reset confirmation shows git diff --stat HEAD in a scrollable box. |
| QF-27 | done | Fixed by RV-05: readable status names, conflicted rows unchecked with a warning. |
| PR-02 | partial | Add, Resolve, Remove and Rename run verbose git (-v) in the progress window, so each processed item is listed. Revert also runs there, but git restore lists nothing. Still open: a table-based item list and a 'Show log…' post-action. |

Open follow-ups reported by this area:

- Finder area: add Finder menu entries for resolve, cleanup, abortmerge (show only while MERGE_HEAD / CHERRY_PICK_HEAD / REVERT_HEAD / a rebase exists; GitRepository.operationInProgress tells which), deletekeeplocal, deleteandignore and removefromignore (for ignored items). Optionally add Resolve…, Clean Up… and Abort Merge to MainMenu's Repository menu.
- Log area (LG-04): add a path filter to LogWindowController (e.g. init(repositoryPath:path:)) so the status list can offer Show Log, Show Log of Submodule and Show Log Before Rename (rest of ST-15).
- Commit area: implement the 'Keep changelists' toggle. After a successful commit, call listActions.changelists.remove(committedPaths) unless it is ticked. Consider setting statusListView.setLineCounts and a StatusSummary footer in the Commit dialog too.
- Diff area (DF-08 / DF-10): Compare Revisions against the working tree, so Reset's 'Show Modified Files' can open HEAD vs working tree there instead of Check for Modifications; a unified-diff viewer so 'Save Diff…' can open the patch.
- Settings area (SE-11): an alternative-editor setting, so 'View in alternative editor' can join Open / Open With in the status-list menu.
- Shared progress component (PR-02): a table-based processed-items view and a 'Show log…' post-action are still open.
- Repository hygiene: PangolinGitCore/.build/ (SwiftPM build output) is checked into git and changes on every `swift build` / `swift test`; consider removing it and adding it to .gitignore.
- Coordinator: in this worktree the branch was created from main (2860c3b) rather than the P0 commit; I reset it to e660399 before working. Other worktrees (d97-1..8) may have the same issue.

#### P3 — Log and Statistics

16 done, 12 partial, 0 skipped.

| Item | State | Notes |
|---|---|---|
| LG-01 | done | Ref menu: HEAD, FETCH_HEAD, all refs, all branches/tags/remotes ('basic refs'), local branches, branch/tag submenus, the Browse References picker and a range entry (A..B, A...B, 'A B'). The choice is remembered per repository. The tri-state checkbox became menu items. |
| LG-02 | done | Ref labels drawn as coloured chips: current branch bold, detached HEAD, annotated tags marked, stash and bisect refs. Options: labels on the left or right, subject+body on the line, symbolised names (/main, origin/≡). Colours are fixed for now; SE-04 should make them configurable. |
| LG-03 | done | A 'Working tree changes' row with its own file list and menu: Commit, Check for Modifications, Revert, Stash, Abort merge, Pull, Fetch, Submodule update. Show Unversioned is a toggle. Clean up is left out because the Status area owns 'cleanup'. |
| LG-04 | done | Show Log on a file or folder now filters to that path. Follow renames (on by default for files), hide or grey unrelated changed paths, Show Whole Project toggle, Esc clears the path. |
| LG-05 | done | From/To date pickers. Limit to the last N commits, years, months or weeks, with the default set in Settings > Log. Next 100 and Show All buttons. The 500-commit cap is gone. |
| LG-06 | partial | Port of CFilterHelper: terms, -exclude, +or, quoted phrases, ! to invert, regex, case sensitivity. Field menu covers Subject, Messages, Paths (loaded on demand), Authors, Emails, SHA-1, Ref names and Notes. The graph stays visible while filtering. Missing: the Bug-ID field (needs BG-01) and the annotated tag message field. |
| LG-07 | partial | First parent only, no merges, full history and labelled commits only (--simplify-by-decoration) are in the View menu. Collapse/expand of revisions is not done. |
| LG-08 | partial | Column chooser in the header menu, with order, width and visibility saved. New columns: SHA-1, Email, Committer, Committer email, Commit date, Describe, Notes. The actions-icons column and the Bug-ID and SVN columns are not done. |
| LG-09 | done | Go To menu: HEAD, first/second parent, child, newer/older by same author, merge, tag or branch. Back/forward selection history buttons, ⌥ arrow keys, ⌘V jumps to a pasted hash, hash links in the details pane. |
| LG-10 | partial | Added: compare with working tree, compare with previous (per parent), unified diff (combined or per parent), browse repository, export this version (git archive), log from here, create branch/tag, switch, detached checkout, merge into current, rebase onto, cherry-pick, revert, reset, bisect good/bad/skip, per-label submenus, delete refs, format patch, edit notes, show branches containing, Copy submenu. Mutating commands run in the progress window. Missing: Search log messages, and Blame / Blame previous revision (Blame cannot open at a revision yet). |
| LG-11 | partial | Multi-selection works. Two commits: Compare Revisions, unified diff, log of A..B / B..A / A...B, bisect start. Any count: revert, cherry-pick, combine, format patch, copy variants. Missing: Compare change sets, and bisect skip on a selection. |
| LG-12 | partial | Changed-files pane with -M and +/- line counts, diffed against the real parent. Menu: compare with previous or working tree, unified diff, show log of the file, log of submodule, log before rename, blame of the working-tree file, save revision to, open this revision, revert to this revision, revert this commit's changes, list changes against parent N for merges, Show in Finder, Open, copy variants. Missing: blame at the commit's revision, Export selection, Open with / alternative editor. |
| LG-13 | done | Details pane links hashes (8+ hex digits) and URLs, shows notes, Gravatar (SHA-256 of the email, URL template in settings) and parent subjects. ⌘C copies all information. |
| LG-14 | partial | git describe (tags/contains, long, first-parent) shows in the details pane and in an optional Describe column computed only for visible rows. Branch revision number shows in the details pane only, not as a column. |
| LG-15 | partial | Cells are reused (fixes the Log half of QF-26). Parsing and lane building run off the main thread, and only the latest load is applied. No on-disk log cache and no incremental streaming. |
| LG-16 | done | Refresh button (⌘R), spinner while loading, status line 'Showing N of M revisions, from … to …, K selected'. |
| LG-17 | done | Enter compares with the previous revision. Double-click compares when the setting is on; otherwise it shows the commit as a unified diff. In picker mode both select. |
| LG-18 | partial | Each ref label has its own submenu: switch, tracking branch, merge, rebase, create branch from, push, push tag, show tag, delete, copy name. Shift-click on a label chip and the Shift extended menu are not done. |
| LG-19 | done | Edit Notes dialog runs git notes add -f, or git notes remove when emptied. Notes are loaded with %N, shown in the details pane and searchable. |
| LG-20 | done | New window listing branches and tags that contain a commit (git branch -a --contains, git tag --contains), with a filter, Copy, and double-click to open that ref's log. |
| LG-21 | done | Combine to one commit needs consecutive non-merge commits on the current branch's first-parent line and no tracked changes. It runs reset --soft plus commit with an editable message, then cherry-picks any newer commits back on top. If that fails, a 'Restore Original' button resets to the old HEAD. |
| LG-22 | partial | Submodules are marked in the changed-files pane, and 'Show Log of Submodule' opens the submodule's log. Highlighting the superproject's submodule pointer is not done. |
| LG-23 | done | Already done in P0. Picker mode is kept (single selection; menu offers Copy only). |
| LG-24 | done | Statistics rewritten with a summary page, commits by date and by author, percentage of authorship (TortoiseGit weighting), and changed lines by date with and without new/deleted files (Calculate runs numstat). Chart styles: pie, stacked line, line, stacked bar, bar. Options: case-sensitive authors, committer names, commit dates, sort by count, an 'authors shown individually' slider with Others. Time unit is picked automatically. Uses .mailmap through %aN/%cN. Save as PNG. Opened from the Log's Statistics button on the current revisions; the Finder 'stats' command still opens it on HEAD. |
| LG-25 | done | ⌘A (built in), ⌘C copies commit information, ⌘F focuses the search field (local key monitor because the Edit menu has no Find item), Esc clears the search, then the path filter, then cancels the picker. |
| SE-06 | partial | New Settings > Log pane: default limit, message font and size, short dates, relative times, system locale, double-click compares, abbreviate renamings, symbolise refs, Gravatar and its URL, labels on the right, subject+body, branch revision number, describe options. All are read by the Log. Missing: the asterisk log prefix and the log cache option, since there is no cache. |
| SE-07 | partial | Only the log-related options: use .mailmap, offer FETCH_HEAD and reverse tag order (all in the Log pane). The remaining Dialogs 2 options belong to other areas. |
| QF-26 | done | Log half only: Log tables reuse LogTextCellView and LogMessageCellView instead of creating NSTextFields on every draw. The Blame half belongs to the Tools/Blame area. |

Open follow-ups reported by this area:

- Blame area: BlameWindowController needs an initial-revision parameter so the Log can offer 'Blame' and 'Blame previous revision' at a commit (LG-10, LG-12). The Log currently blames the working-tree file only.
- Settings/Colors area (SE-04): ref-label and graph colours are fixed in LogMessageCellView.color(for:) and RevisionGraphView. Read them from ConfigManager once the colour set exists.
- Export/Patches area: ExportWindowController has no initial-revision parameter, so 'Export this version' runs git archive itself through the progress window. Switch to the dialog if a revision parameter is added. Format Patch runs git format-patch directly; it could open the PT-01 dialog later.
- Branching area: Merge, rebase-onto and cherry-pick from the Log run git directly through ProgressWindowController. Switch to the new Merge/Cherry-pick dialogs ('mergebranch', 'cherrypick') once they exist.
- Status area: the working-tree row could offer 'Clean up…' once the 'cleanup' command exists.
- Finder area: none needed. Show Log on a file or folder already passes the path through the existing 'log' command.
- Coordinator: the main menu has no Edit > Find item, so the Log handles ⌘F with a local key monitor. A global Find item (SH-19) could replace it.
- Not done in my area: LG-07 collapse/expand, LG-08 actions-icons column, LG-15 on-disk log cache, LG-18 Shift-click on label chips, LG-22 superproject pointer highlighting, LG-11 compare change sets.

#### P4 — Diff family and merge editor

19 done, 15 partial, 4 skipped.

| Item | State | Notes |
|---|---|---|
| DF-01 | done | Removed and added lines are paired as 'modified' rows. Intra-line differences are highlighted per character or per word (Myers on tokens after trimming common prefix/suffix). Lines longer than the max inline length setting get no inline marks. |
| DF-02 | done | The whole file is shown (--unified=1000000). Line numbers and +/−/≠ markers sit in an NSRulerView gutter with full-width row colours. Collapse unchanged sections and Wrap long lines are toggles, and both settings persist. |
| DF-03 | partial | Done: F7/⇧F7 next/previous difference, a clickable/draggable locator bar, the find bar (⌘F) and go to line (⌘L). Remaining: next/previous inline difference and the line-diff bar. |
| DF-04 | partial | Done: compare whitespace, -b, -w, --ignore-space-at-eol, --ignore-cr-at-eol and --ignore-blank-lines in the diff window; Compare Revisions also has a common-ancestor option (a...b). Remaining: ignore case, ignore comments, regex filters and moved-block detection. |
| DF-05 | partial | Done: Use Left Block (F12 or the context menu) restores one difference in the working-tree file, keeping its encoding and EOL, and can be undone with ⌘Z; Save Patch. Remaining: free editing in the panes, Use right block / whole file, marking blocks, Save as. |
| DF-06 | done | Added, deleted and modified colours plus the new header and position colours are read everywhere (diff, unified viewer, merge editor, Compare Revisions). Diff font, size and tab width come from Settings ▸ Colors. |
| DF-07 | partial | Done: the 'diffprevious' command (working file against the commit before the last one that touched it; for a folder, Compare Revisions HEAD~1 ↔ working tree). Diff with two files selected compares the two files (git diff --no-index). Remaining: Diff later / Diff with "file" and the Finder menu entries (Finder area). |
| DF-08 | done | The diff window has a comparison popup: HEAD↔Working tree, Index↔Working tree (unstaged) and HEAD↔Index (staged). |
| DF-09 | done | Images go to the image comparison, ahead of the global external tool (TortoiseGit's PickDiffTool order). Binary files show 'Binary files differ — no text comparison is possible.' The status-list Show Diff already goes through present(). |
| DF-10 | done | New UnifiedDiffWindowController: TortoiseGitUDiff-style colouring, find, Open, From Clipboard, Save As, Print, and an optional external unified viewer setting. |
| DF-11 | partial | Done: target can be the working tree (WT button or empty field), Diff Options menu, Show Log, empty-tree fallback when HEAD~1 is missing, path filter. Remaining: log restricted to rev1..rev2 (LogWindowController takes no range) and the View Patch side pane. |
| DF-12 | done | Context menu: Compare (several files), Show Unified Diff, external compare, Revert to A/B (checkout, or rm if the file does not exist there), Blame, Submodule Diff, Show Log, patch for selection, Export selection, Save list, Copy paths, Copy all information. Renames show old → new. 'No differences found!' state. |
| DF-13 | done | SubmoduleDiffWindowController: From/To hashes and subjects, change type (fast-forward, rewind, newer/older/same time, new, deleted, identical), Show Log, Show Differences, Update Submodule. |
| DF-14 | done | ExternalToolLauncher plus ExternalToolCommand: TortoiseGit %base/%mine/%theirs/%merged/%bname/... and git $LOCAL/$REMOTE/$BASE/$MERGED placeholders, per-extension and per-file tables, ⌥ inverts built-in/external, .app bundles opened via open -a, merge tool with block/trust behaviour and helper files. |
| DF-15 | partial | Done: rebuilt on NSScrollView magnification with side-by-side (linked or not, horizontal or vertical), overlay alpha, difference blend (XOR-like), curtain, zoom/fit/1:1, drag to pan, multi-frame navigation, size/DPI/bit-depth info, checkerboard behind transparency. Remaining: three-way image resolution, alpha keyboard shortcuts, transparent colour choice, Open dialog. |
| DF-16 | done | Diff on a folder opens Compare Revisions (HEAD ↔ working tree) limited to that folder; a submodule folder opens the submodule diff instead. |
| DF-17 | done | Each side's encoding (BOM, UTF-8, UTF-16/32, Windows-1252 fallback) and EOL style are shown in the status bar. Non-UTF-8 diff output is decoded with the same fallback. An option ignores line endings. |
| MG-01 | done | Theirs \| Base (toggle) \| Mine panes with line-number gutters. Lines that differ from base are tinted, and the current conflict is highlighted in all panes and in the merged text. No three-column locator bar. |
| MG-02 | partial | Done: per-block Use Theirs / Use Mine / Use Base and both orderings (Theirs then Mine, Mine then Theirs), plus all conflicts at once. Remaining: line-level selection, prepend/append, mark/unmark blocks. |
| MG-03 | partial | Done: the merged text is the source of truth, so block choices and hand edits share one undo/redo history (resolutions no longer discard edits); find bar, go to line, standard cut/copy/paste. Remaining: convert tabs/spaces, trim right. |
| MG-04 | partial | Done: stages and the working file are decoded with encoding/BOM detection; the result is written back with the same encoding, BOM and EOL, with a UTF-8 fallback prompt; the status bar shows both. Remaining: combos to change encoding/EOL, EditorConfig. |
| MG-05 | done | Pane titles follow MERGE_HEAD (name-rev), CHERRY_PICK_HEAD, REVERT_HEAD and rebase head-name/onto; panes are swapped during a rebase as TortoiseGit does. file.BASE/LOCAL/REMOTE helper files are written for external tools and removed on Mark as Resolved or close. |
| MG-06 | done | ls-files -u stages are classified. Delete/modify, binary, symlink and submodule conflicts get a sheet with Use Mine / Use Theirs (checkout --ours/--theirs + add, rm, or update-index --cacheinfo for gitlinks); images can be compared. |
| MG-07 | done | Starts from the working file (git's own conflict hunks, keeping any edits). 'Restart from Git's merge result' runs git merge-file -p --diff3 with friendly labels; the engine is a fallback or can be chosen by setting. |
| MG-08 | skipped | The Resolve dialog is RV-06 (Status area). MergeWindowController.afterResolve(root:operation:) is ready to reuse. |
| MG-09 | partial | Done: two-file compare (DiffWindowController(leftFile:rightFile:) / presentFiles) and jump to the first difference or conflict on load. Remaining: one-pane mode, switch left/right, read-only flag, editing in two-file mode. |
| MG-10 | partial | Done: the unified viewer doubles as a patch reviewer — file list (red when git apply --check fails), side-by-side preview per file, Apply Selected/All (--include) through ProgressWindowController, Reversed, Add new files to Git, From Clipboard. Remaining: automatic base retrieval and a Finder 'Review/apply single patch' entry (UnifiedDiffWindowController.openPatchFile is ready). |
| MG-11 | partial | Done: Settings ▸ Tools 'Merge Tool' and 'Viewer & Editor' tabs (show base pane, start from git result, .orig backup, inline mode, max inline length, collapse, wrap); font, tab width and colours on Colors. Remaining: jump options, default-UTF-8, EditorConfig, ignore case/comments. |
| MG-12 | partial | Done: status-bar unresolved count, Mine/Theirs +/− against base, encoding and EOL; line-state markers in the gutters. Remaining: ribbon, whitespace-only and moved line icons. |
| MG-13 | partial | Done: in-window shortcuts F8/⇧F8 conflicts, ⌃F9/⌃F10 use theirs/mine, ⇧⌃F9/⇧⌃F10 both orderings, ⌘S save, ⌘↩ resolve, ⌘F, ⌘L; diff window F7/⇧F7, F12, ⌘F, ⌘L, ⌘R. Remaining: a Merge entry in the main menu (MainMenu.swift is shared), Ctrl-Tab pane switching. |
| MG-14 | skipped | Depends on ST-01 in the status/commit lists (Status area). They should call MergeWindowController.present(file:repository:), which also honours the external merge tool setting. |
| MG-15 | done | After Mark as Resolved: offers Edit Next Conflict while unmerged files remain, otherwise Commit… for a merge or Continue Rebase / Cherry-pick / Revert through ProgressWindowController with GIT_EDITOR=true. Refresh happens via the git mutation hook and RepositoryEvents.post on save. |
| MG-16 | skipped | No three-way image merge yet; a binary image conflict can only open a Mine vs Theirs image comparison before choosing a side. |
| MG-17 | skipped | The automation flags (/base /mine /theirs /merged /oneway …) belong to AU-02 (URL-scheme parameters) in P10. |
| SE-11 | done | Settings ▸ Tools has three tabs: Diff Viewer (built-in vs external, program, arguments with placeholder legend, unified diff viewer, per-extension table), Merge Tool (external toggle, program, arguments, block/trust popup, per-extension table) and Viewer & Editor (alternative editor). All values are read by ExternalToolLauncher. |
| SE-13 | partial | Done: unified-diff header and position colours, diff font, size and tab width on the Colors pane. Remaining: the Blame half (age-gradient endpoints, move/copy detection thresholds, first-parent, follow renames) belongs to the Blame pane, which is not in this area. |
| QF-28 | done | Files that are not conflicted or not text no longer report 'Clean merge'. The editor says the file is not conflicted or is binary and disables the resolve actions. Non-UTF-8 files are decoded instead of becoming empty. |
| diffprevious | done | PangolinCommand.diffPrevious = "diffprevious", routed to DiffWindowController.presentPrevious(filePath:repository:). |

Open follow-ups reported by this area:

- Finder area: add menu entries for pangolingit://diffprevious (files and folders) and for two-file Diff (send both paths to `diff`), plus a 'Review/apply single patch…' entry for .patch/.diff files that calls UnifiedDiffWindowController.openPatchFile(_:repository:) (needs a command name, e.g. 'reviewpatch', or route via the Patches area).
- Status area (ST-01 / RV-06 / MG-14): 'Edit conflicts' in status/commit lists should call MergeWindowController.present(file:repository:). The Resolve dialog can reuse MergeWindowController.afterResolve(root:operation:) for the Commit / Continue hand-off. 'Open with alternative editor' (ST-10) can call ExternalToolLauncher.openInAlternativeEditor(_:).
- RefLog, Blame and Changed-files owners: replace direct `DiffWindowController(filePath:oldRevision:newRevision:)` construction with `DiffWindowController.present(filePath:oldRevision:newRevision:repository:)`. That gives folders the Compare Revisions list, images the image diff, submodules the submodule diff and the external tool setting (RefLogWindowController.swift:145, BlameWindowController.swift:431, ChangedFilesWindowController.swift:67/186).
- Log area: LogWindowController cannot be opened on a revision range or path. Compare Revisions' 'Show Log' and the submodule diff's per-side 'Show Log' open the plain log; an init taking a range or path filter would complete DF-11 and DF-13.
- Blame area (SE-13 remainder): age-gradient endpoints, move/copy detection thresholds, first-parent and follow-renames settings on the Blame pane.
- MainMenu owner (MG-13): optionally add a 'Merge'/'Diff' main-menu section with the shortcuts listed above. They currently work as in-window key equivalents only, and there is no Find menu item in the app's Edit menu.
- Repository hygiene: PangolinGitCore/.build (SwiftPM build output) is tracked in git, so any `swift test` run dirties the tree. Consider removing it from the index and adding it to .gitignore.
- Coordinator: project.pbxproj is regenerated by xcodegen in every branch; on merge conflicts just re-run `xcodegen generate`.

#### P5 — Branching and history rewriting

33 done, 9 partial, 1 skipped.

| Item | State | Notes |
|---|---|---|
| SW-01 | done | Switch uses RevisionChooserView (branch incl. remote / tag / commit), with an optional initial target |
| SW-02 | done | Track tri-state (--track/--no-track/default), Override branch (-B) and --merge, built by GitSwitchOptions |
| SW-03 | done | Switch dialog and Browse References both offer to create a local tracking branch (or switch to the existing local one, or use a detached HEAD) |
| SW-04 | done | Offers to stash before the checkout. Runs in the progress window. After success: Stash Pop, Update Submodules, Pull, Merge, Show Log. After failure: Stash and Retry, Checkout with Merge, Resolve |
| SW-05 | done | Detached-HEAD warning (can be turned off); live check-ref-format validation; warns about clashes with existing branches and tags |
| SW-06 | done | Checkouts run through the progress window and the git mutation observer; the Switch window also watches RepositoryEvents |
| BT-01 | done | Annotated tag (message) and signed tag (-s, message required); push the tag to a chosen remote; branch description written via git config |
| BT-02 | done | Base On chooser, Track tri-state, live name validation, stash offer on switch, errors shown in the progress window, Update Submodules post-action |
| BR-01 | done | Filter with a field menu (Refname / Subject / Authors / SHA-1) |
| BR-02 | done | Namespace tree built from '/' (GitRefTreeNode), with stash and notes, remotes as sub-nodes, and Show nested refs |
| BR-03 | done | All TortoiseGit columns (tracked branch with ahead/behind, last commit, author and date, committer and date, SHA-1, description); every column sortable |
| BR-04 | done | All / Only merged / Only unmerged to HEAD (for-each-ref --merged/--no-merged) and a Current Branch button |
| BR-05 | done | F2 and Rename… open a rename sheet (not edited in the row itself) running git branch --move; Edit Description… writes branch.X.description |
| BR-06 | partial | Context menu has Switch, Merge to current, Rebase onto, Create branch/tag, Show RefLog, Browse repository, Compare with working tree and HEAD, Fetch, Select/Unset tracked branch, two-ref Compare and unified diff, Copy. Missing: Show Log for a ref and A..B / A...B log ranges, because LogWindowController cannot start at a ref or range (LG-01, Log area) |
| BR-07 | done | Multi-select delete of branches, remote branches (grouped per remote) and tags in one progress run, with a warning for unmerged branches; Delete All Tags; Delete Remote Tags dialog (ls-remote, then push --delete) |
| BR-08 | done | Remotes node: Manage Remotes, Fetch All. Each remote: Fetch, Delete Remote Tags, Manage Remotes. Tags node: Create Tag, Delete All. Heads node: Create Branch |
| BR-09 | done | Shows 'Showing N refs, N selected'; reloads on RepositoryEvents |
| BR-10 | partial | New rangeCompletion init returns two refs, but nothing calls it yet: Compare Revisions (Diff area) and the Log still need to adopt it |
| BR-11 | done | New MergeBranchWindowController: source chooser, Squash, No FF, FF only, No Commit, Messages (--log=N), unrelated histories, strategy and option, message, stash offer, post-actions. Wired as command 'mergebranch' |
| BR-12 | done | The Merge dialog shows a 'merge in progress' box that explains the state, with Resolve/Commit and Abort Merge; conflict lists explain ours/theirs for merge versus rebase; MergeBranchWindowController.confirmAndAbortMerge is reusable |
| RB-01 | done | Reword asks for the new message; the todo becomes pick + exec git commit --amend -F <file>, with the file kept in .git/pangolin-rebase (tested against real git) |
| RB-02 | done | Detects a stopped rebase in .git/rebase-merge and shows steps done, the current step and remaining steps, a Conflict Files tab with actions, and Continue / Skip / Amend… (at an edit stop) / Abort |
| RB-03 | done | Branch combo, upstream chooser, swap, --onto with picker, Force rebase, Preserve merges (--rebase-merges, list read-only), Autostash, Autosquash (applied to the visible list). The '-x' option is in cherry-pick |
| RB-04 | done | Keys: Space cycles, P / Q / F / E / R / S set the action, U / D move, Cmd-A selects all. Per-commit context menu, Add… from the Log, Pick All / Squash All / Edit All / Skip Unselected, drag-and-drop reordering |
| RB-05 | partial | Tabs: Commit Message, Revision Files, Conflict Files; progress bar shows 'Rebasing (n/m)'. git output streams in the shared progress window instead of a Log tab |
| RB-06 | partial | Done: stash offer (or autostash), up-to-date and fast-forward detection, post-actions (Show Log, Push…, Stash Pop, Show Rebase). Missing: auto-skip of failed commits, the empty-commit prompt, the pre-rebase hook prompt, and Send Mail / Restart |
| RB-07 | partial | The rebase window handles stopped plain rebases (e.g. from pull --rebase), and RebaseWindowController(upstream:branch:) is ready. Log area still needs a 'Rebase current onto this' item |
| RB-08 | partial | New CherryPickWindowController: multiple commits sorted oldest first, pick or skip, reorder, Add from Log, -x, -m parent for merges, no-commit, sign-off, stash offer, conflict list with Continue / Skip / Abort. Missing: squash and edit per commit. The Log needs a 'Cherry Pick…' item (follow-up) |
| BI-01 | partial | Only BisectWindowController(good:bad:) is ready for starting from the Log. Missing: Finder good/bad/skip/reset entries (Finder area, would need new commands) and the Log context items and markers (Log area) |
| BI-02 | done | Stash offer, Update Submodules after each step, bisect run with a chosen script, path limit, custom terms (--term-old/--term-new), revision pickers, Reset with an Update Submodules post-action |
| RL-01 | done | Ref selector with HEAD, local and remote branches and stash; no 200-entry cap |
| RL-02 | done | Columns Ref / SHA-1 / Action / Message / Date; fields split on U+001F with the date from --date=unix (GitReflog, tested) |
| RL-03 | done | Filter field; Delete Entry (reflog delete --rewrite) or stash drop for several entries at once; Clear Stash; stash Apply / Pop / Show Changes / Branch |
| RL-04 | partial | Context menu has Compare with working tree, Compare with previous, two-entry Compare and unified diff, Browse repository, Create branch/tag, Switch, Reset, Copy SHA-1 / messages / all data. Missing: Show Log at commit (no Log API) and Export (Export dialog takes no revision) |
| RL-05 | done | RefLogWindowController(pickerCompletion:) exists, and every RevisionPickerButton ('…') now has 'Choose from RefLog…', which includes Compare Revisions' pickers |
| SS-01 | partial | Done: stash offer before switch, create-and-switch, merge, rebase, cherry-pick and bisect. Missing: the offer before pull (Remote area), a status dialog button, and the Log working-tree entry |
| SS-02 | done | --all (ignored files) with a warning about what -u / --all delete; stash limited to selected paths (the router passes the Finder selection); stash branch |
| SS-03 | done | Stash list = RefLog on refs/stash (command 'stashlist') and the Stash window with a diff preview, Apply / Pop / Drop / Clear / Branch, and a Show Changes offer after apply or pop |
| SS-04 | skipped | Stash label in the Log graph belongs to LG-02 (Log area) |
| SS-05 | done | Stash windows observe RepositoryEvents; apply and pop run in the progress window with Show Changes / Resolve post-actions |
| CV-01 | done | The new Merge dialog uses RevisionChooserView (Switch, Rebase and Branch already did) |
| QF-14 | done | Reword works and an in-progress rebase is detected (RB-01, RB-02) |
| QF-18 | done | RefLog parser no longer cuts subjects at '\|' (RL-02) |

Open follow-ups reported by this area:

- Finder area: add menu entries for mergebranch, cherrypick, stashpop, stashapply and stashlist. Hide Merge… while merging or bisecting; show Stash Pop / Apply / List only when refs/stash exists (StashActions.hasStashes). Bisect good/bad/skip/reset entries (BI-01) need new commands; BisectWindowController already has the step logic.
- Log area: add context items using the new entry points: Merge to current (MergeBranchWindowController(repositoryPath:initialRevision:)), Cherry Pick selected commits (CherryPickWindowController(repositoryPath:commits:)), Rebase current onto this (RebaseWindowController(repositoryPath:upstream:)), Bisect start with two selected commits (BisectWindowController(repositoryPath:good:bad:)), Switch to this (SwitchWindowController(repositoryPath:initialTarget:)), Show RefLog (RefLogWindowController(repositoryPath:ref:)). LG-01 (log starting at a ref or range) would complete BR-06 Show log / A..B and RL-04 Show log; LG-02 stash and bisect markers cover SS-04 and BI-01.
- Diff area: Compare Revisions could use BrowseRefsWindowController(repositoryPath:rangeCompletion:) to pick both revisions at once (BR-10 range selection).
- Status area: 'abortmerge' can call MergeBranchWindowController.confirmAndAbortMerge(root); ConflictListView (Dialogs/Rebase) is reusable for Resolve.
- Remote area: Pull can use DirtyWorkingTree.prepare(root, operation: "pull", allowContinue:window:) for the stash offer before pull (SS-01), and open RebaseWindowController after a stopped pull --rebase (RB-07).
- Export area: ExportWindowController takes no initial revision, so RefLog and Browse References cannot offer Export at a version (RL-04).
- GitCLIRunner.isMutating does not list 'reflog' (delete/expire) or 'symbolic-ref'. RefLog posts RepositoryEvents by hand for now; the core owner may want to add them.
- Coordinator: when updating doc/FEATURE_COMPARISON.md, RB-05 streams git output in the progress window rather than a Log tab, and RB-06 is missing auto-skip, the empty-commit prompt, the pre-rebase hook prompt, and Send Mail / Restart. The cherry-pick dialog has pick/skip only, no squash or edit.

#### P6 — Remote workflow

25 done, 3 partial, 0 skipped.
Merge: *Delete remote tags* uses the Branching area's dialog; the Remote area's duplicate was dropped.

| Item | State | Notes |
|---|---|---|
| PF-01 | done | Remote-branch combo filled from refs/remotes/<remote>, default is the upstream's merge branch (else the local name if the remote has it), with a … picker (Log or References) that strips the remote prefix. |
| PF-02 | done | Remote / URL radio pair (RemoteTargetView) in Pull/Fetch and Push. The URL combo uses recentUrls history (now written) and Browse picks a local repository. |
| PF-03 | done | 'All Remotes' popup entry (--all) in Fetch mode. Tags popup Default(<tagopt>)/--tags/--no-tags. Prune is a tri-state labelled with the effective default from remote.<n>.prune or fetch.prune. Depth field, and Unshallow shown only for shallow repositories. |
| PF-04 | done | Squash, no-ff, ff-only, no-commit and autostash, with mutual exclusion; the merge options are disabled under Rebase. Rebase is preselected from branch.<b>.rebase or pull.rebase. |
| PF-05 | done | 'Launch Rebase after fetch' and Sync's Fetch & Rebase: nothing new does nothing; when a fast-forward is possible it asks Fast-forward / Rebase / Cancel; when the branches diverged it opens the Rebase dialog. |
| PF-06 | done | Progress window gets a Resolve… post-action on conflicts (plus Abort Rebase for a rebase pull). Sync has a Conflicts tab with Resolve… and double-click to the merge editor. Resolve… opens the 'resolve' command once it exists, else Check for Modifications. |
| PF-07 | done | Manage… opens the remote editor; dialogs reload remotes via RepositoryEvents. Per-remote key in remote.<n>.sshkey is applied with GIT_SSH_COMMAND (ssh -i … -o IdentitiesOnly=yes); a 'Use the remote's SSH key' checkbox appears in Pull, Push and Sync. |
| PU-01 | done | Editable local-branch combo with picker, 'All branches (--all)' scope, and 'Push to all remotes' (one push per remote). |
| PU-02 | done | Force popup: none / --force-with-lease (+ --force-if-includes) / --force. |
| PU-03 | done | Always push to this remote (branch.<b>.pushRemote), recurse submodules no/check/on-demand, --push-option, --follow-tags, --no-verify and --dry-run. |
| PU-04 | partial | The outgoing-commit preview (remote/branch..local, or 'not on any remote' for a new branch) and the Request Pull… post-action are done. Remaining: RequestPull cannot yet receive the pushed ref (its init takes only the repository). |
| PU-05 | done | Push scope in the dialog covers one tag, all tags and notes (refs/notes/*). Sync's Push menu has Push Tags and Push Notes, and its Tags tab can push or fetch a single tag. |
| SY-01 | done | Tabs: Log (inline git output), In Commits (the pulled range after a pull), In Changes, Conflicts, Out Commits, Out Changes, Ref List (before/after snapshot with fast-forward/rewind/rewritten/new/deleted and 'Hide unchanged'), and Tags (ls-remote vs show-ref). |
| SY-02 | done | Split buttons: Pull (Pull/Fetch/Fetch & Rebase/Fetch All/Remote Update/Clean Up Stale/Compare Tags), Push (Push/Tags/Notes), Submodule (Update/Init/Sync), Stash (Save/Pop/Apply). They run inline in the Log tab with Stop; Shift-click on Pull/Push opens the full dialog. Apply Patch is there; Email Patch appears once a 'sendmail' command exists. |
| SY-03 | done | Local-branch combo, remote popup with Manage…, remote-branch combo with picker, remote URL (and push URL) label, Force (with lease), SSH key checkbox. |
| SY-04 | done | Done: the switch-to-branch prompt when pulling into a branch that is not checked out; the set-upstream suggestion with 'Don't ask again' (Sync) and default -u when there is no upstream (Push); confirm-stop on close while git runs. Skipped: randomised window position, which belongs with its SE-07 setting (off by default in TortoiseGit). |
| CN-01 | partial | --bare (destination gets .git), --no-checkout, --origin, LFS (git-lfs filters via clone --config, disabled when git-lfs is missing) and an SSH key (used for the clone and saved as remote.<origin>.sshkey) are done. Remaining: the 'From SVN repository' group, which belongs to SV-01 (Integrations). |
| CN-02 | done | exactPath init parameter, and an empty target folder is used as is; Browse… for a local URL; .DS_Store ignored when checking for an empty folder. Show Log/Show in Finder and recent repositories are kept. |
| RM-01 | done | New RemotesEditorViewController: rename, URL, separate push URL (set or unset), SSH key + Browse, tagopt Reachable/None/All, prune Default/On/Off, remote.pushDefault. Changes are applied as minimal git commands (unit-tested). |
| RM-02 | done | The remote editor has buttons and a row context menu for Fetch, Prune, Delete Remote Tags…, Copy URL and Remove. DeleteRemoteTagsWindowController lists ls-remote --tags with checkboxes and runs 'push <remote> --delete refs/tags/…'. Its present(repository:remote:) is ready for the Browse References remote-node menu (BR-07/08). |
| RM-03 | partial | Done: Manage… in Pull/Fetch, Push and Sync. Remaining: the Submodule dialog (another area) can call RemoteDialogSupport.manageRemotes(repository:). |
| DA-01 | done | pangolin-askpass is also the last credential.helper, injected through GIT_CONFIG_COUNT so it runs only after the user's own helpers: one username+password form, 'Remember in Keychain' (GitCredentialStore), erase on rejection, quit on cancel. The ssh host-key prompt shows host, key type and fingerprint, with a critical style when the key changed. Settings ▸ Credentials has an on/off toggle and Forget Saved Logins. |
| DA-02 | done | Platform item, implemented the macOS way in the remote editor: 'Add to Agent' runs 'ssh-add --apple-use-keychain <key>' (passphrase via askpass), and 'Edit ~/.ssh/config…' creates the file from a template and opens it. Pageant/PuTTY themselves are not applicable on macOS. |
| DA-03 | done | The environment export from P0 is kept. Settings ▸ Network now also writes http.proxy and http.sslVerify to the global git config and shows the current values. |
| SE-09 | done | New Settings ▸ Git pane, global or per repository (chooser of recent repositories): user.name/email/signingkey, core.autocrlf/safecrlf/quotepath and fetch.prune. An empty field or 'Inherit' leaves the key unset, and the placeholder shows the inherited value. Editors open .git/config, .tgitconfig, ~/.gitconfig, the XDG config and the system config, plus a View Effective Config sheet. |
| SE-10 | done | New Settings ▸ Remote pane: a repository chooser that embeds the same remote editor. |
| QF-08 | done | The dead CredentialPromptWindowController is deleted; its job is now done by the askpass credential-helper form. |
| fetch command | done | PangolinCommand.fetch ('fetch') opens PullFetchWindowController(mode: .fetch). |

Open follow-ups reported by this area:

- Finder area: add a 'Fetch…' Finder menu entry for pangolingit://fetch. A main-menu Repository ▸ Fetch… item would need an AppDelegate selector in MainMenu.swift, which I did not add.
- Status area: when the 'resolve' command lands, the Resolve… post-actions in Pull/Sync pick it up automatically via PangolinCommand(rawValue: "resolve"). No change needed.
- Patches area: if they add 'applypatchserial' and 'sendmail', Sync's Apply Patch… / Email Patch… buttons use them automatically. RequestPullWindowController should accept the pushed ref (and remote) so Push's Request Pull… post-action can pass it (PU-04).
- Branching area: RebaseWindowController should accept an upstream parameter, so 'Launch Rebase after fetch' / Fetch & Rebase can preset the fetched ref when it is not @{upstream} (today it opens with @{upstream}). The Browse References remote-node menu (BR-07/08) can call DeleteRemoteTagsWindowController.present(repository:remote:) and RemoteDialogSupport.manageRemotes(repository:).
- Submodule area (RM-03): add a Manage… button calling RemoteDialogSupport.manageRemotes(repository:).
- Integrations area (SV-01): the 'From SVN repository' clone group (git svn clone -T/-t/-b -r --username) is not implemented.
- Coordinator/docs: README's Keychain claim is now true through the askpass credential helper (Settings ▸ Credentials toggle). Settings now has 13 panes (Git and Remote added); the toolbar may overflow at 680pt width.
- Note for the coordinator: this worktree's branch was created from main (2860c3b), not e660399; I fast-forwarded it to e660399 before working, so the commit sits directly on P0.

#### P7/P8 — Patches, export, mail, submodules, worktrees, repo browser, revision graph, blame

17 done, 12 partial, 1 skipped.
Merge: *Submodule Diff* uses the Diff area's window (also opened from Diff and Compare Revisions); the Tools area's duplicate was dropped.

| Item | State | Notes |
|---|---|---|
| PT-01 | done | FormatPatchWindowController: output folder, Since / Number / Range with … pickers, --no-prefix, --binary, Send mail after create, Save Unified Diff. Runs in the progress window with Show in Finder / Send Mail… post-actions. The init takes since / from / to so the Log can open it. |
| PT-02 | done | ApplyPatchSeriesWindowController: ordered list with Add / Remove / Up / Down, Finder drag-and-drop, drag to reorder and preview. Options --3way, --ignore-space-change, --signoff, --keep-cr. When git am fails, the progress window offers Resolved, Skip and Abort. Detects a rebase-apply session that is still in progress. |
| PT-03 | partial | Patches can be reviewed in the new viewer and applied with git apply or git am. Remaining: the per-file preview and apply inside the merge editor (MG-10, Diff area). |
| PT-04 | done | Patch window: limited to the Finder selection; working tree, staged (--cached) or two revisions with pickers; --binary. Apply adds a Check button (--check), Reverse (-R) and --index, and runs in the progress window. |
| PT-05 | done | PatchViewerWindowController: coloured unified diff, Find bar, summary, Save As, Apply… (mbox patches go to Apply Patch Serial, plain diffs to git apply). .patch and .diff are registered in Info.plist as an Alternate handler, and AppDelegate gets application(_:open:). |
| SM-01 | done | SendMailWindowController: To, CC, Subject, message body, patch list with drag-and-drop and double-click preview, Patch as attachment, Combine into one mail. Sends through the Mail app (NSSharingService composeEmail, or mailto: for inline mail, which keeps CC) or through git send-email --confirm=never using sendemail.* config. Recipients and options are remembered. |
| RP-01 | partial | Added … pickers on start and end, a Send Mail… button, Send mail after create, and init(start:end:). The upstream default was already there. Remaining: launching it from the Push post-action (Push area). |
| EX-01 | done | Exports the whole project or only the Finder selection (git archive <rev> <paths>), takes a preset revision in the init, asks before overwriting a file or a non-empty folder, and creates the destination folder. The revision chooser and async tar were already in place from P0. |
| EX-02 | partial | Export This Version… is in the Revision Graph menu, and Export… is in the Repository Browser for folders. The Log and RefLog entries remain (their areas; they can call ExportWindowController(repositoryPath:revision:)). |
| SU-01 | done | SubmoduleAddWindowController: URL combo with recent URLs and clipboard, path with Browse and auto-fill from the repository name, Branch (-b), Force. Runs in the progress window with a Commit… post-action. The PuTTY key option is Windows-only and is not applicable. |
| SU-02 | done | SubmoduleUpdateWindowController: checkbox list preselected from the selected rows or folders, Whole project, --init, --recursive, --force, --no-fetch, --remote, and checkout / --merge / --rebase. Runs in the progress window. |
| SU-03 | partial | Sync now runs in the progress window and acts on the selection. Added SubmoduleSupport.updatePostAction(repository:) for other dialogs. Remaining: the Finder Sync entry (Finder area) and wiring that post-action into Switch / Reset / Pull (those areas). |
| SU-04 | done | Remove… runs deinit -f, then git rm -f (which removes the .gitmodules entry), then deletes .git/modules/<name>, and offers Commit…. The row menu has Show Log of Submodule, Submodule Diff, Check for Modifications, Commit Submodule…, Show in Finder and Copy Path / URL. |
| SU-05 | partial | SubmoduleDiffWindowController: from / to hashes and subjects, change type (new, deleted, fast-forward, rewind, newer / older / same time), dirty flag, Show Log, Update, Show Differences. Remaining: the submodule conflict dialog (MG-06) and dirty-submodule indicators in status lists (Status area). |
| WT-01 | done | WorktreeAddWindowController: directory with Browse; base on HEAD / Branch / Tag / Commit via RevisionChooserView; optional new branch (suggested from a remote branch); Checkout toggle (--no-checkout); Force; Detach. Runs in the progress window with Show in Finder and Show Log post-actions. |
| WT-02 | done | Columns Path, Hash, Branch, Locked, Reason (lock or prunable reason). Lock asks for a reason. Prune; double-click opens the folder. The row menu has Finder, Log, Check for Modifications, Lock / Unlock, Remove and Copy Path. If git refuses to remove a worktree, a Force Remove post-action appears; locked worktrees are removed with --force --force. |
| WT-03 | skipped | Platform item: creating a worktree by drag-and-drop needs the Finder drop handler (SH-08, Finder area). WorktreeAddWindowController is ready for that hand-off. |
| RBW-01 | done | Split view: folder tree on the left (repository as root), contents of the selected folder on the right, folders first. buildTree is kept and still tested. |
| RBW-02 | partial | Revision field with the … picker (Log / References), Go and Refresh (⌘R); the window title shows the revision. The Revision Graph opens it at a commit. Remaining: Browse Repository entries in Log / RefLog / Browse References (their areas). |
| RBW-03 | partial | Done: Open, Open With…, Compare with Working Tree, Blame at the revision, Mark for Diff / Diff with marked, Save As (several files go to a folder), Export folders, Revert to This Revision, Show Log (submodules open their own log), Copy Path / hash, drag to Finder via NSFilePromiseProvider, sortable columns, ⌘R. Remaining: alternative editor, Quick Look, the submodule update prompt, and a file-filtered Show Log (the Log has no path filter yet). |
| RG-01 | partial | Done: RevisionGraphWindowController with RevisionGraphBuilder in core (decorated commits, optional branch and merge points, parents rewritten, lanes from CommitGraphLaneEngine). Nodes coloured by ref type; tooltips; zoom − / 100% / Fit / + and pinch; Find with next; scope All / Local / Current; tags toggle; Newest at bottom. Menu: Show Log, Browse, Compare (two nodes / with HEAD), unified diff, Switch, Create Branch / Tag, Export, Format Patch, copy hash / refs, delete branch / tag / remote branch. Save as PNG or PDF; refreshes automatically. Remaining: overview window, SVG / GraphViz export, headless CLI /output. |
| BL-01 | partial | Done: BlameWindowController(filePath:revision:line:); Blame Previous Revision (follows renames via porcelain previous); Compare with Previous (unified diff when the file was renamed); jump to a line; Blame from the Repository Browser and the history pane. Remaining: Show in Log selecting the commit (needs a Log selectCommit API), and Blame entries in Log / Compare Revisions (their areas). |
| BL-02 | done | Detection levels Disabled / -M / -C / -C -C / -C -C -C with a minimum-characters threshold, -w, --first-parent; available in the toolbar and in Settings. The history pane uses log --follow. |
| BL-03 | partial | Done: highlight on hover and selection for all lines of a commit; tooltips with commit, author, date and summary; next / previous block (⌥↑ / ⌥↓); age gradient between Newest and Oldest colours from Settings; dark-mode-safe tints; column toggles (including File and Orig. Line) from the header menu, saved automatically. Remaining: syntax highlighting and line wrap. |
| BL-04 | partial | Git Log pane added (git log --follow): selecting a commit highlights its lines, selecting a line selects its commit, and the pane has its own menu. The full commit message loads into the details area. Remaining: a separate Properties grid. |
| BL-05 | partial | Done: Find navigates instead of filtering (⌘G / ⇧⌘G, Return); Go to Line (⌘L); ⌘C copies lines; encoding menu (UTF-8, Latin-1, CP1252, Mac Roman, UTF-16, Shift JIS). Remaining: Open file / recent files. |
| BL-06 | done | Line menu: Blame Previous Revision, Compare with Previous Revision, Show Log, Copy SHA-1, Copy Log Message, Copy Lines. .mailmap needs no extra code: git blame already applies it to author names in porcelain output. |
| QF-15 | done | Worktree add no longer always creates a new branch. Prune is implemented, and the header comment now matches what the window does. |
| QF-16 | done | Submodule removal is implemented (SU-04), and the header comment now matches what the window does. |
| QF-26 | done | Blame half: row views are reused through makeView, cells are reused, and blameDateFormat is used everywhere. The Log half belongs to the Log area. |

Open follow-ups reported by this area:

- Finder area: add Finder menu entries for formatpatch, applypatchserial, sendmail (works outside a repository, takes the selected .patch files as path= items) and revisiongraph. Add Submodule Add / Update / Sync entries that open SubmoduleAddWindowController(repositoryPath:folder:) and SubmoduleUpdateWindowController(repositoryPath:paths:). WT-03 / SH-08: drag-and-drop New worktree can open WorktreeAddWindowController(repositoryPath:base:).
- Log area: add these to the Log context menus. Format Patch… → FormatPatchWindowController(repositoryPath:since:), or (from:to:) for a range. Export this version… → ExportWindowController(repositoryPath:revision:). Blame → BlameWindowController(filePath:revision:line:). Browse Repository → RepoBrowserWindowController(repositoryPath:initialRevision:). Revision Graph → CommandRouter .revisionGraph. Also add a LogWindowController API that selects a commit (and a path filter) so Blame and Revision Graph 'Show Log' can jump to it.
- RefLog / Browse References areas: Export this version and Browse Repository can use the same inits (EX-02, RBW-02).
- Push area (RP-01 / PU-04): add a Request Pull post-action that opens RequestPullWindowController(repositoryPath:start:end:) with the remote branch and the pushed branch.
- Switch / Reset / Pull areas (SU-03): append SubmoduleSupport.updatePostAction(repository:) to the post-actions; it returns nil when the repository has no .gitmodules.
- Status area (SU-05): show dirty-submodule indicators in status lists; a Submodule Diff row action can open SubmoduleDiffWindowController(repositoryPath:submodulePath:from:to:).
- Diff area: PT-03 / MG-10 per-file patch review in the merge editor. DF-10 can reuse PatchViewerWindowController, whose static colourised(_:) does the diff colouring.
- MainMenu (shared): consider adding Repository menu items for Revision Graph, Create Patch Serial and Apply Patch Serial.
- Coordinator: the PangolinGitCore/.build directory is tracked in git, and `swift test` dirties it. I restored it and left it out of the commit, but it probably belongs in .gitignore.
- Coordinator: the git worktree for this agent was created at 2860c3b instead of the P0 commit; I reset it to e660399 before starting. Other agents' worktrees may have the same problem.

#### P9/P10 — Integrations and platform

20 done, 13 partial, 2 skipped.

| Item | State | Notes |
|---|---|---|
| LF-01 | partial | pangolingit://lfslock and lfsunlock now act on the selected files (progress window; Force Unlock offered after a failed unlock; Pull… offered after a lock; ?force=1 supported). Still to do: the Finder menu entries (Finder area) and the status-list items (ST-17, Status area). |
| LF-02 | done | Locks dialog now has: server or cached (--local) source, filter field, sortable columns, select all, unlock of several locks, Force checkbox, Force Unlock fallback after a refused unlock, git-lfs's own error text, Lock Files… panel and refresh on repository changes. |
| LF-03 | partial | Done: lockable patterns shown and added (git lfs track --lockable); git-lfs installed/initialised check with an Install LFS button. Still to do: the lock-owner badge and the status-list column (Finder and Status areas). |
| LF-04 | skipped | The LFS clone option belongs in the Clone dialog, which the Remote/Clone area owns (CN-01). See follow-ups. |
| GD-01 | done | pangolingit://daemon shows a security warning ('Don't show again' remembers only Proceed). Then a window lists git:// URLs (Bonjour name and IPs), streams `git daemon --verbose --export-all --base-path` and has Stop. The port comes from the Advanced option DaemonPort. |
| SV-01 | partial | Done: svnfetch, svnrebase, svndcommit and svnignore commands. They check for an svn-remote, offer to stash and re-apply local changes, and DCommit asks keep/remove empty dirs, optionally remembered in svn.rmdir. svnignore imports into .gitignore files or info/exclude. Still to do: clone from SVN (Clone area, CN-01) and Finder menu entries shown only for svn repositories (Finder area). |
| BG-01 | partial | Done: Settings ▸ Issue Tracker pane (bugtraq.* at local, .tgitconfig or global level, empty fields inherit), regex tester, message preview. Core BugtraqConfig: message assembly (append/top), Bug-ID parsing back out of a message, one- and two-regex log matching, issue URLs; read via GitConfigStore.bugtraq(). Still to do: Bug-ID field in Commit (Commit area) and Bug-ID column and links in Log (Log area). |
| BG-02 | skipped | macOS-only (🍎) item, deferred as the entry says until BG-01 has consumers in Commit and Log. Proposed route: a JSON-over-stdio issue provider named in bugtraq.provider. |
| SE-08 | done | Settings ▸ Repository pane edits tgit.logminsize, logwidthmarker, warnnosignedoffby, projectlanguage (spell-check language popup) and tgit.icon, at local, project (.tgitconfig) or global level with inherit placeholders. Core ProjectSettings is read via GitConfigStore.projectSettings(). Wiring these values into the Commit dialog belongs to the Commit area. |
| SE-12 | partial | Done: core ClientHookRunner (the six TortoiseGit hook types, path lookup walking up plus '*', TortoiseGit argument order with temp files, message read back, wait or no-wait, .tgitconfig hook.* hooks asking for approval once). Hooks pane: master switch and add/edit/remove table. customHooksDirectory now applies to every git run as core.hooksPath. Still to do: Commit, Push and Rebase dialogs must call ClientHookRunner (other areas). |
| AU-01 | partial | Done: handleURL parses every query item into CommandRouter.shared.options (CommandOptions: rev, startrev, endrev, range, logmsg/logmsgfile, line, closeonend, page, url and so on), set only while execute runs. New `pangolin` CLI (Contents/MacOS, also linked by the cask) accepts both `pangolin log . --rev X` and `/command:log /path:a*b /rev:X`. settings?page= works. Still to do: individual dialogs reading the options (owning areas), and docs/. |
| AU-02 | partial | Done: `pangolin idiff --left A --right B` and pangolingit://imagediff?left=&right= open the image comparison. `pangolin merge --base … --merged R` routes to the existing conflict editor for R only. Still to do: true base/mine/theirs merge and udiff --patchfile (Diff area). |
| WC-01 | done | Engine rewritten in PangolinGitCore (WCRevTemplate, WCRevOptions, WCRevCollector): all GitWCRev keywords including $WCREV=n$, $WCLOGCOUNT&+-$, UTC and strftime forms and every conditional; -m -M -u -U -d -q -s -F (plus -f); exit codes 1 to 11; .gitwcrevignore; two-argument status form; --json. $WCREV$ is now the full hash as in GitWCRev; $WCHASH$, $WCURL$, $WCAUTHOR$ and $WCEMAIL$ are extras. |
| SK-01 | done | Key types Ed25519, ECDSA and RSA with sizes; passphrase passed through a one-shot SSH_ASKPASS (SSH_ASKPASS_REQUIRE=force) that answers a fixed number of prompts; fingerprints; in-agent column; Add to Agent with --apple-use-keychain; import and delete (to Trash); per-repository or global key via core.sshCommand (git has no per-remote key); edit ~/.ssh/config; known_hosts window; Test Connection with the selected key. |
| UP-01 | partial | Done: releases feed with channel choice, an update window (versions, changelog, download list, Download to ~/Downloads with SHA-256 check when a .sha256 asset exists, Skip This Version, Remind Me Later), weekly automatic check, UpdateCheckURL and VersionCheck settings. Still to do: no EdDSA or Sparkle signature verification and no language packs. |
| UP-02 | done | New About window shows app, macOS, git (with path) and git-lfs versions, credits, website, support and contributors links, Check for Updates…, and Copy Version Info. |
| FW-01 | done | Wizard rewritten with pages for language, git (Auto Detect that no longer erases the saved path, Check Now with version, extra PATH), identity ('Don't store now'), authentication (credential helper written to global config; SSH key status plus Manage SSH Keys…) and Finder status. All git calls run asynchronously; closing the window completes the wizard and registers services. |
| FW-02 | done | The Finder-extension prompt now has 'Don't ask again', stored in StoredDecisions and reset from Saved Data. |
| IN-01 | partial | Done: create_dmg.sh uses the real Release build (fails if missing), writes a .sha256 and updates the cask's version and sha256. The cask uses sha256 :no_check until the first published image and installs the `pangolin` binary. uninstall.sh --purge also removes the Group Container, logs and preferences. tools/managed-preferences.mobileconfig is the MDM counterpart of the HKLM policies. Not applicable or not done: notarisation changes, language packs, MSI. |
| PR-04 | done | Core StoredDecisions store, now used by the Finder prompt, daemon warning, LFS force unlock, skipped updates and project hook approval; cleared from Saved Data. Other areas can adopt it for their own prompts. |
| PR-06 | partial | Done: WindowRegistry remembers size and position per dialog type for resizable windows and centres only when no frame is saved; Saved Data resets them. Still to do: a dialog-title style option. |
| PR-08 | partial | Multi-selection added to my tables only: LFS locks (multi-unlock, reveal) and known hosts. Other areas' dialogs are theirs to change. |
| PR-09 | done | Dock menu lists recent repositories with Log, Check for Modifications, Commit, Pull, Push, Sync and Show in Finder. File ▸ Open Recent (rebuilt when opened, with Clear Menu) opens the Log. |
| PR-10 | partial | The spell-check language is stored per project (tgit.projectlanguage, -1 = off) via the Repository pane and ProjectSettings. Still to do: the Commit dialog applying it to NSSpellChecker (Commit area). |
| SE-03 | done | General pane gained (in GeneralSettingsExtras.swift): git --version check, Extra PATH (used by every git run), Show Environment, weekly update check, preview channel, Check Now, language popup (AppleLanguages, takes effect after restart) and Run First-Start Wizard. |
| SE-14 | done | Advanced page is now a typed list (option, value, default, description), checked by type and resettable. Each listed option is read: VersionCheck and UpdateCheckURL (update checker), StyleGitOutput (progress window), MaxLinesInLogfile (action log), DaemonPort, LFSLocksFromServer, SSHKeyDefaultType. TortoiseGit keys with no consumer were left out. |
| SE-15 | done | Saved Data now covers stored decisions, window positions and the action log (~/Library/Logs/PangolinGit/action.log, written for every state-changing git command, Show and Clear, trimmed to MaxLinesInLogfile) next to the existing histories. |
| SE-17 | partial | Done: pangolingit://settings?page=<pane or index>, export and import of all preferences (.plist), tooltips on the panes I own and on new controls. Still to do: tooltips on the other panes and a Help button (PR-05). |
| SE-18 | done | Decision: the Windows pages are not ported. The SSH client override is offered as core.sshCommand (global or per repository) from the SSH window. |
| QF-20 | done | SparkleUpdater renamed to UpdateChecker. It is documented as a plain HTTPS check, not Sparkle. README still needs correcting by the coordinator. |
| QF-22 | done | ssh-keygen and ssh-add no longer receive the passphrase on argv. A temporary askpass helper answers from 0600 files and is removed afterwards. |
| QF-23 | done | pangolin-wcrev links PangolinGitCore and finds git like the app does (configured path, Homebrew, /usr/bin). git failures exit with 6 (git error) or 10 (not a working tree). |
| QF-24 | done | DMG script uses the real build; cask checksum is :no_check until the first release image and is then kept current by create_dmg.sh; purge removes the Group Container. |
| QF-25 | done | Infrastructure only: SWIFT_EMIT_LOC_STRINGS and LOCALIZATION_PREFERS_STRING_CATALOGS on the app target; test that the catalog compiles for de, fr, nl, ja and zh-Hans. No dialogs were swept (CC-06). |
| daemon/lfslock/lfsunlock | done | Added to PangolinCommand and CommandRouter, dispatched through IntegrationCommands. I also added svnfetch, svnrebase, svndcommit, svnignore and updatecheck. |

Open follow-ups reported by this area:

- Finder area: add Finder menu entries for lfslock, lfsunlock and daemon. Add svnfetch, svnrebase, svndcommit and svnignore, shown only when the repository has an `svn-remote.*` config section (IntegrationCommands.isSVNRepository shows the check). Show an LFS lock-owner badge (LF-03) using GitLFS.locks(in:source: .local).
- Status area (ST-17): add Lock and Unlock to the status-list context menu by calling IntegrationCommands.setLocked(_:repository:paths:force:). Add an LFS lock-owner column.
- Commit area: call ClientHookRunner.startCommit when the dialog opens (it may rewrite the message) and preCommit before committing (non-zero exit blocks); call postCommit afterwards. Pass an `approve` closure that asks the user and stores StoredDecisions approvalKey = 1. Add the Bug-ID field from GitConfigStore(repository:).bugtraq() (displayLabel, isValidBugID, messageWithBugID, warnIfNoIssue). Read GitConfigStore.projectSettings(): logMinSize, logWidthMarker, warnNoSignedOffBy, icon, and projectLanguage for NSSpellChecker, where -1 turns spell checking off.
- Push and Rebase areas: call ClientHookRunner.prePush and postPush(error:), and preRebase(upstream:rebasedBranch:), around the git command; abort when the result is not succeeded.
- Log area (LG-13): show a Bug-ID column and clickable links via BugtraqConfig.issueReferences(in:) (ranges plus URLs).
- Clone area (CN-01 / LF-04 / SV-01): add an LFS option (git lfs install --local plus git lfs pull, or just make sure the filters are installed) and clone from SVN (git svn clone with trunk/tags/branches, -r and username). Read CommandRouter.shared.options.string("url") and "exactpath" in the Clone dialog init (AU-01).
- Every area (AU-01): dialogs may read CommandRouter.shared.options in their initialiser, e.g. log rev/startrev/endrev/range, commit logmsg (logMessage), diff/blame line, branch/tag rev/name, stashsave msg, resolve noquestion. closeonend could be applied by ProgressWindowController if it captured options at creation (P0 owner).
- Diff area (AU-02): a standalone three-way merge taking base/mine/theirs/merged from CommandOptions; a unified-diff viewer for --patchfile.
- Coordinator: README still claims Sparkle (QF-20); document the `pangolin` CLI and the new keywords and options of pangolin-wcrev (also: $WCREV$ is now the full hash as in GitWCRev; use $WCREV=7$ for the short one). The installer/ .pkg should also link or ship Contents/MacOS/pangolin if it puts tools on PATH.
- CC-06: switch dialog strings to String(localized:). Extraction into Localizable.xcstrings is now enabled at build time.

## Summary scorecard

Counts are of the deviation entries in this document (one entry may bundle several closely related TortoiseGit sub-features). Totals: 150 missing, 106 partial, 20 broken/dead, 10 platform-specific — 286 entries, plus the 29 quick-fix defects in §18.

| § Area | ❌ Missing | ⚠️ Partial | 🐛 Broken | 🍎 Platform | Headline gap |
|---|---|---|---|---|---|
| 1 Finder integration | 10 | 7 | 0 | 5 | Menu is static: no state-dependent entries, no file/folder distinction, no badge coverage outside `~` and `/Volumes`, no right-drag handler, no Finder property page. |
| 2 Check for Modifications / file list | 12 | 7 | 0 | 0 | No conflict actions, no changelists, no column chooser/sorting, no unified-diff export, no stash button, no LFS/skip-worktree flags. |
| 3 Add / Delete / Rename / Ignore / Clean | 5 | 6 | 1 | 0 | No Clean-up dialog at all; Ignore dialog writes a bogus pattern on the repo root; no "Delete (keep local)" / "Delete and ignore" shortcuts. |
| 4 Commit | 16 | 6 | 1 | 0 | No author/date override, sign-off, message history, autocompletion, partial staging, patch pane, Commit & Push, new-branch, bug-ID. |
| 5 Log / Statistics | 17 | 7 | 1 | 0 | HEAD-only, 500-commit cap, no ref labels, no branch/date/path filters, no multi-selection actions, context menu has 5 of ~35 items. |
| 6 Diff family | 7 | 7 | 3 | 0 | No intra-line diff, no navigation, no whitespace options, no unified-diff viewer, image diff unreachable, no external tool launch. |
| 7 Merge editor / patch apply | 13 | 4 | 0 | 0 | Block-level only, base never shown, no editing/undo/find, no patch-review mode, no encoding/EOL handling, no `.BASE/.LOCAL/.REMOTE` files. |
| 8 Revert / Reset / Resolve | 8 | 3 | 1 | 0 | No Resolve dialog, no Abort-merge dialog, Reset "Log…" cannot pick a commit, no recycle-bin (Trash) safety. |
| 9 Switch / Branch / Refs / Merge | 11 | 8 | 2 | 0 | No Merge dialog at all; Switch lists local branches only; Browse Refs filter is dead and has no context menu; tags are always lightweight. |
| 10 Rebase / Cherry-pick / Bisect / RefLog / Stash | 11 | 7 | 2 | 0 | No cherry-pick UI, no reword, no in-progress detection, no stash diff/list dialog, RefLog is HEAD-only. |
| 11 Remote operations | 13 | 10 | 1 | 1 | No remote-branch pickers, no arbitrary URL, no pull options (ff-only/no-ff/squash/autostash), no Sync tabs, Clone lacks bare/no-checkout/origin/LFS/SVN, no Create-repository command. |
| 12 Export / Patch / Mail / Request pull | 6 | 3 | 0 | 0 | No `format-patch` series, no `git am`, no Send-mail, no revision picker. |
| 13 Submodules / Worktrees / Repo browser / Rev graph / Blame | 5 | 11 | 1 | 1 | Repo browser is a flat file list; no revision-graph window; blame lacks revision navigation, log pane and move detection; worktree add cannot use an existing branch. |
| 14 LFS / daemon / svn / bugtraq | 6 | 1 | 0 | 1 | No lock/unlock from Finder, no daemon, no git-svn, no issue-tracker integration. |
| 15 Settings & hooks | 5 | 8 | 5 | 1 | Most panes store values nothing reads; text fields never persist; no OK/Apply; no client-side hook scripts; no git-config editor pages. |
| 16 Progress & cross-cutting | 3 | 4 | 2 | 0 | No progress dialog is ever shown; no post-action buttons; no abort; windows don't refresh each other after most actions. |
| 17 CLI / WCRev / SSH / update / wizard | 2 | 6 | 0 | 1 | URL scheme carries paths only (no `/rev`, `/logmsg`, …); wcrev has 7 of ~25 keywords; "Sparkle" is a GitHub-page link. |

---

## 1. Finder / shell integration

**Already covered (✅):** FinderSync extension with seven badge kinds (normal, modified, conflicted, added, deleted, ignored, unversioned) rendered from SF Symbols (`PangolinGitFinder/FinderSync.swift:151-176`); a launch-agent status cache that runs `git status --porcelain=v2 -z` per repository, watches with FSEvents (400 ms debounce) and pushes re-badge notifications (`PangolinGitAgent/StatusCache.swift`, `FSEventsWatcher.swift`); folder badges bubble up conflicted > modified (`PangolinGitCore/.../RepositoryStatusSnapshot.swift:33-48`); a toolbar button that opens the same menu; four top-level entries (Commit, Diff, Show Log, Sync) plus a "PangolinGit" submenu with 31 commands; per-command visibility toggles via Settings ▸ Context Menu; `pangolingit://` URL dispatch for multi-selection.

### SH-01 Status-dependent context menu `❌ Missing`
- **What it does:** Shows only the commands that make sense for the clicked item: *Add…* only for unversioned items, *Revert…* only for modified ones, *Edit conflicts* / *Resolve…* only for conflicted files, *Abort Merge* only while `MERGE_HEAD` exists, *Bisect good/bad/skip/reset* only during a bisect, *Stash Pop/Apply/List* only when `refs/stash` exists, *Submodule Update/Sync* only when `.gitmodules` exists, *Commit submodule…* on submodule roots, SVN entries only in git-svn trees, Fetch/Push/Export/Repo-browser on bare repositories.
- **How it works in TortoiseGit:** `src/TortoiseShell/MenuInfo.cpp` carries a per-entry mask of required/forbidden item states; `ContextMenu.cpp` evaluates the selection (status from TGitCache, `MERGE_HEAD`, `BISECT_START`, `refs/stash`, submodule/bare detection) and filters the table before building the menu.
- **Example:** Right-clicking a conflicted `main.c` shows *Edit conflicts* and *Resolve…* first; right-clicking a clean folder shows neither.
- **PangolinGit today:** One static list for every in-repo target (`PangolinGitFinder/FinderSync.swift:19-63, 257-271`). `MenuRules.evaluateState` computes merge/rebase/bisect state (`PangolinGit/Commands/MenuRules.swift:69-88`) but has no callers. The agent already returns the item's status to the extension (`StatusCache.queryStatus`), so the data is available.
- **To implement:** Extend the XPC reply with a `MenuState` (item status, isDir, isSubmodule, isBare, merging/rebasing/bisecting/cherry-picking, hasStash, hasSubmodules), cache it in the extension per path, and give each `MenuEntry` a required/forbidden-state mask like `MenuInfo.cpp`.

### SH-02 File vs. folder vs. multi-selection menus `⚠️ Partial`
- **What it does:** File-only commands (Blame, Edit conflicts, Diff with previous version, Rename) appear only for single files; folder-only commands (Switch, Rebase, Clean up, Create repository, Clone) only for folders; two-file selection offers *Diff* between them; patch files offer *Review/apply single patch* and *Apply patch serial*.
- **How it works in TortoiseGit:** Same `MenuInfo.cpp` masks (`ITEMIS_FOLDER`, `ITEMIS_ONLYONE`, `ITEMIS_TWO`, `ITEMIS_PATCHFILE`, `ITEMIS_INSUBMODULE`, …); the submenu icon changes to show file/folder/link/multiple context.
- **Example:** Selecting `a.c` and `b.c` and choosing *Diff* opens TortoiseGitMerge with the two files; right-clicking `fix.patch` offers *Review/apply single patch…*.
- **PangolinGit today:** Only the first selected path is examined and the same list is offered (`FinderSync.swift:228`); the app rejects wrong targets afterwards with an alert ("Select a file", `PangolinGit/Commands/CommandRouter.swift:213-221`). Multi-selection is forwarded but only `add` and `remove` honour it (`CommandRouter.swift:106-181`).
- **To implement:** Part of SH-01's mask: add `isFile/isFolder/count==1/count==2/isPatchFile` to the selection evaluation; add the two-file Diff and patch-file entries.

### SH-03 Extended menu (Shift + right-click) `❌ Missing`
- **What it does:** Rarely used commands (Show RefLog, Delete (keep local), Delete and add to ignore list, Clean up…, Daemon, Apply patch serial) are hidden unless the user holds Shift while opening the menu; the set is configurable (Settings ▸ Context Menu 2).
- **How it works in TortoiseGit:** `ContextMenuExtended` registry mask; `ContextMenu.cpp` checks `GetAsyncKeyState(VK_SHIFT)`.
- **Example:** Shift + right-click a folder to reach *Clean up…* without cluttering the everyday menu.
- **PangolinGit today:** All 35 entries are always shown; no modifier handling (`FinderSync.swift:221-272`).
- **To implement:** Check `NSEvent.modifierFlags.contains(.shift)` inside `menu(for:)`; add an "extended" flag per `MenuEntry` and a second checklist in Settings ▸ Context Menu.

### SH-04 Badge coverage of arbitrary locations `⚠️ Partial`
- **What it does:** Overlays appear on any working tree on any drive type the user enabled (fixed, removable, network, RAM, CD-ROM, A:/B:), with include/exclude path lists and a "show excluded folders as normal" option.
- **How it works in TortoiseGit:** TGitCache watches every drive root that is enabled in Settings ▸ Icon Overlays; include/exclude patterns with recursive (`\`) and non-recursive (`?`) semantics.
- **Example:** A repository on an external SSD mounted at `/Volumes/Work` or a tree under `/opt/src`.
- **PangolinGit today:** `FIFinderSyncController.directoryURLs` is hard-coded to the real home folder and `/Volumes` (`FinderSync.swift:99-111`); nothing under `/opt`, `/private`, `/Library` or a custom root is badged, and the context menu is not offered there either (menus are only served inside `directoryURLs`).
- **To implement:** Settings ▸ Overlays page with a list of watched roots (default `~` and `/Volumes`), exclude paths and "network volumes" toggle; publish the list through the agent; update `directoryURLs` when it changes.

### SH-05 Assume-valid / skip-worktree overlays and flags `❌ Missing`
- **What it does:** Files flagged `assume-unchanged` ("Needs-lock" icon) or `skip-worktree` ("Locked" icon) get their own overlay; the flags can be set/cleared from the status dialog and the Git property page.
- **How it works in TortoiseGit:** Optional overlay handlers (Settings ▸ Overlay Handlers); status read from the index flags; context items *Assume Unchanged*, *Skip worktree*, *Unflag as skip-worktree and assume-unchanged* run `git update-index --assume-unchanged/--skip-worktree/--no-…`.
- **Example:** A local `config.json` flagged skip-worktree stays untouched by checkouts and shows the padlock badge.
- **PangolinGit today:** `GitBadgeKind.locked` exists in the model (`PangolinGitCore/.../Models/GitStatus.swift:49`) but no badge image is registered and nothing produces it (`FinderSync.swift:151-160`); no flag commands anywhere.
- **To implement:** Read `git ls-files -v` (lower-case = assume-unchanged, `S` = skip-worktree) in the snapshot, map to `.locked`/`.needsLock` badges, add the three context-menu items to the status list.

### SH-06 Unversioned-in-folder and submodule folder propagation options `⚠️ Partial`
- **What it does:** Options "Unversioned files mark parent folder as modified" and "Show status of subrepositories in parent folders".
- **How it works in TortoiseGit:** Settings ▸ Icon Overlays checkboxes; TGitCache aggregates accordingly.
- **Example:** A folder containing only a new, untracked `notes.txt` shows the modified badge so the user notices it before committing.
- **PangolinGit today:** Folder badge stays `normal` when only untracked/ignored children exist (`RepositoryStatusSnapshot.swift:33-35`); submodule roots are badged like plain paths (`GitRepository.swift:166` parses `isSubmodule` but the snapshot ignores it); no settings for either behaviour.
- **To implement:** Two booleans in `ConfigManager`, read in `RepositoryStatusSnapshot.folders` aggregation; treat `isSubmodule` entries as a folder with their own status.

### SH-07 Status cache modes and drive-type/exclusion controls `❌ Missing`
- **What it does:** Choose between the background cache process, shell-internal recursive cache, shell-only (current folder) or no overlays; disable the cache for elevated processes; set max file size for content hashing.
- **How it works in TortoiseGit:** Settings ▸ Icon Overlays radio buttons; advanced `TGitCacheCheckContentMaxSize`.
- **Example:** On a huge monorepo switch to "Shell" mode so Explorer stays responsive.
- **PangolinGit today:** Single mode: whole-repo `git status` per root, refreshed when stale or older than 60 s (`StatusCache.swift:10, 59-62`); `recursiveStatusDepth` is stored but never read by the agent (`ConfigManager.swift:99-102`).
- **To implement:** Add a "cache mode" setting (full / shallow `-uno` / off) and honour `recursiveStatusDepth` by limiting `git status` pathspecs for very large trees.

### SH-08 Right-drag drop handler (Move / Move-and-rename / Copy-and-add / Apply patch / New worktree) `🍎 Platform` + `❌ Missing`
- **What it does:** Dragging items with the right mouse button into a working tree shows a TortoiseGit drop menu: *Git Move versioned item(s) here*, *Git Move and rename versioned item here*, *Git Copy and add files to this WC*, *Review/apply single patch…*, *Apply Patch Serial…*, *Git New worktree…*.
- **How it works in TortoiseGit:** `IDropTarget`/`IShellExtInit` drop handler in the shell extension; `DropMoveCommand`, `DropCopyAddCommand` run `git mv` / copy + `git add`.
- **Example:** Right-drag `src/old/parser.c` to `src/new/` and pick *Git Move versioned item(s) here* so the rename is recorded in the index.
- **PangolinGit today:** Nothing intercepts Finder drags; a Finder move leaves the index with a delete + untracked pair until the user runs Add/Commit. FinderSync has no drop API.
- **To implement (macOS route):** FinderSync cannot add drop menus. Options: (a) detect Finder moves via FSEvents in the agent and offer "Record move in Git?" through a notification; (b) add a *Move/Copy here…* command in the context menu that opens a destination picker and runs `git mv`; (c) a Services/Quick Action "Git Move to…". Document the chosen route.

### SH-09 Left-drag into dialogs and out of file lists `❌ Missing`
- **What it does:** Drop files from Explorer onto the Commit dialog to include/add them; drag entries out of status/commit/log file lists into an editor; drag a file from the repository browser or log into Explorer to export that revision.
- **How it works in TortoiseGit:** OLE drag sources/targets on `GitStatusListCtrl`, `RepositoryBrowser`, log file list.
- **Example:** Drag `README.md` from the Commit dialog's list into VS Code to edit it before committing.
- **PangolinGit today:** No `NSDraggingSource`/`registerForDraggedTypes` on any table (`Views/StatusList/StatusListView.swift`, `Dialogs/RepoBrowser/*`, `Dialogs/Log/*`).
- **To implement:** Register file-URL drag types on `StatusListView`/Log file table (`NSPasteboardWriting` with the absolute path) and a drop target on the Commit window that adds/checks dropped paths; for repo browser exports write the blob to a temp file via `NSFilePromiseProvider`.

### SH-10 Explorer "Git" property page `🍎 Platform` + `❌ Missing`
- **What it does:** A tab inside the normal file Properties window showing current branch, tracked branch and URL, HEAD and last-commit hash/subject/author/date for the file, checkboxes for assume-valid, skip-worktree, executable bit and symlink, and the effective autocrlf/safecrlf/user settings.
- **How it works in TortoiseGit:** `IShellPropSheetExt` (`GITPropertyPage.cpp`).
- **Example:** Check who last touched `Makefile` without opening the log.
- **PangolinGit today:** None. Finder's Get Info panel cannot be extended.
- **To implement (macOS route):** A *Git Info…* context-menu command opening a small window with the same fields and checkboxes (`git log -1 -- path`, `git ls-files -s`, `git update-index --chmod`).

### SH-11 Shortcut (.lnk) handling and submenu icon variants `🍎 Platform`
- **What it does:** For a shortcut inside a repo, two TortoiseGit entries appear (shortcut vs. target); the submenu icon shows file/folder/link/multiple.
- **PangolinGit today:** Aliases/symlinks are passed through as plain paths. Finder symlink semantics differ; low priority. Decide explicitly whether symlinked repos should be resolved (`realpath`) before `GitAdminDir.findRepository`.

### SH-12 Context-menu accelerators and icons toggle `⚠️ Partial`
- **What it does:** Entries have keyboard accelerators (`&Commit…`) and icons; both can be switched off (Advanced `ShellMenuAccelerators`, `ShowContextMenuIcons`).
- **PangolinGit today:** Icons are always shown (`FinderSync.swift:242`); no key equivalents (`keyEquivalent: ""`, `:239`). Finder menus cannot carry mnemonics, but `keyEquivalent` characters are allowed in the toolbar menu.
- **To implement:** A `showMenuIcons` setting relayed through the agent; optional key equivalents for the toolbar-item menu.

### SH-13 Windows 11 compact context menu page `🍎 Platform`
- **What it does:** Chooses which entries appear in the Win11 top-level menu and re-registers the `IExplorerCommand` handler.
- **PangolinGit today:** Not applicable; macOS Sonoma+ collapses extension menus under a submenu automatically. The existing *Context Menu* pane already decides top-level vs. submenu? **No** — the four top-level entries are hard-coded (`FinderSync.swift:19-24`). See SH-14.

### SH-14 Configurable top-level vs. submenu placement `❌ Missing`
- **What it does:** Settings ▸ Context Menu lets the user tick which commands appear directly in the Explorer menu instead of the TortoiseGit submenu; *Restore Default*.
- **How it works in TortoiseGit:** `ContextMenuEntries` registry mask consulted by `ContextMenu.cpp` when building the menu.
- **Example:** Put *Show log* and *Commit…* at top level, everything else in the submenu.
- **PangolinGit today:** Top-level entries fixed to Commit/Diff/Show Log/Sync (`FinderSync.swift:19-24`); the settings pane only hides/shows (`Dialogs/Settings/ContextMenuSettingsView.swift:13-44`) and omits `merge`, `rebase`, `filediff`, `branch`, `clone`, `firstrun`, which therefore can never be hidden (`FinderSync.swift:238` defaults to visible).
- **To implement:** Change the per-command value from `Bool` to `{hidden, submenu, topLevel}`; add the missing commands to the pane; add *Restore Default*; have the extension build the two lists from the relayed dictionary.

### SH-15 Hide menus for unversioned paths / exclude paths `❌ Missing`
- **What it does:** Suppress TortoiseGit entries for folders not under version control (Shift restores them) and for a user list of path patterns (`C:\Windows\*`).
- **PangolinGit today:** Outside a known repository root the menu still offers *Git Clone…* and *Settings…* (`FinderSync.swift:248-251`); no exclusion list. The in-repo decision itself depends on a badge having been requested earlier (`knownRoots`, `FinderSync.swift:184-187, 215-219`), so a repository reached by typing a path can be misclassified as "outside".
- **To implement:** Ask the agent synchronously-cached `isInsideRepository(path)` for the menu target instead of relying on `knownRoots`; add "exclude paths" and "hide outside repositories" settings.

### SH-16 Missing shell commands: Fetch…, Merge…, Create repository here, Resolve…, Abort merge, Clean up…, Stash Pop/Apply/List, Bisect good/bad/skip/reset, Submodule Add/Update/Sync as separate entries, Create Patch Serial…, Apply Patch Serial…, Review/apply single patch…, Send Mail…, Daemon, Revision graph, Diff with previous version, Diff later / Diff with "…", Delete (keep local), Delete and add to ignore list, Remove from ignore list, LFS Lock/Unlock, Help, About `❌ Missing`
- **What it does:** Each is a one-click entry point in the Explorer menu (see §9–§14 for the dialogs behind them).
- **PangolinGit today:** The Finder menu offers 35 commands (`FinderSync.swift:19-63`). Missing from it: *Fetch* (only via Pull/Fetch toggle), *Merge* dialog (there is none; "Edit Conflicts…" opens the file merge editor), *Create repository here*, *Resolve…*, *Abort merge*, *Clean up…*, direct stash pop/apply/list, bisect sub-commands, submodule sub-commands, format-patch / apply-series / review-patch / send-mail, daemon, revision graph, diff-with-previous, diff-later, delete-keep-local, delete-and-ignore, unignore, LFS lock/unlock on the selected file, Help, About.
- **To implement:** Add `PangolinCommand` cases + `MenuEntry` rows as each dialog lands (tracked in the per-area sections).

### SH-17 Status badge refresh after in-app actions `⚠️ Partial`
- **What it does:** Overlays update immediately after a TortoiseGit command finishes (the dialog notifies the cache; F5 forces a refresh).
- **PangolinGit today:** The app never calls the agent's `invalidateCache(forPath:)` (`PangolinGitAgent/main.swift:54-57`, no callers in `PangolinGit/`); badges rely solely on FSEvents, which misses index-only changes that arrive within the debounce window or when `.git/index` is rewritten atomically. There is no manual refresh.
- **To implement:** Call `invalidateCache` from `RepositoryEvents.post`; add *Refresh status* to the Finder menu.

### SH-18 Explorer title bar branch / ahead-behind info `🍎 Platform`
- **What it does:** `ModifyExplorerTitle` shows branch name, stash count and ahead/behind in the Explorer window title.
- **PangolinGit today:** Not possible with FinderSync. Alternative: show branch and ahead/behind in the toolbar button tooltip or in a menu header item (disabled `NSMenuItem` at the top of the menu). Record as optional.

### SH-19 Keyboard shortcuts inside dialogs (F5 refresh, Ctrl+Return commit, Ctrl+F search, Ctrl+A/Ctrl+C in lists, Escape clears filters, window-maximise tricks) `⚠️ Partial`
- **PangolinGit today:** Only ⏎ (default button) and ⎋ (cancel) in some dialogs; main-menu shortcuts exist (`App/MainMenu.swift`). No ⌘R refresh, no ⌘⏎ commit from the message view, no ⌘F focus-filter, no ⌘C on table rows (see Cross-cutting in `pangolin_inventory_1`).
- **To implement:** Standard AppKit responder-chain actions per dialog: `⌘R` → reload, `⌘⏎` → default action from text views, `⌘F` → focus search field, `copy:` on tables (paths / hashes), `⌘⇧C` copy hash in Log.

### SH-20 Finder toolbar button menu uses targeted folder `✅ Present` (listed for completeness: `FinderSync.swift:224-226`). No deviation.

### SH-21 "Inaccessible" entry and bare-repository handling `⚠️ Partial`
- **What it does:** Bare repositories get Fetch/Push/Export/Repo-browser/Browse-refs/RefLog/Worktrees entries; unreadable folders show an *Inaccessible…* hint.
- **PangolinGit today:** Bare repos are treated as "no root" and every command alerts "Not a Git working tree" (`CommandRouter.swift:87-93`); the agent returns no badge for bare repos (`StatusCache.swift:125`).
- **To implement:** Let `CommandRouter` accept `locations.isBare` for the subset of commands that work on bare repos (log, browse refs, reflog, repo browser, export, fetch, push, worktree).

---

## 2. Check for Modifications and the shared file list

**Already covered (✅):** "Changed Files" window per repository with All/Modified/Untracked/Staged filter, Refresh, substring filter, checkbox list with Status / File Path / Extension columns, Diff (first checked item), Revert…, Stage, Unstage, Commit… buttons, double-click → diff, context menu with Add / Add folder / Add to ignore list (name, extension, folder, local exclude) / Remove from repository / Restore / Show Diff / Show in Finder / Copy Path (`PangolinGit/Dialogs/Changed/ChangedFilesWindowController.swift`, `PangolinGit/Views/StatusList/StatusListView.swift`, `StatusListActions.swift`).

### ST-01 Conflict handling in the file list (Edit conflicts, Resolved, Resolve using mine/theirs, Three-way diff) `❌ Missing`
- **What it does:** Conflicted rows get *Edit conflicts* (default action), *Resolved* (`git add`), *Resolve conflict using "theirs" / "mine"* (`git checkout --theirs/--ours` + add; labels show branch names and respect rebase direction) and *Three way diff*.
- **How it works in TortoiseGit:** `GitStatusListCtrl` context menu entries gated on `GIT_STATUS_CONFLICT`; branch names guessed from `MERGE_HEAD`/rebase state.
- **Example:** After a failed pull, right-click `schema.sql` → *Resolve conflict using "theirs"* to accept the incoming version.
- **PangolinGit today:** Conflicted rows are coloured orange but have no actions (`StatusListActions.swift:23-70`); double-click opens the two-way diff, not the merge editor; the merge editor is reachable only from Finder on a single file.
- **To implement:** Add the four items to `StatusListActions.menu` for `.conflicted`; route *Edit conflicts* to `MergeWindowController`; implement mine/theirs with `git checkout --ours|--theirs -- path && git add -- path`.

### ST-02 Changelists (move to / remove from / keep / `ignore-on-commit`) `❌ Missing`
- **What it does:** Group changed files into named local lists shown as group headers in status and commit dialogs; clicking a header selects the group; files in `ignore-on-commit` are unchecked automatically; files leave the list on commit unless *Keep changelists*.
- **How it works in TortoiseGit:** Local store (`.git/tortoisegit.changelist`-style); context menu *Move to changelist ▸ <new changelist> / names*, *Remove from changelist*, *Keep changelists* toggle.
- **Example:** Keep `local.settings.json` in `ignore-on-commit` so it is never committed by accident.
- **PangolinGit today:** None; the list is a flat `NSTableView` (`StatusListView.swift:47-140`).
- **To implement:** Persist `[path: changelist]` per repository in `~/Library/Application Support/PangolinGit/changelists/<repo-hash>.json`; render group rows in `StatusListView`; honour `ignore-on-commit` in the Commit dialog's default check state.

### ST-03 Show unversioned / ignored / flagged / staged / unmodified toggles and "Show whole project" `⚠️ Partial`
- **What it does:** Checkboxes *Show unversioned files*, *Show ignored files*, *Show ignore local changes flagged files* (assume-valid/skip-worktree group), *Show all staged files*, hidden *Show unmodified files*, and *Show Whole Project* (ignore the clicked sub-folder; remembered per repository).
- **PangolinGit today:** Untracked files are always listed and ignored files never; the window always shows the whole repository because the Finder selection is dropped (`CommandRouter.swift:136`); the segmented filter offers All/Modified/Untracked/Staged only (`ChangedFilesWindowController.swift:48-51`).
- **To implement:** Pass the selection into the window; add the checkboxes; run `git status … --ignored=matching -- <pathspec>` and `git ls-files -v` for flagged files; persist "whole project" per repo.

### ST-04 Column chooser, sorting, remembered widths, extra columns (Lines added/removed, Last modified, Size, LFS lock owner) `❌ Missing`
- **What it does:** Right-click the header to pick columns; click to sort; widths/visibility saved per dialog.
- **PangolinGit today:** Fixed four columns, no sort descriptors anywhere in the app (`StatusListView.swift:83-107`).
- **To implement:** `NSTableView` autosave name + `sortDescriptorPrototype` per column, a header context menu, and `git diff --numstat` for the line columns.

### ST-05 Colour coding by status with configurable colours `⚠️ Partial`
- **What it does:** Blue modified, purple added (`+` suffix for add-with-history), dark red deleted/missing, green merged, bright red conflicted; colours from Settings ▸ Colors 1.
- **PangolinGit today:** Hard-coded system colours (`StatusListView.swift:251-268`); the Colors pane stores three hex values nothing reads (`Dialogs/Settings/ColorsSettingsView.swift`, see SE-04).
- **To implement:** Read the status colours from `ConfigManager` in `StatusListView`, `RevertWindowController`, `FileDiffWindowController`.

### ST-06 Summary line with line counts `❌ Missing`
- **What it does:** Footer shows "line: +n -m, files: N modified, N added, …".
- **PangolinGit today:** "N changed file(s)" only (`ChangedFilesWindowController.swift:154`).
- **To implement:** Aggregate `git diff --numstat` (and `--cached`) once per load.

### ST-07 Save unified diff button `❌ Missing`
- **What it does:** Writes a patch of all uncommitted changes and opens it in the unified-diff viewer.
- **PangolinGit today:** Only the Patch window (create mode) does something similar for the whole tree (`Dialogs/Patch/PatchWindowController.swift:117`).
- **To implement:** Button → `git diff HEAD` (plus `--binary` option) → save panel / open in the unified view (see DF-10).

### ST-08 Stash split button (Stash changes / Pop / Apply / List) `❌ Missing`
- **PangolinGit today:** The Stash dialog must be opened from Finder; no button here.
- **To implement:** `NSPopUpButton` with pull-down style calling `git stash push/pop/apply` and opening the Stash dialog.

### ST-09 Batch diff of all checked files, "Compare with base" vs "Compare two files" `⚠️ Partial`
- **What it does:** Diff launches for every selected file (warns above `NumDiffWarning`); selecting exactly two files offers *Compare two files*.
- **PangolinGit today:** *Diff* opens the first checked item only (`ChangedFilesWindowController.swift:183-187`); README claims batch diff (`README.md:13`).
- **To implement:** Loop over checked items (warn above 10); add the two-file compare to the context menu.

### ST-10 Open / Open with… / View in alternative editor / Explore to `⚠️ Partial`
- **PangolinGit today:** *Show in Finder* exists (`StatusListActions.swift:58-64`); no *Open*, *Open with…*, alternative editor.
- **To implement:** `NSWorkspace.open`, an "Open With" submenu built from `NSWorkspace.urlsForApplications(toOpen:)`, and the external-editor setting (SE-11).

### ST-11 Copy to clipboard variants (full paths, relative paths, names, all information, single column) `⚠️ Partial`
- **PangolinGit today:** *Copy Path(s)* copies relative paths only (`StatusListActions.swift:65-68`).
- **To implement:** Submenu with the five variants.

### ST-12 Delete unversioned/ignored/missing files (recycle bin, Shift = permanent) `❌ Missing`
- **What it does:** Remove untracked files from disk via the Recycle Bin; Shift+Delete bypasses it.
- **PangolinGit today:** No delete-from-disk action in the list; the Remove dialog only handles tracked paths (`Dialogs/Remove/RemoveWindowController.swift`).
- **To implement:** `FileManager.trashItem(at:)` for untracked rows; ⌥ modifier for permanent delete.

### ST-13 Revert… from the list (including restoring missing files) `⚠️ Partial`
- **PangolinGit today:** Changed Files has a Revert… button for checked rows (`ChangedFilesWindowController.swift:189-219`), but the shared context menu (used by Commit and Add) has no *Revert* item, and missing files are restored via *Restore* only.
- **To implement:** Add *Revert…* to `StatusListActions`.

### ST-14 Restore after commit `❌ Missing`
- **What it does:** Keep a copy of a file, commit a trimmed version (e.g. after removing debug lines in the merge tool), then restore the full file.
- **PangolinGit today:** None.
- **To implement:** Context item that copies the file to a temp location and restores it after `git commit` succeeds (Commit dialog hook).

### ST-15 Show log / Show log of submodule / Show log before rename / Blame / Export selection to… `❌ Missing`
- **PangolinGit today:** No per-file log, blame or export entries in the status list; Log cannot be opened for a path (LG-04).
- **To implement:** Context items that open `LogWindowController(path:)`, `BlameWindowController`, and a folder-preserving export (`git cat-file` or file copy).

### ST-16 Skip-worktree / Assume-unchanged / Unflag `❌ Missing` (see SH-05).

### ST-17 LFS Lock / Unlock on selected rows `❌ Missing` (see LF-02).

### ST-18 Add as Executable (+x) / Add as Symlink `❌ Missing`
- **How it works in TortoiseGit:** Shift reveals the variants; runs `git update-index --chmod=+x` / symlink mode after add.
- **To implement:** ⌥-variants of the Add item.

### ST-19 Group header select-all, empty-list hint, keyboard toggling of checkboxes `⚠️ Partial`
- **PangolinGit today:** Select All / None buttons exist (`StatusListView.swift:294-304`); no empty-state message, space bar does not toggle (`StatusListView`).
- **To implement:** Empty-state label; `keyDown` space handler toggling the selected rows.

---

## 3. Add, Delete, Rename, Ignore, Clean up

**Already covered (✅):** Add dialog scoped to the Finder selection with checkbox list (`Dialogs/Add/AddWindowController.swift`); Remove dialog with `--cached`, `-f`, `-r` on the whole multi-selection (`Dialogs/Remove/RemoveWindowController.swift`); Rename/Move dialog with `-f` and dry run (`Dialogs/Rename/RenameWindowController.swift`); Ignore dialog with `.gitignore` vs `info/exclude`, exact / extension / custom pattern and live preview (`Dialogs/Ignore/IgnoreWindowController.swift`); rich ignore submenu in the status list (`StatusListActions.swift:122-190`).

### AD-01 Add dialog: Include ignored files `❌ Missing`
- **What it does:** Checkbox to also list ignored files so they can be force-added.
- **PangolinGit today:** Only `.untracked` rows are listed (`AddWindowController.swift:94-113`); no `git add -f`.
- **To implement:** Checkbox → `--ignored=matching` on status, `-f` on add.

### AD-02 Add progress post-actions (Commit…, Add as Executable, Add as Symlink) `❌ Missing`
- **PangolinGit today:** Dialog closes silently after `git add`; no follow-up (`AddWindowController.swift:115-130`).
- **To implement:** Part of the shared progress/post-action dialog (PR-01).

### AD-03 "There is nothing to add" / empty-directory hint `⚠️ Partial`
- **PangolinGit today:** Status text "There are no unversioned files in the selection." exists; no tip about `.gitkeep`. Cosmetic.

### DL-01 Delete confirmation per item with "Yes to all" and warnings for unversioned/modified content `⚠️ Partial`
- **What it does:** Before `git rm -r -f`, warns when a folder contains unversioned or modified files; per-item confirmation.
- **PangolinGit today:** No confirmation at all unless *Force* is ticked (`RemoveWindowController.swift:142-189`); the file is deleted from disk immediately; no Trash.
- **To implement:** Pre-flight `git status -- <paths>` to detect dirty/untracked content; confirmation sheet; move to Trash before `git rm --cached` when `useTrashOnRevert` is on (RV-04).

### DL-02 Delete (keep local) as a one-click command `⚠️ Partial`
- **PangolinGit today:** Available only as the `--cached` checkbox inside the Remove dialog.
- **To implement:** Finder/list entry that pre-ticks `--cached` and skips the dialog.

### DL-03 Delete and add to ignore list (by name / by extension, "keep file locally?") `❌ Missing`
- **To implement:** Finder/list submenu: `git rm --cached` then `GitIgnoreFile.append`.

### DL-04 Missing files auto-marked deleted on commit `✅ Present` (commit passes `--only -- <paths>` for checked missing rows, `CommitWindowController.swift:196-200`).

### RN-01 Rename dialog: file chooser, `..\` moves, name validation, submodule support `⚠️ Partial`
- **What it does:** `…` opens a file chooser; validates illegal names and same-working-tree constraint; works for submodules.
- **PangolinGit today:** Free-text destination with no picker, no validation that the source is tracked, no submodule handling (`RenameWindowController.swift:46-67, 140-197`); first selected item only (`CommandRouter.swift:176`).
- **To implement:** Add an `NSSavePanel`-based picker, `git ls-files --error-unmatch` pre-check, and multi-item move (each item → destination folder).

### RN-02 Case-only rename guidance `✅ Present` (git mv handles it on APFS; no deviation).

### IG-01 Ignore dialog: "only in containing folder" vs "recursively", and `.gitignore` in the containing directory `⚠️ Partial`
- **What it does:** Three ignore-file targets (root `.gitignore`, `.gitignore` next to the item, `info/exclude`) × two scopes (this folder only / recursive).
- **PangolinGit today:** Root `.gitignore` or `info/exclude` only; scope is implicit in the chosen pattern (`IgnoreWindowController.swift:65-73, 144-153`).
- **To implement:** Add the "containing directory" target and a scope radio that chooses between `/dir/name` and `name` patterns (the builders already exist in `GitIgnoreFile`).

### IG-02 Ignore dialog on the repository root writes `/new-file.txt` `🐛 Broken`
- **PangolinGit today:** With relative path `""` the "Exact file path" radio is labelled `file.txt` and appends the literal `/new-file.txt` (`IgnoreWindowController.swift:81, 147`).
- **To implement:** Disable the exact-path radio (or require a selection) when the target is the root.

### IG-03 Multi-selection in the Ignore dialog `⚠️ Partial`
- **PangolinGit today:** Only `relative.first` is passed (`CommandRouter.swift:157`); the multi-item variants exist only in the status-list submenu (`StatusListActions.swift:122-190`).
- **To implement:** Accept `[String]` and reuse the status-list pattern builders.

### IG-04 Remove from ignore list / warn when ignoring a tracked file `❌ Missing`
- **What it does:** Un-ignore a path; when ignoring a tracked file, offer `git rm --cached`.
- **PangolinGit today:** Pattern is appended even for tracked files, with no warning (`IgnoreWindowController.swift:194-213`); no unignore.
- **To implement:** `git check-ignore -v` to locate the matching line and remove it; `git ls-files --error-unmatch` pre-check.

### CU-01 Clean up dialog (`git clean`) `❌ Missing`
- **What it does:** Remove untracked and/or ignored files and directories with options: *Remove all untracked (-fx)*, *non-ignored untracked (-f)*, *ignored only (-fX)*, *untracked directories (-d)*, *nested repositories (-ff)*, *Do not use recycle bin*, *Dry run*, *Submodules*; by default TortoiseGit dry-runs and moves the files to the Recycle Bin itself, then offers *Clean to recycle bin* / *Clean permanently*.
- **How it works in TortoiseGit:** Extended menu → *Clean up…*; `CleanTypeDlg` + `CleanupCommand`.
- **Example:** Wipe `build/` and stray `*.o` files before a release archive.
- **PangolinGit today:** None. `GitRepository.clean(dryRun:directories:force:)` exists but is uncalled (`GitRepository.swift:465-471`).
- **To implement:** `CleanWindowController` with the seven options; default path = `git clean -n` → list → `FileManager.trashItem` per path (Trash instead of Recycle Bin).

---

## 4. Commit

**Already covered (✅):** Commit window per repository with message editor (continuous spell checking), status list with checkboxes, *Amend Last Commit*, ⏎/⎋, auto-reload on repository events, double-click → diff, context menu as in §2, `git add -A` + `git commit --only` of checked paths, optional Push dialog after commit (`PangolinGit/Dialogs/Commit/CommitWindowController.swift`).

### CM-01 Commit to a new branch `❌ Missing`
- **What it does:** Checkbox *new branch* + name box: creates the branch from the current one and commits there; validates name, warns on tag clash; detached HEAD prompts "create a branch now?".
- **How it works in TortoiseGit:** `git checkout -b <name>` before `git commit`.
- **Example:** You started hacking on `main` and want the commit on `feature/x` instead.
- **PangolinGit today:** None (`CommitWindowController.swift:46-129`).
- **To implement:** Checkbox + field; run `git switch -c` first; detached-HEAD detection via `rev-parse --abbrev-ref HEAD == "HEAD"`.

### CM-02 Set author / Set author date / Reset date `❌ Missing`
- **What it does:** Override `--author="Name <mail>"` and `--date=` (date/time pickers; *Reset* uses `now` when amending).
- **Example:** Committing a patch received by mail on behalf of its author.
- **PangolinGit today:** None.
- **To implement:** Two optional controls; append `--author`/`--date` to the argv at `CommitWindowController.swift:196-200`.

### CM-03 Add Signed-off-by (button + warn-if-missing) `❌ Missing`
- **How it works in TortoiseGit:** Button appends `Signed-off-by: Name <email>`; `tgit.warnnosignedoffby` config prompts on commit.
- **To implement:** Button inserting the trailer from `git var GIT_COMMITTER_IDENT`; or pass `--signoff`.

### CM-04 Message only (`--allow-empty`) `❌ Missing`
- **To implement:** Checkbox → `--allow-empty` and skip the "no checked rows" guard.

### CM-05 Amend pre-fills the previous message and "Show diff to last commit" `⚠️ Partial`
- **PangolinGit today:** Amend flag is passed but the message box stays empty, so the user must retype (`CommitWindowController.swift:167-200`); no HEAD~ diff mode.
- **To implement:** On toggle, load `git log -1 --format=%B`; when amending, make double-click diff use `HEAD~1`.

### CM-06 Commit message history (Paste recent message…, Paste last commit message, delete entries) `🐛 Broken`
- **What it does:** Context menu lists the last N messages for this repository (N from Settings); Delete key removes an entry.
- **PangolinGit today:** Messages are saved to `recentCommitMessages` (`CommitWindowController.swift:201`) but never offered anywhere; Saved Data only shows a count.
- **To implement:** Message-view context menu / pop-up with the stored list (keyed per repository, not global); `git log -1 --format=%B` for "last commit message".

### CM-07 Pick commit hash / Pick commit message / Paste filename list `❌ Missing`
- **To implement:** Context items: open Log as a picker (needs LG-23), insert hash or message; insert checked paths.

### CM-08 Autocompletion of file names and identifiers (`autolist.txt`, Ctrl+Space, min chars, snippets) `❌ Missing`
- **What it does:** After 3 characters a dropdown offers names of changed files and identifiers parsed from them via regexes; `snippet.txt` expands shortcuts.
- **PangolinGit today:** None; `NSTextView` default completion only.
- **To implement:** `NSTextView.completions(forPartialWordRange:)` backed by checked file names + a small regex table; snippet file in Application Support.

### CM-09 Commit message template (`commit.template`) and "did not edit template" warning `❌ Missing`
- **To implement:** Read `git config commit.template` on open; compare on commit.

### CM-10 Bug-ID / Issue-Nr field and issue-tracker plugin button `❌ Missing` (see BG-01).

### CM-11 Message formatting (`*bold*`, `_underline_`, `^italic^`), line-width marker (`tgit.logwidthmarker`), min length (`tgit.logminsize`), strip `#` lines, sanitise whitespace `❌ Missing`
- **PangolinGit today:** Plain `NSTextView`, 110 pt fixed height, no guide (`CommitWindowController.swift:46-56`).
- **To implement:** Attributed styling pass on `textDidChange`, a vertical guide at the configured column, disable Commit below min length, strip comment lines before commit.

### CM-12 Staging support (index-state checkboxes, partial staging/unstaging of hunks and lines, View Patch pane) `❌ Missing`
- **What it does:** Checkboxes reflect staged/partially-staged state; *Partial Staging>>* opens the patch pane where hunks or selected lines can be staged/unstaged; *View Patch>>* shows the diff of the selected file beside the list.
- **How it works in TortoiseGit:** `git apply --cached` of edited hunks; `tgit.commitstagingsupport`, `tgit.commitshowpatch`.
- **Example:** Commit only the bug fix from a file that also contains unrelated refactoring.
- **PangolinGit today:** Checked = whole file; staging happens with `git add -A` right before commit (`CommitWindowController.swift:196`); no patch pane.
- **To implement:** Side pane using `SideBySideDiffView` (unified mode) with per-hunk checkboxes; stage via `git apply --cached` of the selected hunks (`GitPatch.parse` already parses hunks: `Core/Git/GitPatch.swift`).

### CM-13 Quick-select links (All / None / Unversioned / Versioned / Added / Deleted / Modified / Files / Submodules) `⚠️ Partial`
- **PangolinGit today:** Select All / None only (`StatusListView.swift:294-304`).
- **To implement:** Extra links filtering by `GitItemStatus`.

### CM-14 Show Unversioned Files / Show Whole Project / Do not autoselect submodules `⚠️ Partial`
- **PangolinGit today:** Untracked always listed; always whole project (selection ignored, `CommandRouter.swift:106`); submodules not distinguished.
- **To implement:** Same as ST-03 plus a submodule flag from `--porcelain=v2` `S` field.

### CM-15 Commit button drop-down: ReCommit, Commit & Push `❌ Missing`
- **PangolinGit today:** Single Commit button; global *Show the Push dialog after a successful commit* preference (`CommitWindowController.swift:201-207`).
- **To implement:** Pull-down button with *Commit*, *Commit & Push* (push without dialog when upstream exists), *ReCommit* (keep window open, reload).

### CM-16 Dirty-submodule warning, missing-but-staged handling, merge-commit hint, conflict-marker hint `❌ Missing`
- **To implement:** Pre-commit checks: `git submodule status` for `+` entries; `grep -l '^<<<<<<<'` on checked files; `MERGE_HEAD` banner that disables unchecking.

### CM-17 Hooks (start-commit / pre-commit / post-commit client scripts) `❌ Missing` (see SE-12).

### CM-18 Cancel confirmation when a message was typed `❌ Missing`
- **To implement:** `windowShouldClose` check on non-empty text.

### CM-19 Commit progress dialog with post-actions (ReCommit, Push, Pull, Create Tag) `❌ Missing` (see PR-01).

### CM-20 Resizable message/file splitter, customisable columns `⚠️ Partial`
- **PangolinGit today:** Fixed 110 pt message area (`CommitWindowController.swift:55`).
- **To implement:** `NSSplitView` with autosave.

### CM-21 Error reporting `⚠️ Partial`
- **PangolinGit today:** "Commit failed: <stderr>" in a one-line status label (`CommitWindowController.swift:208-212`); hook output is invisible on success.
- **To implement:** PR-01.

### CM-22 Commit from Finder honours the selected files/folder `⚠️ Partial`
- **What it does:** The dialog is pre-populated with the clicked paths and their children; other changes are hidden unless *Show Whole Project*.
- **PangolinGit today:** Whole working tree every time (`CommandRouter.swift:106`).
- **To implement:** Pass `relative` paths to `CommitWindowController` and pre-check only those.

### CM-23 Ctrl+Return to commit from the message box `❌ Missing` (see SH-19).

---

## 5. Log and Statistics

**Already covered (✅):** Log window per repository with Graph / Commit / Message / Author / Date columns, lane graph, substring filter (subject, author, hash), detail pane (hash, author, date, committer, parents, body), changed-files pane via `diff-tree --name-status`, context menu (Copy Hash, Create Branch Here, Create Tag Here, Revert this Commit, Reset Current Branch to Here), double-click copies the hash, auto-reload on repository events (`PangolinGit/Dialogs/Log/LogWindowController.swift`); Statistics window with commits by author / month / weekday and a bar chart (`Dialogs/Statistics/StatisticsWindowController.swift`).

### LG-01 Branch / revision filter (current branch, All branches tri-state, basic refs, local branches, Browse References picker, range `A..B` / `A...B` / `A B`) `❌ Missing`
- **What it does:** A button shows the current ref; clicking opens the reference browser to select one or several refs; checkbox *All Branches* cycles all / basic refs / local branches (remembered per repo); context menu shortcuts HEAD, FETCH_HEAD, All, All basic refs, All local branches.
- **How it works in TortoiseGit:** `git log <refs>` / `--all` / `--branches`.
- **Example:** Show `origin/release/2.0` history, or everything with `--all` to find a stray branch.
- **PangolinGit today:** Always `git log -n 500 --date-order` from HEAD (`LogWindowController.swift:181-198`, `GitRepository.swift:205-225`).
- **To implement:** Ref button + popover listing refs (reuse Browse References as a picker, BR-10); pass refs/ranges to `getLog(range:)` (already supports a range string).

### LG-02 Ref labels in the message column (tags, local/remote branches, HEAD, stash, bisect markers; label placement, Labels view toggles, symbolised ref names) `❌ Missing`
- **What it does:** Coloured labels for every ref pointing at the commit; the active branch bold; annotated tags marked; options to draw labels right of the message, show subject+body, symbolise `origin/` as `↑`.
- **PangolinGit today:** `GitRevision.refs` is parsed from `%D` (`GitRevision.swift`, `GitRepository.swift:237-240`) but never rendered (`LogWindowController.swift:256-273`); HEAD is not highlighted.
- **To implement:** Custom `NSTableCellView` drawing rounded label chips before/after the subject with colours from Settings (SE-04); View ▸ Labels toggles.

### LG-03 "Working tree changes" virtual entry (with Show Unversioned Files) `❌ Missing`
- **What it does:** Top row representing uncommitted changes; its context menu offers Commit…, Stash, Abort merge, Pull, Fetch, Submodule update, Clean up….
- **To implement:** Prepend a synthetic row when `git status` is non-empty; bottom pane shows the status list.

### LG-04 Path filter: log of a file or folder, Follow renames, Hide/Gray unrelated changed paths `❌ Missing`
- **What it does:** Opening Show Log on a file lists only commits touching it (`-- path`, `--follow`); the bottom pane can hide or grey files outside that path.
- **PangolinGit today:** `log` on a file opens the whole-repository log (`CommandRouter.swift:110`); `getLog(path:)` supports a pathspec but is never given one.
- **To implement:** Pass `relative.first` to the window; add *Follow renames* and *Hide/Gray unrelated* toggles.

### LG-05 Date range (From / To pickers) and default limitation (last N commits / years / months / weeks) `❌ Missing`
- **PangolinGit today:** Hard cap of 500 commits, no date filters (`LogWindowController.swift:187`).
- **To implement:** Two `NSDatePicker`s → `--since/--until`; a limit popover; Settings ▸ Dialogs default; remove the fixed cap (stream with `-n` paging or `--max-count` + "Load more").

### LG-06 Search-engine filter syntax and field selection (Subject, Messages, Paths, Authors, Emails, SHA-1, Refname, Tag info, Notes, Bug-IDs; regex; case-sensitive) `⚠️ Partial`
- **What it does:** Space-separated terms (all must match), `-term` excludes, `+term`, `!` inverts, quoted phrases; field checklist under the magnifier.
- **PangolinGit today:** Case-insensitive substring over subject, author name and full hash (`LogWindowController.swift:200-224`); the graph is hidden while filtering.
- **To implement:** Tokeniser for the syntax; `NSSearchField` menu with field checkboxes, regex and case toggles; keep the graph visible by filtering rows but drawing lanes from the full list.

### LG-07 Walk behaviour (First parent, No merges, Full history, Compressed graph, Show labelled commits only) and Collapse/Expand revisions `❌ Missing`
- **How it works in TortoiseGit:** `--first-parent`, `--no-merges`, `--full-history`, `--simplify-by-decoration`.
- **To implement:** View menu toggles mapped to extra `git log` arguments.

### LG-08 Column set (Actions icons, Email, Commit name/email/date, Bug-ID, SHA-1, ID, SVN rev, REBASE) with header chooser `⚠️ Partial`
- **PangolinGit today:** Five fixed columns (`LogWindowController.swift:68-98`); no header context menu; no action icons (`GitRevision.filesChanged` is never populated).
- **To implement:** Column chooser with autosave; actions column from `--name-status` summary (`-M` for renames).

### LG-09 Navigation (prev/next by author, committer, merge point, parent 1/2, tag, branch, selection history; Alt+Up/Down; Alt+Left/Right history; paste hash to jump) `❌ Missing`
- **To implement:** Navigation popup + two buttons; selection-history stack; `paste:` handler that scrolls to a hash.

### LG-10 Single-revision context menu: Compare with working tree, Compare with previous revision (parent submenu), Show changes as unified diff (merge sub-options), Blame / Blame previous revision, Browse repository, Merge to current, Switch/Checkout to [branch] / to this, Rebase current onto this, Export this version, Cherry Pick this commit, Format Patch, Push label, Delete branch/tag (submenu, All), Edit Notes, Copy to clipboard submenu (full data, SHA-1, authors, names, emails, subjects, messages, tag/branch names), Search log messages, Show branches this commit is on `⚠️ Partial`
- **PangolinGit today:** Five items (`LogWindowController.swift:108-115`): Copy Hash, Create Branch Here, Create Tag Here, Revert this Commit, Reset Current Branch to Here.
- **To implement:** Add the ~20 missing items progressively; most map to existing windows (DiffWindowController with `rev~1..rev`, FileDiff, Blame, RepoBrowser with revision, Export with revision, Switch) plus new ones (Merge dialog BR-12, Cherry-pick RB-08, Format patch PT-01, Notes LG-19, Branches-containing LG-20).

### LG-11 Multi-revision context menu: Compare revisions, unified diff between two, Show log of A..B / B..A / A...B, Compare change sets, Revert these commits, Combine to one commit, Cherry Pick selected, Format Patch range, Bisect start/skip with selection, multi-copy variants `❌ Missing`
- **PangolinGit today:** Multi-selection does nothing (`LogWindowController.swift:302-351` acts on `selectedRow`).
- **To implement:** `allowsMultipleSelection = true`; branch the context menu on `selectedRowIndexes.count`.

### LG-12 Bottom-pane (changed files) context menu: Compare with base / working tree / parent, unified diff, Revert to this / parent revision, Show log (file, submodule, before rename), Blame, Save revision to…, Export selection, Open / Open with / alternative editor, Explore to, Copy paths / all information; merge file groups (Merged files, Diff with parent N) `⚠️ Partial`
- **PangolinGit today:** Two-column table with no context menu; double-click opens **HEAD vs working tree**, not the commit vs its parent (`LogWindowController.swift:363-369`, `CommandRouter.swift:112`); renames not detected (`diff-tree` without `-M`).
- **To implement:** Fix double-click to `DiffWindowController(oldRevision: "<sha>~1", newRevision: "<sha>")`; add `-M`; build the context menu.

### LG-13 Gravatar avatars and message pane extras (clickable hashes/URLs/bug IDs, Copy all information, Edit Notes) `❌ Missing`
- **PangolinGit today:** Plain text detail pane (`LogWindowController.swift:302-351`).
- **To implement:** `NSTextView` with link attributes (`ShortHashLengthForHyperLinkInLogMessage` = 8), optional avatar via SHA-256 of the email, notes editor (`git notes edit`).

### LG-14 Describe in log (`git describe` column / strategy) and branch revision number (`rev-list --count --first-parent`) `❌ Missing`
- **To implement:** Optional columns driven by Settings ▸ Dialogs 1.

### LG-15 Log cache for fast reload `❌ Missing`
- **PangolinGit today:** Full `git log -n 500` on every open/refresh; each cell is a fresh `NSTextField` (`LogWindowController.swift:256-273`).
- **To implement:** Reuse cell views; incremental loading via `git log --format` streaming; optional on-disk cache keyed by HEAD hash.

### LG-16 Refresh button / F5, status bar ("Showing N revisions, from … to …, N selected"), loading progress bar `⚠️ Partial`
- **PangolinGit today:** "Showing N commits." label; no manual refresh, no progress indicator.
- **To implement:** Toolbar Refresh (⌘R), richer status line, `NSProgressIndicator` during load.

### LG-17 Double-click → compare with previous (configurable) and Enter `⚠️ Partial`
- **PangolinGit today:** Double-click copies the hash (`LogWindowController.swift:359-361`).
- **To implement:** Honour a *Can double-click to compare* setting; Enter → compare.

### LG-18 Shift-click on ref labels / Shift for extended menu / ref-label-specific context menu (switch, push, delete, merge, create branch from label) `❌ Missing` (depends on LG-02).

### LG-19 Edit Notes `❌ Missing` — `git notes add/edit -F`; show notes in detail pane (`%N`).

### LG-20 Show branches this commit is on (dialog with filter) `❌ Missing` — `git branch -a --contains <sha>`.

### LG-21 Combine to one commit `❌ Missing` — `git reset --soft <parent of oldest>` + commit with concatenated message; preconditions: clean tree, contiguous range on current branch.

### LG-22 Superproject submodule pointer highlighting and *Log of submodule* `❌ Missing`.

### LG-23 Log as a picker (`…` buttons in Reset, Compare Revisions, Export, Branch/Tag, Rebase return the chosen commit; `/outfile`) `🐛 Broken`
- **PangolinGit today:** Reset's *Log…* button opens a Log window but nothing comes back (`Dialogs/Reset/ResetWindowController.swift:106-108`); every revision field in the app is free text.
- **To implement:** `LogWindowController.init(pickerCompletion:)` that adds a *Select* button and returns the hash; use it from Reset, FileDiff, Export, Branch/Tag, Rebase, Worktree, Bisect, Merge.

### LG-24 Statistics: Statistics summary page, Percent of authorship, Changed lines by date (*Calculate* with numstat), Pie / stacked line / line / stacked bar / bar styles, Authors case-sensitive, Use committer names, Use commit dates, Sort by commit count, "# authors shown individually" slider with *Others*, time-unit buckets, `.mailmap`, Save graph as… `⚠️ Partial`
- **PangolinGit today:** Three fixed views (author / month / weekday), 5000-commit cap on HEAD only, bars without axes or export, `Share` column empty for two of three tabs (`StatisticsWindowController.swift:61-64, 115, 218, 225`); `GitMailmap` parser exists but is unused (`Core/Git/GitMailmap.swift`).
- **To implement:** Operate on the Log window's current revision set (open from a *Statistics* button in Log); add the summary page, line stats via `git log --numstat`, chart-type switcher, the five options, mailmap, and image export (`NSBitmapImageRep` from the chart view).

### LG-25 Keyboard: Ctrl+A select all, Ctrl+C copy, Ctrl+F search, Escape clears path filter `❌ Missing` (see SH-19).

---

## 6. Diff family

**Already covered (✅):** Side-by-side / unified diff window driven by `git diff --no-color --no-ext-diff -M <old> [<new>] -- <path>` with hunk-based rendering and synchronised scrolling (`PangolinGit/Views/Diff/SideBySideDiffView.swift`, `Dialogs/Diff/DiffWindowController.swift`); Compare Revisions window with free-text base/target, swap, `--name-status -M -C` + `--numstat` table, per-file View Diff, Create Patch (whole range), Export Files (`Dialogs/FileDiff/FileDiffWindowController.swift`); Image Diff window with side-by-side / alpha blend / curtain and zoom (`Views/ImageDiff/ImageDiffWindowController.swift`).

### DF-01 Intra-line (character / word) highlighting and modified-line pairing `❌ Missing`
- **What it does:** A changed line is shown as one "modified" row with the differing characters highlighted, rather than a removed + added pair; word-wise mode available.
- **How it works in TortoiseGit:** TortoiseGitMerge computes a second-level diff per line pair (`Max line length for inline diffs` setting).
- **Example:** A one-character typo fix is visible instantly instead of requiring two full lines to be compared by eye.
- **PangolinGit today:** Every change is a `-` line on the left and a `+` line on the right, with blank placeholders; no inline marks (`SideBySideDiffView.swift:136-234`). `DiffEngine` (Myers) exists but is unused by the view (`Core/Diff/DiffEngine.swift`).
- **To implement:** Pair adjacent `-`/`+` runs, run `DiffEngine.diff` on their characters (or words), and apply background attributes to the ranges.

### DF-02 Full-file context (not just hunks), line-number gutter, Collapse unchanged sections, Wrap long lines `⚠️ Partial`
- **PangolinGit today:** Only hunk contents with 3 lines of context are rendered; line numbers are inline text (`%5d | `), no gutter, no collapse/wrap toggles (`SideBySideDiffView.swift:136-234`).
- **To implement:** Load both full blobs (`git show rev:path`) and align them using hunk headers; `NSRulerView`-style gutter; collapse/wrap toggles.

### DF-03 Navigation: next/previous difference, next/previous inline difference, Go to line, Find/Replace, locator bar, line-diff bar `❌ Missing`
- **How it works in TortoiseGit:** F7/Shift-F7, F8, Ctrl-G, Ctrl-F; a left-side locator bar maps change positions and doubles as a scrollbar.
- **PangolinGit today:** None; no search in the diff view.
- **To implement:** Keep a `[changeRange]` index; toolbar/menu actions; `NSTextFinder` for find; a thin `NSView` drawing change positions beside the scroller.

### DF-04 Whitespace / EOL / case / comment / regex filters (Compare whitespaces, Ignore whitespace changes, Ignore all whitespace, Ignore line endings, Ignore case, Ignore comments, Regex filters, Moved-block detection) `❌ Missing`
- **How it works in TortoiseGit:** View menu radios and settings; Compare Revisions has *Diff Options* (ignore space at EOL, space change, all space, blank lines, common ancestor).
- **PangolinGit today:** No options; `git diff` is run with fixed arguments (`DiffWindowController.swift:61-75`, `FileDiffWindowController.swift:181-213`).
- **To implement:** Option popover mapping to `-w`, `-b`, `--ignore-space-at-eol`, `--ignore-blank-lines`, `--ignore-cr-at-eol`, `--color-moved` (parsed), and `--merge-base`; regex filters applied to both texts before diffing.

### DF-05 Editing inside the diff view (Enable edit, Undo/Redo, Use left/right block, Use whole file, Mark block, Save / Save as, Create patch file, Reload) `❌ Missing`
- **What it does:** Two-pane diff is also an editor: take blocks from the other side, hand-edit, save; mark blocks and *Use left file except marked blocks* (used for "restore after commit").
- **PangolinGit today:** Both panes are read-only (`SideBySideDiffView.swift:57-65`).
- **To implement:** Make the right pane editable with `NSUndoManager`; block actions that splice the other side's lines; Save writes the working file.

### DF-06 Diff colours and fonts from Settings (Colors, UDiff page, dark mode, whitespace rendering) `🐛 Broken`
- **PangolinGit today:** Colours are hard-coded `systemGreen/systemRed/systemBlue` (`SideBySideDiffView.swift:145-159`); the Colors pane stores `diff*ColorHex` that nothing reads (`ConfigManager.swift:209-223`).
- **To implement:** Read the three keys (plus a font setting) in `SideBySideDiffView` and `FileDiffWindowController`.

### DF-07 Diff options from the Finder: Diff with previous version (HEAD~ vs HEAD), Diff two selected files, Diff later / Diff with "file", Shift for alternate tool `❌ Missing`
- **PangolinGit today:** *Git Diff* always compares HEAD with the working tree for the first selected path (`CommandRouter.swift:111-112`).
- **To implement:** New commands `diffprev` (`git log -1 --format=%H -- path` then `rev~1..rev`), `difftwo` (two selected files, plain file diff via `git diff --no-index`), `difflater` (remember a path in `UserDefaults`, offer `Diff with "name"`).

### DF-08 Compare with base vs. with index: separate "staged" and "working tree" diffs `⚠️ Partial`
- **PangolinGit today:** `git diff HEAD -- path` merges index and working tree (`DiffWindowController.swift:61-75`); no `--cached` view.
- **To implement:** Revision selector in the diff window: Working tree ↔ Index, Index ↔ HEAD, Working tree ↔ HEAD, arbitrary rev ↔ rev.

### DF-09 Binary and image detection, hand-off to Image Diff `🐛 Broken`
- **What it does:** Diffing an image opens the image diff tool with old and new revision automatically; binaries show a message.
- **PangolinGit today:** "Binary files differ" is rendered as a blue header line; `ImageDiffWindowController` is reachable only via `pangolingit://imagediff` and even then `oldImageURL` is always nil (`CommandRouter.swift:150-151`); no Finder or dialog entry.
- **To implement:** In `DiffWindowController`, detect image UTIs, extract `git show <rev>:<path>` to temp files and open `ImageDiffWindowController(old:new:)`; add *Image diff* to the status-list context menu.

### DF-10 Unified diff viewer (TortoiseGitUDiff: syntax colouring, line numbers, find bar, open/save, Apply patch…, print, dark mode) `⚠️ Partial`
- **PangolinGit today:** The unified pane shows raw `git diff` text in one colour (`SideBySideDiffView.swift:127`); no standalone viewer for `.patch` files, no find, no print.
- **To implement:** `UnifiedDiffWindowController` with `NSTextView` + attribute pass (command/position/header/added/removed colours from SE-13), `NSTextFinder`, Open/Save, Print, and an *Apply patch…* button that opens the patch-review mode (MG-10).

### DF-11 Compare Revisions: revision pickers (Reference Browser / Log / RefLog drop-downs, HEAD buttons, "newer" labels), Diff Options, Show log, View Patch pane, path-filter syntax `⚠️ Partial`
- **PangolinGit today:** Base/target are free text defaulting to `HEAD~1`/`HEAD` (fails on single-commit repos) (`FileDiffWindowController.swift:64-87`); no pickers, no log button, no patch pane, substring filter only.
- **To implement:** Picker buttons (BR-10 / LG-23 / RL-05), *Diff Options* (DF-04), *Show log* of `rev1..rev2`, side patch pane.

### DF-12 Compare Revisions context menu: Compare (double-click, multi), unified diff per file, Revert to revision A / B, Show log / Blame / Show log of submodule, Export selection to…, Save list of selected files to…, Copy paths / all information; "No differences found!" state `⚠️ Partial`
- **PangolinGit today:** View Diff for one row, Export Files (selected or all), Create Patch (whole range only, ignores selection) (`FileDiffWindowController.swift:305-395`); no context menu; renames show "Renamed" without the old path.
- **To implement:** Context menu with the listed items; patch for selected files (`git diff rev1 rev2 -- <paths>`); show `old → new` for renames.

### DF-13 Submodule Diff dialog (From/To hashes, subjects, change type classification, Show log per side, Update, Show diff) `❌ Missing`
- **What it does:** Double-clicking a submodule entry in commit/status/log lists shows how the pointer moved (Fast-forward, Rewind, Newer/Older/Same time, New/Deleted submodule, Identical) with per-side *Show log* and an *Update* button.
- **PangolinGit today:** Submodule rows are treated as ordinary paths; diff shows the `Subproject commit` text lines.
- **To implement:** Detect `160000` mode entries; `git -C <sub> merge-base --is-ancestor` to classify; small window with the two hashes and buttons.

### DF-14 External diff viewer / merge tool / per-extension tools / alternative editor launching (`%base %mine %bname …` substitution, Shift for alternate) `🐛 Broken`
- **PangolinGit today:** Settings ▸ Tools stores `externalDiffTool`, `externalMergeTool` and argument templates (`Dialogs/Settings/ExternalToolsSettingsView.swift:114-125`) but nothing launches them; `git diff` always runs with `--no-ext-diff`.
- **To implement:** `ExternalToolLauncher` expanding `$LOCAL/$REMOTE/$BASE/$MERGED` and TortoiseGit-style `%base/%mine/%theirs/%merged/%bname/%yname`; per-extension table; ⌥-click on Diff uses the external tool; merge tool launched from the Resolve flow with `.BASE/.LOCAL/.REMOTE` temp files and the "trust exit code" / "block while running" options.

### DF-15 Image diff (TortoiseGitIDiff) feature set: overlay with alpha vs XOR blend, alpha keyboard shortcuts and auto-toggle, link image positions, fit widths / heights / in window, original size, image info box (size, DPI, bit depth, zoom), vertical/horizontal arrangement, transparent colour, dark mode, multi-frame GIF navigation, pan by drag, three-way image conflict resolution with *Select* buttons, Open dialog `⚠️ Partial`
- **PangolinGit today:** Side-by-side / alpha blend / curtain, blend slider, zoom slider, size footer; no pan, fit, XOR, info, arrangement, frames, 3-way, open dialog (`ImageDiffWindowController.swift:74-134, 167-239`); toolbar does not reflow on resize.
- **To implement:** Rebuild on `NSScrollView` + `NSImageView` pair with shared `magnification`, add the listed modes; XOR via `CIDifferenceBlendMode`; info from `CGImageSource` properties; 3-way mode taking base/mine/theirs/result paths.

### DF-16 Folder diff (whole-tree diff as a changed-file list instead of one giant text) `⚠️ Partial`
- **PangolinGit today:** Diff on a folder concatenates the whole subtree into one text (`DiffWindowController.swift:71`).
- **To implement:** Route folder targets to the Compare Revisions window with pathspec (`FileDiffWindowController(base: HEAD, target: worktree, path:)`).

### DF-17 Line-ending / encoding handling in the diff view `❌ Missing`
- **PangolinGit today:** CRLF is trimmed in display (`SideBySideDiffView.swift` parser); no BOM/encoding detection or status-bar indicators.
- **To implement:** Detect encoding via `NSString.stringEncoding(for:)`/BOM; show EOL style; option to ignore EOL (DF-04).

---

## 7. Merge / conflict editor and patch application (TortoiseGitMerge 3-pane)

**Already covered (✅):** Three-pane window (Ours / Theirs top, editable Merged bottom) loading index stages `:1:`/`:2:`/`:3:` with a conflict-marker fallback, own 3-way merge engine, Prev/Next conflict, Use Ours / Theirs / Base / Both (ours→theirs), All Ours / All Theirs, manual-edit protection, *Mark Resolved & Save* (`git add`) with an unresolved-marker guard (`PangolinGit/Dialogs/Merge/MergeWindowController.swift`, `Core/Diff/MergeEngine.swift`).

### MG-01 Base pane and real four-view layout `⚠️ Partial`
- **What it does:** TortoiseGitMerge shows Theirs (left), Mine (right) and Merged (bottom) with inline diff colouring against the base, and conflict blocks highlighted in all panes; the locator bar shows three columns.
- **PangolinGit today:** The base version is loaded but never displayed; the ours/theirs panes are plain text with no change highlighting or scroll-to-conflict (`MergeWindowController.swift:54-125`).
- **To implement:** Reuse `SideBySideDiffView` rendering for ours-vs-base and theirs-vs-base; highlight the current conflict in all three; add a Base tab or pane.

### MG-02 Line/hunk-level choices and editing primitives (Use this text block, Use block from left before right / right before left, Use whole other file, Prepend/Append block, Mark/Unmark block, Leave only marked blocks, Both blocks this-first/last) `⚠️ Partial`
- **PangolinGit today:** Whole-conflict choices only; `useBothTheirsThenOurs` exists in the engine but has no button (`MergeEngine.swift:193`, `MergeWindowController.swift:127-162`); no per-line selection.
- **To implement:** Context menu in each pane operating on the block under the cursor; block marking state; both orderings.

### MG-03 Editing, Undo/Redo, Find/Replace, Go to line, Cut/Copy/Paste, Select all, Convert tabs/spaces, Trim right `❌ Missing`
- **PangolinGit today:** The merged pane is a plain `NSTextView` (undo not configured across regenerations); regenerating after a resolve discards manual edits only after a confirmation (`MergeWindowController.swift:326-342`); no find.
- **To implement:** `NSUndoManager` with grouped operations; `NSTextFinder`; Go-to-line sheet; transforms.

### MG-04 Encoding / line-ending / tab handling (status-bar combos, Encoding dialog, BOM variants, "Default to UTF-8", EditorConfig) `❌ Missing`
- **PangolinGit today:** UTF-8 only; non-UTF-8 files silently become empty strings and the window reports "Clean merge — no conflicts detected" (`MergeWindowController.swift:205-243, 287-296`).
- **To implement:** Detect encoding and EOL; write back with the same; expose combos in a status bar.

### MG-05 Conflict-file helpers: `file.BASE.ext` / `file.LOCAL.ext` / `file.REMOTE.ext` on demand, friendly branch titles, mine/theirs semantics per operation (merge vs rebase vs cherry-pick vs stash), temp-file cleanup on *Mark as resolved* `❌ Missing`
- **What it does:** Pane titles read "Theirs: origin/main" / "Mine: feature"; during a rebase the sides are swapped; helper files allow external tools to be used.
- **PangolinGit today:** Fixed titles "Local (Ours) — HEAD" / "Remote (Theirs) — Incoming" (`MergeWindowController.swift:54-125`); no helper files.
- **To implement:** Read `MERGE_HEAD`, `REBASE_HEAD`, `CHERRY_PICK_HEAD`, `rebase-merge/head-name` to name the sides; write helper files when launching an external tool (DF-14).

### MG-06 Delete/modify conflicts, binary conflicts, submodule conflicts (Delete-conflict dialog, Submodule-conflict dialog with Base/Mine/Theirs and *Use this*) `❌ Missing`
- **PangolinGit today:** A missing stage yields `""` and is treated as text (`MergeWindowController.swift:205-243`); no detection.
- **To implement:** Inspect `git ls-files -u` stages; show a dedicated sheet for missing-side / binary / `160000` entries with Keep / Delete / Use mine / Use theirs.

### MG-07 Use git's own merge result instead of recomputing `⚠️ Partial`
- **PangolinGit today:** The on-disk conflict file (git's hunking, `diff3` style) is ignored whenever stages exist; PangolinGit's own Myers-based 3-way may produce different conflict boundaries than git's (`MergeWindowController.swift:205-243`, `MergeEngine.swift:33-160`).
- **To implement:** Offer `git merge-file -p --diff3` output as the merged starting text and parse its markers; keep the engine as a fallback.

### MG-08 Mark as resolved without opening the editor / Resolve dialog listing all conflicted files `❌ Missing` (see RV-06).

### MG-09 Two-file diff/edit mode and one-pane view (`/oneway`), switch left/right, Reload, Save as, Create patch file, Read-only mode, `.bak` backup, jump-to-first-diff/conflict on load `❌ Missing`
- **PangolinGit today:** The merge window only opens for a conflicted file from Finder; two-file compare is the read-only diff window (§6).
- **To implement:** Unify the diff and merge windows into one editor with modes (diff / merge / patch).

### MG-10 Patch review and application mode (open `.patch`/`.diff`, file list black/red for clean/dirty, preview patched file, patch selected / all files, automatic base retrieval, "Add new files automatically to Git", Open from clipboard) `❌ Missing`
- **What it does:** Right-click a patch → *Review/apply single patch…*: a file list shows which files the patch touches; each can be previewed as a diff and applied individually; the base revision named in the patch is fetched automatically.
- **PangolinGit today:** Patch window applies the whole file with `git apply --3way` and no preview (`Dialogs/Patch/PatchWindowController.swift:186-197`).
- **To implement:** Parse with `GitPatch.parse` (exists, unused: `Core/Git/GitPatch.swift`), list files, `git apply --check` per file, per-file apply with `--include`, side-by-side preview.

### MG-11 Settings pages for the merge editor (General: backup, jump options, UTF-8 default, one-pane default, line numbers, auto-add, tab size/spaces, EditorConfig, font, max inline length, ignore EOL/case, context lines; Colors page) `❌ Missing`
- **To implement:** New Settings ▸ Merge pane; read in the editor.

### MG-12 Ribbon / toolbar, status-bar counters (added/removed lines per side, unresolved conflicts), line-status margin icons (added, removed, equal, whitespace-only, edited, conflicted, moved) `❌ Missing`
- **PangolinGit today:** Toolbar buttons and a footer sentence only (`MergeWindowController.swift:127-162, 281-322`).
- **To implement:** Gutter icons per line state; status bar.

### MG-13 Keyboard shortcuts (F7/F8 next diff/conflict, Ctrl-F9/F10 use left/right block, Ctrl-G, Ctrl-E, Ctrl-R, Ctrl-S, Ctrl-T whitespace, Ctrl-L collapse, Ctrl-P wrap, Ctrl-U switch, Ctrl-D one-pane, Ctrl-M mark, Ctrl-Tab pane) `❌ Missing`
- **To implement:** Menu items with key equivalents in a *Merge* main-menu entry.

### MG-14 Launching the editor from status/commit/log lists and from the Resolve flow `⚠️ Partial`
- **PangolinGit today:** Only the Finder entry "Edit Conflicts…" on a single file (`FinderSync.swift:41`, `CommandRouter.swift:134`).
- **To implement:** ST-01.

### MG-15 Post-resolve: `RepositoryEvents` refresh, offer *Commit…* / continue rebase/cherry-pick `❌ Missing`
- **PangolinGit today:** `git add` then close; no notification (`MergeWindowController.swift:405-461`).

### MG-16 Three-way image merge (`TortoiseGitIDiff /base /mine /theirs /result`) `❌ Missing` (see DF-15).

### MG-17 Automation flags (`/base /mine /theirs /merged /diff /patchpath /oneway /readonly /line /createunifieddiff …`) `❌ Missing` (see AU-02).

---

## 8. Revert, Reset, Resolve, Abort merge

**Already covered (✅):** Revert window listing modified/staged/added/deleted/renamed/conflicted/missing files with a diff preview, Select All/None, confirmation (`confirmOnRevert`), `git rm --cached` / `git restore --source=HEAD --staged --worktree` (`PangolinGit/Dialogs/Revert/RevertWindowController.swift`); Reset window with Soft/Mixed/Hard/Keep, hard-reset confirmation (`Dialogs/Reset/ResetWindowController.swift`).

### RV-01 Revert honours the Finder selection and shows unversioned-items note `⚠️ Partial`
- **PangolinGit today:** Whole repository always (`CommandRouter.swift:141`); no note.
- **To implement:** Pass pathspec; add the note.

### RV-02 Revert a folder's deletions/renames and undo an add from the Finder `⚠️ Partial`
- **PangolinGit today:** Works through the dialog's list; no *Delete (keep local)* shortcut (DL-02).

### RV-03 Revert progress dialog with *Handle submodules* `❌ Missing` (PR-01).

### RV-04 Recycle-bin (Trash) safety for reverted and deleted files (setting *Use recycle bin when reverting*) `❌ Missing`
- **What it does:** The working-tree version is moved to the Recycle Bin before being overwritten so a mistaken revert is recoverable.
- **PangolinGit today:** `git restore` overwrites in place (`GitRepository.swift:308-336`).
- **To implement:** Copy each file to Trash via `FileManager.trashItem` before `restore`; setting in Dialogs pane.

### RV-05 Revert dialog column/colour/filter parity and status text `⚠️ Partial`
- **PangolinGit today:** Separate table with raw enum names (`Stagedmodified`) and two colours (`RevertWindowController.swift:290-291`); no filter, no context menu; does not observe/post `RepositoryEvents`; conflicted files are reset to HEAD without warning (`:164-186`).
- **To implement:** Reuse `StatusListView`; warn or exclude conflicted rows; post events.

### RV-06 Resolve… dialog (checkbox list of conflicted files, Select/deselect all, *Commit your change after resolve* hint, progress with *Commit…* post-action) `❌ Missing`
- **What it does:** Mark several files resolved at once (`git add`) without opening the editor.
- **PangolinGit today:** None; the only path is the per-file merge editor's *Mark Resolved & Save*.
- **To implement:** `ResolveWindowController` using `StatusListView` filtered to `.conflicted`; buttons Resolved / Use mine / Use theirs / Edit.

### RV-07 Abort Merge dialog (Merge / Mixed / Hard types, *Show modified files*, context-menu *Abort Merge* while `MERGE_HEAD` exists) `❌ Missing`
- **How it works in TortoiseGit:** `git reset --merge|--mixed|--hard HEAD`.
- **PangolinGit today:** None; a user mid-merge has no way out except Reset with hand-typed `HEAD`.
- **To implement:** Small dialog + Finder/menu entry gated on merge state (SH-01); also cover `cherry-pick --abort`, `revert --abort`.

### RS-01 Reset target chooser (Branch / Tag / Commit radios, combos, `…` log/ref pickers) `🐛 Broken`
- **PangolinGit today:** Free text defaulting to `HEAD~1` (one commit back!) when opened from Finder (`ResetWindowController.swift:18, 50-52`); the *Log…* button opens a log window that cannot return a selection (`:106-108`).
- **To implement:** Default to `HEAD`; choose-version control (shared "Base On" chooser, CV-01); LG-23 picker.

### RS-02 *Show modified files in working tree* button `❌ Missing` — opens Compare Revisions HEAD ↔ working tree (DF-08).

### RS-03 Reset progress post-actions (Update submodules, Bisect good/bad/skip/reset, Clean up…) and repository-event refresh `❌ Missing`
- **PangolinGit today:** Closes silently; no `RepositoryEvents.post` so open Log/Commit windows stay stale (`ResetWindowController.swift:114-148`).

### RS-04 Reset selected paths (`git reset -- <paths>`), `--merge` mode `❌ Missing`
- **PangolinGit today:** Whole-branch reset only; `--keep` offered instead of `--merge`.

### RS-05 Hard-reset preview of what will be lost `❌ Missing`
- **To implement:** Show `git diff --stat HEAD` in the confirmation sheet.

---

## 9. Switch/Checkout, Create Branch/Tag, Browse References, Merge dialog

**Already covered (✅):** Switch window with current branch, local-branch popup, create-new-branch, force (`Dialogs/Switch/SwitchWindowController.swift`); Create Branch/Tag window with base field, checkout-after, force (`Dialogs/Branch/CreateBranchTagWindowController.swift`); Browse References outline (local, remote, tags) with current-branch marker, Switch/Checkout, Delete (with force-delete and remote delete), Refresh (`Dialogs/BrowseRefs/BrowseRefsWindowController.swift`).

### CV-01 Shared "Choose version" control (HEAD / Branch / Tag / Commit radios, sorted combos, `…` ref-browser and log pickers, free text like `HEAD~4`) `❌ Missing`
- **What it does:** One reusable control used by Switch, Branch/Tag, Merge, Reset, Export, Bisect, Rebase, Worktree.
- **PangolinGit today:** Every dialog has a plain `NSTextField` for the revision (Switch is the exception with a local-branch-only popup).
- **To implement:** `RevisionChooserView` (`NSView`) populated from `git for-each-ref`, with picker buttons to Browse References (BR-10) and Log (LG-23); adopt it in all eight dialogs.

### SW-01 Switch to tags, remote branches and commits (Branch / Tag / Commit radios) `⚠️ Partial`
- **PangolinGit today:** Popup lists `git branch --list` only (`SwitchWindowController.swift:120-125`) despite the label "Target Branch / Tag"; no remote branches, tags or hashes.
- **To implement:** CV-01.

### SW-02 Track (tri-state), Override branch if exists (`-B`), Merge (`--merge`) `❌ Missing`
- **PangolinGit today:** Only `-b` and `--force` (`SwitchWindowController.swift:135-161`).
- **To implement:** Three more controls → `--track/--no-track`, `-B`, `-m`.

### SW-03 Checkout of a remote branch creates a tracking local branch `⚠️ Partial`
- **PangolinGit today:** Browse References checks out `origin/x` as detached HEAD (`BrowseRefsWindowController.swift:211-226`).
- **To implement:** Offer *Create local branch tracking origin/x* (TortoiseGit asks); `git switch -c x --track origin/x`.

### SW-04 Dirty-tree stash prompt and post-actions (Update submodules, Merge, Pull, Commit, Resolve, Stash, Retry, Checkout with merge) `❌ Missing`
- **PangolinGit today:** git's refusal is shown as "Checkout failed: …" in a one-line label (`SwitchWindowController.swift:173-174`).
- **To implement:** Pre-flight `git status --porcelain`; offer Stash / Force / Merge; PR-01 post-actions.

### SW-05 Detached-HEAD warning and name validation (`check-ref-format`, tag-name clash) `❌ Missing`.

### SW-06 Repository-event refresh after checkout `🐛 Broken` — neither Switch nor Browse References posts `RepositoryEvents` (`SwitchWindowController.swift:171`, `BrowseRefsWindowController.swift:211-226`), so Log/Commit/Sync windows and the Finder badge for HEAD-dependent state stay stale until FSEvents fire.

### BT-01 Annotated / signed tags with message, tag *Push* right away, branch description `⚠️ Partial`
- **PangolinGit today:** Lightweight tags only (`CreateBranchTagWindowController.swift:140-148`); `GitRepository.tagCreate(message:)` exists unused.
- **To implement:** Message box (required for annotated), *Sign* (`-s`), *Push* (`git push <remote> <tag>`), `git branch --edit-description`.

### BT-02 Base On chooser, Track tri-state, name validation, post-action *Update submodules* `⚠️ Partial`
- **PangolinGit today:** Base is free text; checkout failure after creation is silently ignored and the dialog closes (`CreateBranchTagWindowController.swift:158-160`); no `--track`, no validation.
- **To implement:** CV-01; `--track` control; `git check-ref-format --branch`; surface checkout errors.

### BR-01 Browse References filter `🐛 Broken`
- **PangolinGit today:** Typing in the search field reloads the outline without filtering (`BrowseRefsWindowController.swift:201-205, 355-375`).
- **To implement:** Apply the text (log-style syntax with field menu: Refname, Subject, Authors, SHA-1) in the data source.

### BR-02 Ref tree: nested namespaces (`feature/x` under `feature`), stash and notes nodes, *Show nested refs*, remotes as sub-nodes `⚠️ Partial`
- **PangolinGit today:** Three flat categories; the header comment promises stashes that are never built (`BrowseRefsWindowController.swift:6, 165-169`).
- **To implement:** Build a tree from `/`-separated names; add `refs/stash`, `refs/notes`, `refs/remotes/<remote>` groups.

### BR-03 Columns: Tracked branch, Last author date, Last commit, Last author, Date last commit, Last committer, SHA-1, Description; sortable `⚠️ Partial`
- **PangolinGit today:** Reference / Commit / Message / relative Date (`:96-116`); no sorting.
- **To implement:** `for-each-ref --format` with `%(upstream:short)`, `%(authordate)`, `%(committername)`, `%(contents:subject)`; sort descriptors.

### BR-04 Branch filter combo (All / Only merged / Only unmerged to HEAD) and *Current Branch* button `❌ Missing` — `git branch --merged/--no-merged`.

### BR-05 Inline rename (F2) and *Rename* / *Edit description* `❌ Missing` — `git branch -m`, `--edit-description`.

### BR-06 Context menu: Show log, Browse repository, Show RefLog, Compare with working tree, Fetch from remote, Merge to current, Switch/Checkout to this, Create Branch from remote branch, Select/Unset tracked branch, two-ref Compare / unified diff / Show log A..B B..A A...B, Copy ref names `❌ Missing`
- **PangolinGit today:** No `NSMenu` on the outline; only the three bottom buttons (`:126-139`).
- **To implement:** Context menu wired to existing windows (Log with ref LG-01, RepoBrowser with revision, RefLog with ref RL-01, FileDiff) and `git branch -u` / `--unset-upstream`.

### BR-07 Multi-select delete (Delete N branches / remote branches / tags), unmerged warnings, *Delete all tags*, *Delete remote tags on "X"…* dialog `⚠️ Partial`
- **PangolinGit today:** Single selection; local/tag/remote deletion exists with force fallback (`:228-331`).
- **To implement:** `allowsMultipleSelection`; batch delete; remote-tags dialog (`git ls-remote --tags` → `git push <remote> --delete <tags>`).

### BR-08 Remotes-node actions (Manage Remotes, Fetch from "X") and tags-node *Create Tag…* `❌ Missing`.

### BR-09 Info line "Showing N refs, N selected" and refresh on repository events `⚠️ Partial` — count line exists (`:172`), no event observation.

### BR-10 Browse References as a picker (`…` buttons, *Select* entry, two-ref range selection) `❌ Missing`
- **To implement:** `BrowseRefsWindowController(pickerCompletion:)` returning one or two refs; used by CV-01, LG-01, Pull/Push/Sync pickers.

### BR-11 Merge dialog `❌ Missing`
- **What it does:** Merge a branch/tag/commit into the current branch with *Squash*, *No Fast Forward*, *Fast Forward Only*, *No Commit*, *Messages [N]* (`--log`), *Strategy* (resolve / recursive / ours / subtree) and *Strategy option* (ours, theirs, patience, ignore-space-*, renormalize, rename-threshold, subtree=), a custom merge message, and post-actions (Commit…, Merge unrelated history, Stash, Remove merged branch, Push).
- **How it works in TortoiseGit:** `TortoiseGit ▸ Merge…`, log/ref-browser *Merge to "current"…*; `git merge [options] <ref>`.
- **Example:** Merge `feature/login` into `main` with `--no-ff` so the integration point stays visible.
- **PangolinGit today:** No merge dialog at all. README's "merge controls" in the reference browser do not exist (`README.md:14`; buttons at `BrowseRefsWindowController.swift:126-139`). `GitRepository.merge(branch:fastForward:squash:message:)` exists unused (`GitRepository.swift:390-399`).
- **To implement:** `MergeDialogWindowController` with CV-01 chooser, the six options, strategy popups, message editor; run through PR-01; add Finder entry (hidden during merge/bisect) and Log/Browse-refs context items.

### BR-12 Abort merge / merge conflict semantics explained in UI `❌ Missing` (RV-07, MG-05).

---

## 10. Rebase, Cherry-pick, Bisect, RefLog, Stash

**Already covered (✅):** Interactive rebase window with upstream field, oldest-first commit table, per-row action popup (pick / edit / squash / fixup / drop), Up/Down reordering, Start (`git rebase -i` with `GIT_SEQUENCE_EDITOR=cp`), Continue, Abort (`Dialogs/Rebase/RebaseWindowController.swift`); Bisect window with start / good / bad / skip / reset, in-progress detection, culprit alert (`Dialogs/Bisect/BisectWindowController.swift`); RefLog window for HEAD with Diff with HEAD, Create Branch, Reset to This (`Dialogs/RefLog/RefLogWindowController.swift`); Stash window with message, include-untracked, keep-index, list, Pop/Apply/Drop (`Dialogs/Stash/StashWindowController.swift`).

### RB-01 Reword action `🐛 Broken` (advertised)
- **What it does:** Edit a commit's message during the rebase.
- **PangolinGit today:** `reword` is deliberately omitted because `GIT_EDITOR=true` auto-accepts messages (`RebaseWindowController.swift:5-12`); README claims it (`README.md:15`).
- **To implement:** Set `GIT_EDITOR` to a bundled helper that opens an in-app message sheet (or pre-write the messages with `git commit --amend -F` at each `edit` stop).

### RB-02 In-progress rebase detection, remaining-todo view, Conflict Files tab, Commit/Amend buttons at an `edit` stop `❌ Missing`
- **What it does:** When a rebase stopped (conflict or `edit`), reopening the dialog shows the remaining steps, the conflicted files with resolve actions, a message editor for the current commit, and Commit / Amend / Continue / Abort as appropriate.
- **PangolinGit today:** The table always shows `<base>..HEAD`; Continue/Abort are always enabled; conflicts only appear as stderr in an alert (`RebaseWindowController.swift:190-206, 265-304`).
- **To implement:** Detect `.git/rebase-merge/`; parse `git-rebase-todo` and `done`; `git status` for conflicts → `StatusListView` with ST-01 actions; Amend via `git commit --amend`.

### RB-03 Branch / Upstream combos, swap button, `--onto`, Force rebase, Preserve merges (`--rebase-merges`), add "cherry picked from", Autostash, Autosquash `❌ Missing`
- **PangolinGit today:** Upstream free text; current branch only; no options (`RebaseWindowController.swift:121, 254-258`).
- **To implement:** CV-01 chooser ×2 + swap; options → `--onto`, `--force-rebase`, `--rebase-merges`, `--autostash`, `--autosquash`; for "cherry picked from" use `-x` in cherry-pick mode.

### RB-04 Rebase keyboard shortcuts (Space cycle, P/S/E/Q, U/D move, Ctrl+A), context menu per commit, *Add* commits from log, select-all options (Pick ALL / Squash ALL / Edit ALL / Skip unselected…), drag-and-drop reorder `❌ Missing`
- **PangolinGit today:** Popup per row and Up/Down buttons only (`:71-89, 214-228`).

### RB-05 Lower-pane tabs (Revision Files, Commit Message, Conflict Files, Log) and progress bar "Rebasing (n/m)" `❌ Missing`
- **To implement:** Tab view; stream git output via PR-01.

### RB-06 Dirty-tree stash offer, up-to-date / fast-forward detection, auto-skip failed commits, empty-commit handling, pre-rebase hook prompt, post-rebase actions (Show log, Push, Send mail, Restart) `❌ Missing`.

### RB-07 Non-interactive plain rebase (as used by Pull with rebase, Sync *Fetch & Rebase*) and *Rebase "current" onto this* from Log `⚠️ Partial`
- **PangolinGit today:** Pull supports `--rebase` with no UI for conflicts (`Dialogs/Pull/PullFetchWindowController.swift:155-168`); Log has no rebase item.

### RB-08 Cherry-pick dialog (same UI as rebase, multi-commit, merge-parent choice, `-x`, conflict → commit flow) `❌ Missing`
- **What it does:** Apply one or several selected log commits onto HEAD with pick/squash/edit/skip control and ordering.
- **How it works in TortoiseGit:** Log ▸ *Cherry Pick this commit…* / *selected commits…*; `git cherry-pick`.
- **Example:** Port a hot-fix from `release/1.2` to `main`.
- **PangolinGit today:** None; `GitRepository.cherryPick` exists unused (`GitRepository.swift:411-416`).
- **To implement:** Reuse the rebase window in "cherry-pick mode" (todo list of picks), `-m <parent>` for merges, `--continue/--abort`.

### BI-01 Bisect start from the Log (two selected commits), good/bad/skip/reset from the Finder and Log while bisecting, log markers (bad red / good blue / skip grey) `❌ Missing`
- **PangolinGit today:** Only inside the Bisect window (`BisectWindowController.swift`); Finder menu has a single *Bisect…* entry.
- **To implement:** SH-01 state + four Finder entries; LG-11 items; LG-02 markers from `git bisect log`.

### BI-02 Bisect dirty-tree stash offer, post-step actions (Update submodules), `bisect run`, path limiting, custom terms, revision pickers `⚠️ Partial`
- **PangolinGit today:** Free-text good/bad fields; no stash offer; no run script (`BisectWindowController.swift:61-76, 164-182`).

### RL-01 RefLog ref selector (HEAD, any branch, remote branch, `refs/stash`) `⚠️ Partial`
- **PangolinGit today:** HEAD only, 200 entries (`RefLogWindowController.swift:112`).
- **To implement:** Ref popup → `git reflog show <ref>`; remove the cap or add paging.

### RL-02 Columns (SHA-1, Ref, Action, Message, Date) and robust parsing `⚠️ Partial`
- **PangolinGit today:** No date column; subjects containing `|` are truncated by the parser (`:114-126`).
- **To implement:** Use `%x1f` separators and `%gd|%H|%gs|%ci`.

### RL-03 Search… button, Clear stash, *Delete Ref…* (reflog delete / stash drop), *Stash Apply* `❌ Missing`.

### RL-04 Context menu (Show log at commit, Compare, unified diff, Browse repository, Create branch/tag, Switch, Reset, Export, Copy full data / SHA-1 / messages) `⚠️ Partial`
- **PangolinGit today:** Three buttons (Diff with HEAD, Create Branch, Reset to This); no context menu (`:88-106, 141-160`).

### RL-05 RefLog as a picker for Compare Revisions `❌ Missing` (DF-11).

### SS-01 Stash from everywhere (Finder *Stash changes*, status dialog button, Log working-tree entry, automatic offers before rebase/bisect/switch/pull) `⚠️ Partial`
- **PangolinGit today:** Only via the Stash window (`FinderSync.swift:45`); no automatic offers.

### SS-02 `--all` (include ignored), warning about `git clean -fd` for `-u`, stash of selected paths (`git stash push -- <paths>`), *stash branch* `❌ Missing`.

### SS-03 Stash list dialog = RefLog on `refs/stash` with per-stash diff, apply, delete, *Clear stash*, "Do you want to see changes?" after apply/pop `⚠️ Partial`
- **PangolinGit today:** Table of `stash list` lines; Pop/Apply/Drop; no diff/preview, no clear, no post-apply diff offer (`StashWindowController.swift:155-246`).
- **To implement:** Selection → `git stash show -p stash@{n}` in a `SideBySideDiffView`; *Clear*; after pop/apply offer Changed Files window.

### SS-04 Stash label in the Log graph `❌ Missing` (LG-02).

### SS-05 Stash post-actions (Pop/Apply; Pull/Merge when triggered by those) and repository-event refresh `🐛 Broken`
- **PangolinGit today:** Stash operations never post `RepositoryEvents` (`StashWindowController.swift:205-224`), so Commit/Changed windows keep stale lists.

---

## 11. Pull/Fetch, Push, Sync, Clone, Create repository, Remotes

**Already covered (✅):** Pull/Fetch window with remote popup (upstream preselected), remote-branch text field, `--rebase`, `--prune`, `--tags` (`Dialogs/Pull/PullFetchWindowController.swift`); Push window with remote popup, remote-branch text, `--force-with-lease`, `--tags`, `-u` (`Dialogs/Push/PushWindowController.swift`); Sync window with ahead/behind counts, outgoing commit list, Pull/Push/Fetch(`--all --prune`)/Commit/Refresh (`Dialogs/Sync/SyncWindowController.swift`); Clone window with URL, directory, branch, depth, `--recurse-submodules` (`Dialogs/Clone/CloneWindowController.swift`); Remotes window with fetch/push URLs, Add, Prune, Remove (`Dialogs/Remotes/RemotesWindowController.swift`); askpass helper for passwords, passphrases and host-key prompts (`PangolinGitAskPass/main.swift`).

### PF-01 Remote-branch picker (combo of `refs/remotes/<remote>/*`, `…` to reference browser, default = `branch.<b>.merge`) `⚠️ Partial`
- **PangolinGit today:** Free-text field pre-filled with the **local** branch name (`PullFetchWindowController.swift:127-128`; `PushWindowController.swift:139`), not the configured upstream.
- **To implement:** Populate from `git for-each-ref refs/remotes/<remote>`; default from `git rev-parse --abbrev-ref @{upstream}`; BR-10 picker.

### PF-02 Arbitrary URL / local directory as source or destination (with history, Browse…) `❌ Missing`
- **To implement:** Radio *Remote* / *Arbitrary URL* with an editable combo backed by `recentUrls` (currently never written, `ConfigManager.swift:303-319`).

### PF-03 Fetch all remotes (`--all`), tags tri-state with effective default, prune tri-state with default label, depth / unshallow `⚠️ Partial`
- **PangolinGit today:** Plain checkboxes for `--prune` and `--tags`; no `--all` here (only Sync's Fetch), no `--no-tags`/`--no-prune`, no depth (`PullFetchWindowController.swift:13-15, 155-168`).

### PF-04 Pull options: Squash, No Fast Forward, Fast Forward Only, No Commit, Autostash `❌ Missing`
- **To implement:** Checkboxes → `--squash`, `--no-ff`, `--ff-only`, `--no-commit`, `--autostash`.

### PF-05 *Launch Rebase After Fetch* and *Fetch & Rebase* with smart prompts (unchanged → skip; fast-forward → Merge / Rebase / Abort) `❌ Missing`.

### PF-06 Post-pull conflict handling (progress dialog *Resolve* post-action, Sync *Conflicts* tab) `❌ Missing`
- **PangolinGit today:** "Failed: <stderr>" in a one-line label (`PullFetchWindowController.swift:182-183`).
- **To implement:** PR-01 with *Resolve…* (RV-06).

### PF-07 Manage Remotes link / Autoload SSH key per remote `⚠️ Partial`
- **PangolinGit today:** Remotes window exists but is not linked from Pull/Push; no per-remote key (`PullFetchWindowController`, `PushWindowController`). macOS equivalent of "Autoload PuTTY key": `ssh-add --apple-use-keychain <key>` or `core.sshCommand` with `-i` per remote (see SK-01).

### PU-01 Local branch picker, *Push all branches*, push to all remotes `⚠️ Partial`
- **PangolinGit today:** Local branch is read-only current branch (`PushWindowController.swift:47`).
- **To implement:** Editable combo from `git branch --list`; *Push all* → `--all`.

### PU-02 Force (plain `--force`) vs Force with lease, `--force-if-includes` `⚠️ Partial`
- **PangolinGit today:** Only `--force-with-lease` (`:13, 161-170`).

### PU-03 Push options: *Always push to this remote / branch for this local branch* (`branch.<b>.pushremote`), Recurse submodules (None / Check / On-demand), `--push-option`, `--follow-tags`, `--no-verify`, dry run `❌ Missing`.

### PU-04 Outgoing-commit preview in the push dialog and push output / *Request pull* post-action `❌ Missing`
- **PangolinGit today:** stdout discarded on success (`PushWindowController.swift:179-181`).
- **To implement:** PR-01; *Request pull* button opening RequestPull with the pushed ref.

### PU-05 Push a single tag / push tags only / push notes `❌ Missing` (Sync split-button entries) — `git push <remote> <tag>`, `--tags`, `refs/notes/*`.

### SY-01 Sync dialog tabs: git output Log, In Commits, In Changelist, Conflicts, Out Commits, Out Changelist, Ref List (changed refs before/after fetch, hide unchanged), Compare tags `⚠️ Partial`
- **PangolinGit today:** Outgoing commits only; incoming count computed but not listed; branch label hard-codes `origin/` (`SyncWindowController.swift:114-127`); Fetch errors swallowed (`:144`).
- **To implement:** Tab view: incoming via `@{upstream}..HEAD` reversed, changed files via `diff --name-status`, ref snapshot diff around fetch (`for-each-ref` before/after), tag comparison via `ls-remote --tags`.

### SY-02 Sync split buttons: Pull ▸ Pull / Fetch / Fetch & Rebase / Fetch all refs / Remote update / Clean up stale remote branches / Compare tags; Push ▸ Push / Push tags / Push notes; Submodule ▸ Update / Init / Sync; Stash ▸ Save / Pop / Apply; Apply Patch; Email Patch; Show log `⚠️ Partial`
- **PangolinGit today:** Five plain buttons; Pull and Push open the separate dialogs instead of running inline (`SyncWindowController.swift:45-54, 131-155`).
- **To implement:** Pull-down buttons running the commands inline with PR-01 output in the Log tab; Shift opens the full dialog.

### SY-03 Local/remote branch pickers, remote URL combo + Manage, Autoload key, Force checkbox `❌ Missing` in Sync.

### SY-04 Guards: switch-to-branch prompt when pulling into a non-checked-out branch, set-upstream suggestion with "don't show again", confirm-kill on close, randomised window position `❌ Missing`.

### CN-01 Clone options: `--bare`, `--no-checkout`, `--origin <name>`, LFS clone, Load SSH key, From SVN repository (trunk/tags/branches layout, from-revision, username) `❌ Missing`
- **PangolinGit today:** URL, directory, branch, depth, recurse-submodules only (`CloneWindowController.swift:151-162`).
- **To implement:** Checkboxes → `--bare`, `--no-checkout`, `--origin`, `-c filter.lfs.smudge=`/`git lfs install`; SVN group → `git svn clone -T/-t/-b -r --username`.

### CN-02 Destination semantics (repo name auto-appended; `/exactpath`), URL history combo, Browse for local URL, progress output, open after clone `⚠️ Partial`
- **PangolinGit today:** Destination is pre-filled with the clicked (existing) folder so pressing Clone fails; no history; no progress; nothing opens afterwards (`CloneWindowController.swift:26, 112-116, 164-176`); the clone runs without a working directory (`:170`).
- **To implement:** Append `<repo>` to the chosen parent unless the field was edited; `recentUrls` combo; PR-01 streaming; add to recent repositories and open Log on success.

### CR-01 Create repository here (`git init`, *Make it bare*) `❌ Missing`
- **What it does:** Initialise a repository in the clicked folder; checkbox for bare.
- **How it works in TortoiseGit:** Context menu on unversioned folders; `CreateRepoDlg`.
- **Example:** Start versioning a new project folder.
- **PangolinGit today:** None; no `init` anywhere.
- **To implement:** `repocreate` command (outside-repo menu) → `git init [--bare]` + message; refresh badges.

### RM-01 Remote editing: rename, set fetch URL, separate push URL, tag option (Reachable/None/All), push-default, prune tri-state, per-remote SSH key `⚠️ Partial`
- **PangolinGit today:** Add / Prune / Remove only; rows are read-only (`RemotesWindowController.swift:142-233`).
- **To implement:** Edit form → `remote rename`, `remote set-url [--push]`, `remote.<n>.tagopt`, `remote.pushDefault`, `remote.<n>.prune`, `remote.<n>.sshkey` (custom key used via `core.sshCommand`).

### RM-02 Fetch from this remote, Delete remote tags dialog, remote-node context menu `❌ Missing` (BR-07/BR-08).

### RM-03 Add Remote dialog reachable from Pull/Push/Sync/Submodule dialogs (`Manage` button) `❌ Missing`.

### DA-01 Credential UX: combined username + password form, remember in Keychain, host-key fingerprint display `⚠️ Partial`
- **PangolinGit today:** `pangolin-askpass` shows one `NSAlert` per prompt (username, then password) and never touches the Keychain (`PangolinGitAskPass/main.swift:8-45`); `CredentialPromptWindowController` with Keychain save is dead code (`Dialogs/Credentials/CredentialPromptWindowController.swift`, no instantiation); README claims Keychain integration (`README.md:20`).
- **To implement:** Either rely on git's `osxkeychain` helper (already configurable in Settings ▸ Credentials) and delete the dead window, or make askpass a `git credential` helper that reads/writes `KeychainWrapper`. Parse `ssh` host-key text to show the fingerprint prominently.

### DA-02 Pageant / PuTTY session aliases / TortoiseGitPlink `🍎 Platform`
- macOS equivalents: `ssh-agent` + `~/.ssh/config` host aliases + `UseKeychain yes`. Provide an *SSH ▸ Edit ~/.ssh/config* shortcut and an "add key to agent (Keychain)" button in the SSH window (see SK-01).

### DA-03 Proxy settings applied to git (`http.proxy`, bypass list, SSL verify) `🐛 Broken`
- **PangolinGit today:** Settings ▸ Network stores four keys nothing reads (`Dialogs/Settings/NetworkProxySettingsView.swift`, `ConfigManager.swift:226-246`); `GitCLIRunner` sets no proxy environment (`GitCLIRunner.swift:84-102`).
- **To implement:** Export `http_proxy`/`https_proxy`/`no_proxy` and `-c http.sslVerify=` in `GitCLIRunner`, or write them to the global git config from the pane (as TortoiseGit does for Git for Windows).

---

## 12. Export, Create/Apply patch, Send mail, Request pull

**Already covered (✅):** Export window with ref, Directory / Zip / tar.gz, destination, prefix (`Dialogs/Export/ExportWindowController.swift`); Patch window creating `git diff HEAD` text (editable) and applying a patch with `git apply --3way` (`Dialogs/Patch/PatchWindowController.swift`); Request Pull window generating `git request-pull` with copy (`Dialogs/RequestPull/RequestPullWindowController.swift`).

### EX-01 Export revision chooser (HEAD / Branch / Tag / Commit with pickers, reversed tag order), *Whole Project* vs sub-folder, overwrite prompt `⚠️ Partial`
- **PangolinGit today:** Free-text ref; whole repository only (`ExportWindowController.swift:53-55, 153-170`); directory export blocks the main thread with `tar` (`:165-169`).
- **To implement:** CV-01; pathspec from Finder selection (`git archive <ref> <path>`); run `tar` asynchronously; "export changed files between two revisions" from Compare Revisions (DF-12).

### EX-02 Export from Log (*Export this version…*), RefLog, Revision graph `❌ Missing` (LG-10 / RL-04).

### PT-01 Create Patch Serial (`git format-patch`: output dir, Since ref, Number of commits, Range From/To with log pickers, *No a/ b/ prefixes*, *Send mail after create*, *Save unified diff since HEAD*) `❌ Missing`
- **What it does:** One `.patch` per commit with author/date/message so recipients can `git am`.
- **Example:** Send three commits to a mailing list.
- **PangolinGit today:** The Patch window only writes the working-tree diff (`PatchWindowController.swift:117, 173-174`), which cannot be applied with `git am`; FileDiff's *Create Patch* writes `git diff rev1..rev2` for the whole tree (`FileDiffWindowController.swift:316-347`).
- **To implement:** `FormatPatchWindowController` with the three range modes, `--no-prefix`, output folder; Log context item *Format Patch…* (LG-10/LG-11).

### PT-02 Apply Patch Serial (`git am` with ordered file list Add/Up/Down/Remove, drag-and-drop, `--3way`, `--ignore-space-change`, `--signoff`, `--keep-cr`, Patch/Log tabs, Abort / Skip / Resolved on failure, stale `rebase-apply` detection) `❌ Missing`
- **PangolinGit today:** Single-file `git apply --3way` (`PatchWindowController.swift:186-197`); no `am`.
- **To implement:** `ApplyPatchSeriesWindowController`; `git am [opts] <files>`; `--continue/--skip/--abort`.

### PT-03 Review/apply single patch in the merge editor (per-file preview and apply) `❌ Missing` (MG-10).

### PT-04 Patch creation for selected files / from commit ranges / with `--binary`, apply with `--check`, `-R`, `--index` `⚠️ Partial`
- **PangolinGit today:** Whole tree only; apply has no dry-run/reverse (`PatchWindowController.swift`).

### PT-05 Patch viewer (TortoiseGitUDiff) for `.patch` files from Finder `❌ Missing` (DF-10) — add `.patch`/`.diff` document type to `Info.plist`.

### SM-01 Send Mail dialog (To / CC / Subject, *Patch as attachment*, *Combine one mail*, patch list with drag-and-drop and double-click preview, SMTP / MAPI / configured-server delivery, SMTP settings with credentials) `❌ Missing`
- **How it works in TortoiseGit:** `TortoiseGit ▸ Send Mail…` on `.patch` files, from format-patch, from Sync; `tgit.*` mail settings.
- **PangolinGit today:** None.
- **To implement (macOS route):** `git send-email` with `sendemail.*` config, or hand the files to Mail.app via `NSSharingService.composeEmail` (attachments) — the latter is the lightest path.

### RP-01 Request pull: Start from upstream, `…` pickers, *Send mail after create*, launch from push post-action `⚠️ Partial`
- **PangolinGit today:** Start defaults to the literal `origin/main` (`RequestPullWindowController.swift:52`); no pickers; not reachable after a push.
- **To implement:** Default to `@{upstream}`; CV-01; PU-04.

---

## 13. Submodules, Worktrees, Repository browser, Revision graph, Blame

**Already covered (✅):** Submodules window listing path / commit / state / URL with Add, Update/Init (all), Sync (all), Deinit (`Dialogs/Submodule/SubmoduleWindowController.swift`); Worktrees window listing path / branch / status with Add (new branch), Lock/Unlock, Remove (`Dialogs/Worktree/WorktreeWindowController.swift`); Repository Browser with revision field and Save File As (`Dialogs/RepoBrowser/RepoBrowserWindowController.swift`); per-row lane graph in the Log (`Views/RevisionGraph/RevisionGraphView.swift`); Blame window with colour by author/age, `-w`, `-C -C`, search, inspector with Show in Log / Diff with Previous / Copy SHA (`Dialogs/Blame/BlameWindowController.swift`).

### SU-01 Submodule Add options (Branch `-b`, Force, path browse, key) `⚠️ Partial`
- **PangolinGit today:** URL + path in an alert (`SubmoduleWindowController.swift:176-204`).

### SU-02 Submodule Update dialog (per-submodule selection under the clicked folder, *Whole project*, `--init`, `--recursive`, `--force`, `--no-fetch`, `--merge`, `--rebase`, `--remote`) `⚠️ Partial`
- **PangolinGit today:** One button updating everything with `--init --recursive`; no selection, no options, no busy indicator (`:220`).
- **To implement:** Checkbox list + the seven options; run with PR-01.

### SU-03 Submodule Sync as a Finder entry, *Update submodules* post-actions after checkout/reset/pull/switch `⚠️ Partial`
- **PangolinGit today:** Sync button exists in the window only (`:236`).

### SU-04 Submodule removal (`git rm` + `.gitmodules` cleanup), *Commit submodule…*, *Show log of submodule*, open submodule repo `❌ Missing`
- **PangolinGit today:** Deinit only (`:264`); the header comment promises removal (`:6`).

### SU-05 Submodule Diff dialog, submodule conflict dialog, dirty-submodule indicators in status lists `❌ Missing` (DF-13, MG-06).

### WT-01 New Worktree dialog (Directory with Browse, Base on HEAD / Branch / Tag / Commit, *Create new branch* optional, *Checkout* toggle, Force, Detach) `⚠️ Partial`
- **PangolinGit today:** Save panel + alert asking for a **new** branch name; always `worktree add -b` (`WorktreeWindowController.swift:160-179`); cannot use an existing branch, tag, commit or detached HEAD.
- **To implement:** Proper dialog with CV-01; `--no-checkout`, `--force`, `--detach`.

### WT-02 Columns (Path, Hash, Branch, Locked, Reason), Prune, Explore / double-click, Remove with force post-action, lock reason `⚠️ Partial`
- **PangolinGit today:** Hash parsed but not shown; no prune (header comment claims it, `:6`), no reveal-in-Finder, no `--force` fallback (`:110-157, 224-242`).

### WT-03 *Git New worktree…* via drag-and-drop `🍎 Platform` (SH-08).

### RBW-01 Repository browser tree structure `🐛 Broken`
- **What it does:** Explorer-like directory tree (left) and file list (right) at a chosen revision, works for bare repos.
- **PangolinGit today:** `parseLsTree` creates one top-level node per file with only the basename; directories are never built, so nothing can be expanded and same-named files are indistinguishable (`RepoBrowserWindowController.swift:150-173, 229-232`).
- **To implement:** Build the tree from path components (or use `git ls-tree` per directory lazily); split view with directory outline + file table.

### RBW-02 Revision chooser button (HEAD / branch / tag / commit) and `/rev` entry from Log, RefLog, Browse References `⚠️ Partial`
- **PangolinGit today:** Free-text revision + Go (`:65-76`).

### RBW-03 File actions: Open / Open with… / alternative editor, Compare with working tree, Show log (file/folder/submodule), Blame, Save as… (multi), Revert to this revision, Mark for diff / Diff with marked, Copy path / commit hash, drag to Finder, submodule update prompt, sortable columns, F5 `⚠️ Partial`
- **PangolinGit today:** *Save File As…* for one file (`:182-212`); no context menu, no open/preview, no diff, no log/blame, no sorting.
- **To implement:** Context menu wired to existing windows; `NSFilePromiseProvider` for drag-out; `QLPreviewPanel` for quick look of the blob.

### RG-01 Revision Graph window `❌ Missing`
- **What it does:** A separate graph of all commits that carry refs (branches, tags, notes, stashes, remotes) plus optional branch/merge points, with node colours by ref type, hover tooltips, overview window, zoom (in/out/100 %/fit height/width/graph), filter (range, only current / local branches), *Show branchings and merges*, *Show all tags*, arrow direction, Find, Compare revisions / HEAD revisions, unified diff, Compare with working tree, Show log, Browse repository, Switch to branch, Copy ref names, Delete branch/tag, Save graph as SVG/PNG/JPG/BMP/GIF/WMF/GV, F5, headless export via CLI.
- **How it works in TortoiseGit:** `TortoiseGit ▸ Revision Graph…`; OGDF layout; `/command:revisiongraph /output:`.
- **Example:** See at a glance where `release/1.0` forked from `main` and which tags sit on it.
- **PangolinGit today:** Only the per-row lane column inside the Log (`Views/RevisionGraph/RevisionGraphView.swift`, `LogWindowController.swift:243-254`); README's "Revision Graph" refers to that column (`README.md:19`). No standalone window, no `revgraph` command.
- **To implement:** `RevisionGraphWindowController` over `git log --simplify-by-decoration --format=%H %P %D`, a layered DAG layout (Sugiyama-style; a Swift port of the simplified `lanes.cpp` is already in `CommitGraphLaneEngine`), `CGContext` drawing with zoom, export via `NSBitmapImageRep`/`CGPDFContext` for PDF/SVG.

### BL-01 Blame at a revision (`/endrev`), *Blame previous revision* (parent submenu), *Compare with previous revision*, jump to line (`/line`), *Blame* from Log/Compare/Repo browser at that revision `⚠️ Partial`
- **PangolinGit today:** Always blames the working-tree file at HEAD (`BlameWindowController.swift:269-282`); *Diff with Previous* exists; no blame-at-parent navigation; *Show in Log* opens the whole log without selecting the commit (`:422-425`).
- **To implement:** `init(revision:line:)`; context menu on the commit column; Log window `selectCommit(hash)` API.

### BL-02 Detect moved/copied lines levels (Disabled / `-M` / `-C` / `-C -C` / `-C -C -C`) with character thresholds, `--first-parent`, follow renames, show complete log `⚠️ Partial`
- **PangolinGit today:** `-w` and `-C -C` toggles only (`:90-98`); settings pane has no controls for `blameIgnoreWhitespace`/`blameFollowCopies` even though the keys exist (`Dialogs/Settings/BlameSettingsView.swift`).

### BL-03 Revision/author highlighting on hover and click, log-message tooltip, *Next / Previous* block navigation, age-colour gradient endpoints from settings, syntax highlighting, wrap, dark mode, column toggles (log ID, author, date, file name, original line number) `⚠️ Partial`
- **PangolinGit today:** Row tint by author hash or age with fixed hues (`:385-401`); no hover highlight, no tooltip, no block navigation, no syntax highlighting; `blameDateFormat` setting is ignored (`:307-308`); rows re-created on every draw (`:494-500`).

### BL-04 Git Log docking pane (file history list that highlights lines of the selected commit, with its own context menu) and Properties pane `❌ Missing`
- **PangolinGit today:** A 2-line inspector (`:148-199`).
- **To implement:** Split view with `git log --follow -- path` list; selecting a commit highlights its lines; properties grid.

### BL-05 Encoding submenu, Find (F3/Shift-F3), Go to line, Copy, keyboard shortcuts, Open file / MRU `⚠️ Partial`
- **PangolinGit today:** Search filters rows out instead of navigating (`:357-370`); no encoding, no go-to.

### BL-06 Context menu on the commit column (Blame previous, Compare with previous, Show log, Copy SHA-1, Copy log to clipboard) and `.mailmap` author mapping `❌ Missing`
- **PangolinGit today:** Buttons in the inspector only; `GitMailmap` unused.

---

## 14. LFS locking, Git daemon, git-svn, Bug-tracker integration

**Already covered (✅):** LFS Locks window listing `git lfs locks` with Lock (typed path), Unlock, Force Unlock, Refresh (`Dialogs/LFS/LFSLocksWindowController.swift`).

### LF-01 LFS Lock / Unlock on the selected file from Finder and status lists `❌ Missing`
- **How it works in TortoiseGit:** `TortoiseGit ▸ LFS ▸ Lock / Unlock` on files; status-list context items; lockable files are read-only until locked.
- **PangolinGit today:** The window ignores the Finder selection and needs a typed relative path (`CommandRouter.swift:184-185`, `LFSLocksWindowController.swift:277-300`).
- **To implement:** `lfslock`/`lfsunlock` commands with the selection; status-list items (ST-17).

### LF-02 Locks dialog parity (Select/deselect all, multi-unlock, Force checkbox, auto-fallback to force, `--remote`, `--local`/`--cached`, filter) `⚠️ Partial`
- **PangolinGit today:** Single selection; every failure collapses to "LFS not initialized or no locks found" (`:186-192`).

### LF-03 LFS lock owner badge/overlay and column, lockable-pattern setup (`git lfs track --lockable`), `git lfs install` check `❌ Missing`.

### LF-04 LFS clone option `❌ Missing` (CN-01).

### GD-01 Git daemon (`git daemon --verbose --export-all --base-path`) with security warning and output window `❌ Missing`
- **Example:** Let a colleague on the LAN clone via `git://<host>/`.
- **To implement:** `daemon` command running the process under PR-01 with a Stop button; warning sheet.

### SV-01 git-svn integration (SVN Fetch, SVN Rebase, SVN DCommit with commit-type dialog, SVN Ignore import, clone from SVN) `❌ Missing`
- **PangolinGit today:** Nothing detects `.git/svn`.
- **To implement:** Detect `svn-remote` in config (SH-01 state), four commands, DCommit type sheet (`--rmdir`, remember `svn.rmdir`).

### BG-01 Issue-tracker (bugtraq) integration: `bugtraq.url/message/append/label/number/logregex/warnifnoissue`, Bug-ID field in Commit, Bug-ID column and clickable links in Log, regex tester, config levels with inherit `❌ Missing`
- **What it does:** Issue numbers typed in the commit dialog become links in the log and are appended to the message in a fixed format.
- **Example:** `bugtraq.url = https://github.com/org/repo/issues/%BUGID%` turns `#123` into a link.
- **PangolinGit today:** None.
- **To implement:** Settings ▸ Issue Tracker pane reading/writing `bugtraq.*` (git config, `.tgitconfig` equivalent); Commit dialog Bug-ID field + message assembly; Log column + link attributes (LG-13); regex tester sheet.

### BG-02 COM `IBugTraqProvider` plugins `🍎 Platform`
- macOS route: an `NSExtension`/XPC plugin point or a simple JSON-over-stdio "issue provider" protocol. Defer until BG-01 exists.

---

## 15. Settings, hooks, advanced

**Already covered (✅):** Settings window with 11 panes: General (git path, badge toggles, scan depth), Context Menu (30 toggles, select/deselect all), Dialogs (auto-close progress, commit-all, push-after-commit, confirm revert, max history), Colors (3 diff colours), Tools (external diff/merge paths and args), Network (proxies, SSL verify), Credentials (helper popup + write to global config), Hooks (enable flag, hooks dir), Blame (colour mode, font, size, date format), Saved Data (counts + clear), Advanced (free key/value table) (`Dialogs/Settings/*`).

### SE-01 Settings persistence `🐛 Broken`
- **What it does:** Every control's value is saved when the user leaves the page or presses OK/Apply.
- **PangolinGit today:** No OK/Apply/Cancel bar (`SettingsWindowController.swift:159-161` is an empty `setupBottomBar`), `saveAll()` has no callers (`:163-174`); text fields have no action or delegate, so typed values (git path, scan depth, proxy URLs, tool paths/args, font size, date format, hooks dir, max history) persist only if another control in the same pane fires afterwards; the General pane's two checkboxes are created with `action: nil` (`:7-8`), so toggling badge visibility never saves.
- **To implement:** `controlTextDidEndEditing` + `windowWillClose` → `saveAll()`; wire the checkbox actions; optional Apply/Cancel.

### SE-02 Settings stored but read by nothing `🐛 Broken`
- `recursiveStatusDepth` (General), `autoCloseProgress` (Dialogs), `diffAdded/Deleted/ModifiedColorHex` (Colors), `externalDiffTool/MergeTool/*Args` (Tools), `httpProxy/httpsProxy/noProxy/sslVerify` (Network), `hooksEnabled/customHooksDirectory` (Hooks), `blameDateFormat` (Blame), `credentialHelper` (Credentials; only the explicit *Write to Global Git Config* button has an effect), `advancedSettings` (Advanced), `recentUrls` (never written) — see `ConfigManager.swift` and the consumer table in the inventory. Each is resolved by the feature that should consume it (SH-07, PR-02, DF-06, DF-14, DA-03, SE-12, BL-03, DA-01, SE-14, PF-02).

### SE-03 General page: Language, weekly update check + *Check now*, re-run First Start Wizard, Extra PATH, *Show environment variables*, git version check `⚠️ Partial`
- **PangolinGit today:** Git path + Browse, two badge checkboxes, scan depth (`SettingsWindowController.swift:4-95`). The wizard is reachable only via URL (`pangolingit://firstrun`).
- **To implement:** Buttons for wizard and update check; `git --version` label; extra PATH field consumed by `GitCLIRunner`; language popup (requires localisation, CC-06).

### SE-04 Colors pages (status colours: conflict, added, deleted, merged, modified, renamed; revision graph note/unknown colours; log graphic: current/local/remote branch, tag, filter match; eight graph line colours, line width, node size; dark theme; Restore Default) `⚠️ Partial`
- **PangolinGit today:** Three diff colours, unread (`ColorsSettingsView.swift`); the log graph uses eight fixed colours (`RevisionGraphView.swift:41-44`).
- **To implement:** Extend `ConfigManager` with the colour set; read it in `StatusListView`, `LogWindowController` label chips, `RevisionGraphView`, `SideBySideDiffView`, Blame.

### SE-05 Icon Overlays page (cache mode, drive types, exclude/include paths, show excluded as normal, unversioned→parent modified, submodule status in parent, elevated-process guard), Icon Set page (choose overlay set, preview), Overlay Handlers page (enable/disable per status) `⚠️ Partial`
- **PangolinGit today:** Only "show unversioned" and "show ignored" (and even those only save via Browse, SE-01).
- **To implement:** Overlays pane covering SH-04/SH-06/SH-07; an icon-set popup (SF Symbol set vs. classic Tortoise-style PNG set, both registered via `setBadgeImage`).

### SE-06 Dialogs 1 page (log limitation default, message font, short date/time, relative times, asterisk prefix, system locale, double-click compare, abbreviate renamings, symbolise refs, log cache, Gravatar + URL, labels right, subject+body, branch revision number, describe options) `❌ Missing`
- **PangolinGit today:** None of these exist (`DialogSettingsView.swift` has five unrelated checkboxes).
- **To implement:** Land each with its Log feature (LG-02, LG-05, LG-13, LG-14, LG-15, LG-17).

### SE-07 Dialogs 2 page (auto-close progress modes, recycle bin on revert, confirm kill git, randomise sync position, hide unchanged refs, show timings, reversed tag order, disable sounds, include FETCH_HEAD, use .mailmap, autocompletion + timeout, max log-message history, select items automatically, don't auto-select missing, strip `#` lines) `⚠️ Partial`
- **PangolinGit today:** `defaultCommitAll`, `showPushAfterCommit`, `confirmOnRevert`, `maxRecentHistory`, `autoCloseProgress` (unread) only.

### SE-08 Dialogs 3 page (git-config-stored per-repo options: config source Effective/Local/Project/Global/System + Save to, spell-check language, `tgit.logminsize`, `tgit.logwidthmarker`, `tgit.warnnosignedoffby`, `tgit.icon` project logo) `❌ Missing`
- **To implement:** A "Repository settings" pane that edits `git config --local/--global` with inherit checkboxes; consumed by CM-11, CM-03, CM-08.

### SE-09 Git page (user name/email/signing key with inherit, AutoCrLf/SafeCrLf, QuotePath, Prune; buttons to edit local `.git/config`, `.tgitconfig`, global `.gitconfig`, XDG config, system config, view effective config) `❌ Missing`
- **PangolinGit today:** User identity is set only in the first-run wizard (`FirstRunWindowController.swift:175-183`); no config editor.
- **To implement:** Git pane with the fields and *Open in editor* buttons (`NSWorkspace.open` on the config paths).

### SE-10 Remote page inside Settings (list, Add/Save/Remove/Rename, URL, Push URL, key, Tags, Push default, Prune) `⚠️ Partial` (RM-01; the standalone Remotes window covers a subset).

### SE-11 External programs: Diff viewer (built-in vs external with `%base %mine …`), Unified-diff viewer, Merge tool with *Block while running* and *Trust exit code*, per-extension Advanced tables, Alternative editor `🐛 Broken` (DF-14) — paths are stored but never launched; no per-extension tables; no alternative editor setting.

### SE-12 Hook Scripts page (client-side hooks: Start-commit, Pre-commit, Post-commit, Pre-push, Post-push, Pre-rebase; Enable, Run for this repository (`.tgitconfig`, `%root%`), path scope, command line, Wait for script, Hide while running; failure → Abort / Proceed) `🐛 Broken` + `❌ Missing`
- **What it does:** Run user scripts around TortoiseGit actions (not git's own `.git/hooks`), e.g. to prefill or validate commit messages, run tests before push.
- **PangolinGit today:** The Hooks pane stores `hooksEnabled` and `customHooksDirectory`, neither read (`HooksSettingsView.swift:70-77`); git's own hooks always run (`--no-verify` never used); `core.hooksPath` is never set.
- **To implement:** Hook table in `ConfigManager` (type, path scope, command, wait, hidden, enabled, repo-provided); runner invoked by Commit/Push/Rebase dialogs with the documented argument order (`PATH MESSAGEFILE CWD`, `ERROR CWD`, …); honour `customHooksDirectory` via `-c core.hooksPath=`.

### SE-13 TortoiseGitBlame / TortoiseGitUDiff settings pages (age-gradient endpoints, font, tab size, moved/copied detection level and thresholds, first-parent, complete log, follow renames; UDiff colours per element, font, tab size) `⚠️ Partial`
- **PangolinGit today:** Blame pane has colour mode, font, size, unread date format; no thresholds, no UDiff page.

### SE-14 Advanced page with documented keys `🐛 Broken`
- **PangolinGit today:** A free-form dictionary editor whose values nothing reads (`AdvancedSettingsView.swift`, `ConfigManager.swift:260-265`).
- **To implement:** Replace with a typed list of real options (candidates from TortoiseGit's 52 keys that make sense on macOS: `AutoCompleteMinChars`, `DiffSimilarityIndexThreshold`, `LogTooManyItemsThreshold`, `LogIncludeWorkingTreeChanges`, `NumDiffWarning`, `ProgressDlgLinesLimit`, `SanitizeCommitMsg`, `ShortHashLengthForHyperLinkInLogMessage`, `SquashDate`, `StyleCommitMessages`, `StyleGitOutput`, `VersionCheck`, `ShowContextMenuIcons`, `NoSortLocalBranchesFirst`, `RememberFileListPosition`, `ReaddUnselectedAddedFilesAfterCommit`, `RefreshFileListAfterResolvingConflict`, `FetchVerbose`, `MaxRefHistoryItems`, `OverlaysCaseSensitive`), each read where relevant.

### SE-15 Saved Data page (URL history, log-message history per repo, log cache, dialog sizes/positions, authentication data, temp files, stored decisions, action log with Show/Clear/max lines) `⚠️ Partial`
- **PangolinGit today:** Three counters + Clear buttons (`SavedDataSettingsView.swift`); `recentUrls` is always 0; no "don't ask again" store, no action log, no window-frame reset.
- **To implement:** `StoredDecisions` store used by all "don't show again" sheets; action log file (`~/Library/Logs/PangolinGit/action.log`) written by `GitCLIRunner`; frame autosave reset.

### SE-16 Context Menu page completeness and Context Menu 2 (extended entries) `⚠️ Partial` (SH-03, SH-14).

### SE-17 Settings tooltips, Help button, `/page:` deep links, export/import of settings `❌ Missing`
- **To implement:** Tooltips on every control; `pangolingit://settings?page=<id>`; export/import of the defaults suite as a `.plist`.

### SE-18 Windows-specific pages `🍎 Platform`: Windows 11 context menu (SH-13), Icon Set (partly, SE-05), Overlay Handlers slots (no slot limit on macOS), Create Library, Cygwin/MSYS2 hacks, SSH client path (macOS uses system `ssh`; offer `core.sshCommand` override instead).

---

## 16. Progress dialog and cross-cutting behaviours

**Already covered (✅):** All git calls run off the main thread via `GitCLIRunner.run` (`Core/Git/GitCLIRunner.swift:141-160`); in-process `RepositoryEvents` notifications refresh Commit/Add/Log/Sync/Changed windows after Commit/Add/Ignore/Push/Pull/Sync/status-list actions (`App/RepositoryEvents.swift`); one window per (command, repository) with bring-to-front (`App/WindowRegistry.swift`); launcher with recent repositories (`App/LauncherWindowController.swift`).

### PR-01 Git command progress dialog (live output, progress bar, Close/Abort, auto-close modes, coloured errors, timings) with context-sensitive post-action buttons `🐛 Broken`
- **What it does:** Every long operation (clone, fetch, pull, push, rebase, commit, add, revert, resolve, submodule update, reset, clean) streams git's output into a window; afterwards a drop-down offers the natural next step (Resolve, Commit…, Push, Pull, Stash pop, Update submodules, Request pull, ReCommit, Create tag, Bisect good/bad, Retry, Remove branch, Merge unrelated history, Clean to recycle bin / permanently).
- **How it works in TortoiseGit:** `GitProgressDlg` / `ProgressDlg` with `PostCmdList`; "Autoclose git.exe dialog" setting (close manually / auto-close if no further options / auto-close if no errors; `/closeonend` override).
- **Example:** After `git pull` reports conflicts the user clicks *Resolve…* in the same window.
- **PangolinGit today:** `ProgressWindowController` is fully written but never instantiated (`Dialogs/Progress/ProgressWindowController.swift`; no references elsewhere); `GitCLIRunner` reads pipes to EOF so there is no streaming API (`GitCLIRunner.swift:122-131`); each dialog shows a one-line status label, disables a button, and cannot abort a running process. README lists "Progress monitor" (`README.md:12`).
- **To implement:** Add `GitCLIRunner.stream(arguments:onLine:)` using `FileHandle.readabilityHandler`; present `ProgressWindowController` from every mutating dialog; implement `postActions: [(title, handler)]`; honour `autoCloseProgress` (three modes); `Process.terminate` on Abort; colour error lines (`StyleGitOutput`); optional timing line.

### PR-02 Status-list progress dialog for add/revert/resolve/reset (list of processed items, *Show log…*) `❌ Missing` — same component with a table instead of text.

### PR-03 Repository-wide refresh after every action `🐛 Broken`
- **PangolinGit today:** Reset, Revert, Rename, Remove, Merge editor, Changed Files' stage/unstage/revert, Log's revert, Switch, Branch/Tag creation, Browse References checkout/delete, Rebase, Stash, Worktree, Submodule, Remotes, Patch apply, Bisect, LFS and Export never post `RepositoryEvents` (inventory §Cross-cutting); the Finder cache is never invalidated from the app (SH-17).
- **To implement:** Post from a single place: wrap mutating runs in `GitCLIRunner.runMutating(repo:)` that posts the event and calls the agent's `invalidateCache` on completion.

### PR-04 "Don't show again" stored decisions on prompts `❌ Missing` (SE-15).

### PR-05 Help (F1 / Help button on every dialog → user guide topic) `❌ Missing`
- **PangolinGit today:** Help menu points at a placeholder GitHub wiki URL (`AppDelegate.swift:119`).
- **To implement:** Bundle a converted user guide (the DocBook sources can be rendered to HTML) and open the dialog's anchor from a `?` button; `/command:help`.

### PR-06 Dialog titles with path context, taskbar grouping per working tree, full-path tooltips, remembered dialog sizes/positions `⚠️ Partial`
- **PangolinGit today:** Titles are "<Dialog> — <repo folder>"; `representedURL` is set; only the launcher and a few windows use frame autosave (`LauncherWindowController.swift`); no `DialogTitles` option.
- **To implement:** `setFrameAutosaveName` in every window; title style option.

### PR-07 Error reporting standard (full stderr, copyable, retry) `⚠️ Partial`
- **PangolinGit today:** Mixed: one-line labels (Push, Pull, Clone, Branch, Switch, Rebase start) vs modal `NSAlert(error:)`; `GitCLIError.commandFailed.command` records only the first two argv tokens (`GitCLIRunner.swift:228`).
- **To implement:** PR-01 as the single error surface; record the full argv.

### PR-08 Multi-selection semantics across dialogs `⚠️ Partial`
- **PangolinGit today:** Every table except the status list and FileDiff is single-selection (`LFSLocksWindowController.swift:70` explicitly; others via `selectedRow`).

### PR-09 Window-per-repository main window / Dock menu / File ▸ Recent `⚠️ Partial`
- **PangolinGit today:** Standalone dialogs only (matches TortoiseGit); no Dock menu, no *Open Recent* submenu (recent list only in the launcher).
- **To implement:** `applicationDockMenu` with recent repositories; File ▸ Open Recent.

### PR-10 Spell checking with custom dictionaries / Windows spell checker choice `✅ Present` via `NSTextView` continuous spell checking; language from Dialogs 3 (SE-08) missing.

---

## 17. Automation CLI, GitWCRev, SSH, update check, About, First-start wizard

**Already covered (✅):** `pangolingit://<command>?path=…` URL scheme with 39 commands (`Commands/CommandRouter.swift:7-57`); `pangolin-wcrev <wc> <template> <output> [-f]` with `$WCREV$ $WCHASH$ $WCDATE$ $WCNOW$ $WCBRANCH$ $WCURL$ $WCMODS?T:F$` (`tools/pangolin-wcrev.swift`); SSH window listing `~/.ssh/*.pub`, Ed25519 key generation, copy public key, test connection (`Dialogs/SSH/SSHKeyWindowController.swift`); *Check for Updates…* against GitHub releases (`App/SparkleUpdater.swift`); About panel with credits; four-step first-run wizard (welcome, git path + auto-detect, identity, Finder extension) (`Dialogs/FirstRun/FirstRunWindowController.swift`); `.pkg` installer with pre/post-install scripts and `uninstall.sh` (`tools/`, `installer/`).

### AU-01 Command-line switches beyond `path` `❌ Missing`
- **What it does:** `TortoiseGitProc /command:log /path:… /rev:SHA /startrev /endrev /range /limit /findstring /findtype /outfile /submodule`; `commit /logmsg /logmsgfile /bugid`; `diff /path2 /startrev /endrev /unified /line`; `showcompare /revision1 /revision2`; `blame /endrev /line`; `cat /savepath /revision`; `rebase /upstream /force`; `stashsave /msg`; `bisect /start /good /bad /skip /reset`; `clone /url /exactpath`; `settings /page`; `revisiongraph /output`; `tag|branch /rev /name`; `/closeonend`; `resolve /noquestion`; `merge /abort`; `updatecheck /visible /force`; `pgpfp`; `repocreate`, `cleanup`, `cat`, `help`, `conflicteditor`, `repostatus`, `refbrowse`, `subadd/subupdate/subsync`, `stashapply/stashpop`, `daemon`, `worktreelist`, `lfslocks`; multiple paths via `*`; `/notempfile` compatibility.
- **PangolinGit today:** Only `path` query items are parsed (`CommandRouter.swift:66-77`); no `pangolingit` shell command (the URL scheme can be driven with `open "pangolingit://log?path=…"`).
- **To implement:** Generic query-parameter passthrough (`rev`, `startrev`, `endrev`, `range`, `logmsg`, `logmsgfile`, `line`, `unified`, `closeonend`, `page`, `url`, `name`, `msg`, `output`) into each window's initialiser; a `pangolingit` CLI shim in `Contents/MacOS` that builds the URL (`pangolingit log --path . --rev abc`); document in `docs/`.

### AU-02 Standalone tool CLIs (`TortoiseGitMerge /base /mine /theirs /merged /diff /patchpath /oneway /readonly /line /createunifieddiff…`, `TortoiseGitIDiff /left /right /overlay /fit /base /mine /theirs /result`, `TortoiseGitUDiff /patchfile /title /p`, `TortoiseGitBlame`) `❌ Missing`
- **PangolinGit today:** `imagediff` URL takes one path; merge needs a conflicted file in a repo; no stdin pipe.
- **To implement:** `pangolingit merge --base --mine --theirs --merged`, `pangolingit idiff --left --right`, `pangolingit udiff --patchfile|-` so git's `difftool`/`mergetool` can be pointed at PangolinGit (`git config merge.tool pangolingit`).

### WC-01 `pangolin-wcrev` keyword and option parity `⚠️ Partial`
- **Missing keywords:** `$WCREV=n$` (truncate), `$WCLOGCOUNT$` (+/-/& arithmetic), `$WCDATEUTC$`, `$WCNOWUTC$`, `$WCDATE=fmt$`/`$WCNOW=fmt$` (strftime), `$WCFILEMODS?$`, `$WCUNVER?$`, `$WCISTAGGED?$`, `$WCINGIT?$`, `$WCSUBMODULE?$`, `$WCSUBMODULEUP2DATE?$`, `$WCMODSINSUBMODULE?$`, `$WCUNVERINSUBMODULE?$`, `$WCMODSFULL?$`, `$WCUNVERFULL?$`.
- **Missing options:** `-m/-M` (exit 7 on modifications), `-u/-U` (exit 11 on unversioned), `-d` (exit 9 if destination exists), `-s` (exclude submodules), `-F` (ignore `.gitwcrevignore`), `-q`; `.gitwcrevignore` support; documented error codes 1–11; status print without template (two-argument form).
- **PangolinGit today:** Seven keywords; hard-codes `/usr/bin/git` (`tools/pangolin-wcrev.swift:91`) ignoring the configured git; failed git calls silently become `UNKNOWN`/`0000…` with exit 0 (`:38-42`); `-f` matched anywhere in argv (`:29`); `$WCMODS?…$` regex forbids `:` in the true branch (`:60`).
- **To implement:** Rewrite the substitution as a small tokenizer; add the flags and exit codes; resolve git like `GitCLIRunner`; `.gitwcrevignore` via `git status --porcelain` filtering. The COM object has no macOS equivalent; offer `--json` output instead.

### SK-01 SSH window parity (Generate PuTTY key pair ↔ RSA/ECDSA/Ed25519 choice and bits, add key to agent with Keychain (`ssh-add --apple-use-keychain`), per-remote key, `~/.ssh/config` editing, known_hosts management, fingerprint display, delete/import key, passphrase not on the command line) `⚠️ Partial`
- **PangolinGit today:** Ed25519 only (`SSHKeyWindowController.swift:215`); passphrase passed via `-N` on the command line (visible in `ps`); no agent integration; no fingerprint (`:153-242`).
- **To implement:** Key-type popup; pass the passphrase through `SSH_ASKPASS` or an expect-style pty instead of argv; `ssh-keygen -lf` fingerprint; *Add to agent* button; per-remote key stored as `remote.<n>.sshkey` → `core.sshCommand="ssh -i …"`.

### UP-01 Update check dialog (your version vs. current, changelog pane with signature verification, download list incl. language packs, Download/Install, *Don't ask again*, *Remind me later*, weekly automatic check, preview channel, intranet `UpdateCheckURL` override) `⚠️ Partial`
- **PangolinGit today:** Manual GitHub API check with a *View Release* link; no Sparkle framework despite the class name and plan claims (`App/SparkleUpdater.swift:5-7`); no automatic check; `VersionCheck` setting absent.
- **To implement:** Either integrate Sparkle 2 (appcast, EdDSA signing, background checks) or extend the current checker with a changelog pane, download-and-open, "remind later" and weekly scheduling; add Settings ▸ General controls.

### UP-02 About dialog (versions of git and libraries, contributors, website/support links, *Check for Updates…* button) `⚠️ Partial`
- **PangolinGit today:** Standard About panel with credits links (`CommandRouter.swift:192-211`); no git version, no update button.

### FW-01 First-start wizard pages (language, git path with *Check now* and version, extra PATH, identity with *Don't store now*, authentication: SSH client / key pair generation / credential helper, Advanced…) `⚠️ Partial`
- **PangolinGit today:** Welcome, git path (no validation), identity, Finder extension; synchronous git calls on the main thread (`FirstRunWindowController.swift:124, 133, 179, 182`); *Auto Detect* clears the saved path immediately (`:158`); closing the window re-shows the wizard on every launch (`:184-189`).
- **To implement:** `git --version` validation, credential-helper + SSH page (osxkeychain default, generate key), async calls, mark completed on close with defaults.

### FW-02 Finder-extension enablement prompt with "don't ask again" `⚠️ Partial`
- **PangolinGit today:** `ExtensionHelper.promptIfNeeded` runs on every launch while the extension is off (`App/ExtensionHelper.swift:82-111`); no suppression (PR-04).

### IN-01 Installer / packaging parity (signed, notarised, language packs, MSI group-policy deployment, admin registry policies for update URL, SSH client, context-menu masks) `🍎 Platform`
- **PangolinGit today:** `.pkg` with optional notarisation; `tools/create_dmg.sh` looks in the wrong build folder and fabricates an empty bundle when the app is missing (`tools/create_dmg.sh:12, 24-30`); Homebrew cask has a placeholder SHA (`PangolinGit.rb:3`); `uninstall.sh --purge` misses the Group Container (`tools/uninstall.sh`).
- **To implement:** Fix the DMG script path; managed-preferences (MDM) profile keys for `UpdateCheckURL`, `VersionCheck`, hidden context-menu entries as the macOS counterpart of `HKLM` policies.

---

## 18. PangolinGit-internal defects that block parity (quick fixes)

These are not TortoiseGit features but bugs or dead code found during the scan. Fixing them is cheap and removes false claims from `README.md` / `doc/IMPLEMENTATION_PLAN.md`.

| # | Defect | Evidence | Fix |
|---|---|---|---|
| QF-01 | Ignore dialog on repository root appends literal `/new-file.txt` | `Dialogs/Ignore/IgnoreWindowController.swift:81, 147` | Disable exact-path radio for empty relative path (IG-02). |
| QF-02 | Reset dialog defaults to `HEAD~1` and its *Log…* button cannot return a commit | `Dialogs/Reset/ResetWindowController.swift:18, 106-108` | Default `HEAD`; LG-23 picker. |
| QF-03 | Log changed-file double-click diffs HEAD vs working tree instead of commit vs parent | `Dialogs/Log/LogWindowController.swift:363-369` | Pass `old: "<sha>~1", new: "<sha>"`. |
| QF-04 | Browse References search field filters nothing | `Dialogs/BrowseRefs/BrowseRefsWindowController.swift:201-205, 355-375` | Apply filter in data source (BR-01). |
| QF-05 | Repository browser never builds directory nodes (flat list of basenames) | `Dialogs/RepoBrowser/RepoBrowserWindowController.swift:150-173` | Build tree (RBW-01). |
| QF-06 | Settings: no save on close, `saveAll()` uncalled, General checkboxes have nil actions, text fields never persist | `Dialogs/Settings/SettingsWindowController.swift:7-8, 159-174` | SE-01. |
| QF-07 | Twelve settings keys stored but never read | `Core/Config/ConfigManager.swift` | SE-02 consumers. |
| QF-08 | `ProgressWindowController` and `CredentialPromptWindowController` never instantiated | `Dialogs/Progress/*`, `Dialogs/Credentials/*` | PR-01 / DA-01 (or delete). |
| QF-09 | `MenuRules`/`MenuState`, `PathRequirement`, `GitIndex`, `GitMailmap`, `GitPatch`, `GitFolderStatus`, `OverlayIconView`, `LayoutHelper`, `DiffEngine.computeUnifiedDiff` have no callers | `Commands/MenuRules.swift`, `Core/Models/PathRequirement.swift`, `Core/Git/*`, `Views/*` | Wire in (SH-01, LG-24, MG-10, CC-06) or remove. |
| QF-10 | Image diff unreachable; `oldImageURL` always nil | `Commands/CommandRouter.swift:150-151` | DF-09. |
| QF-11 | Clone destination pre-filled with an existing folder (clone fails); runs with inherited cwd; no post-open | `Dialogs/Clone/CloneWindowController.swift:26, 170` | CN-02. |
| QF-12 | Sync hard-codes `origin/` and swallows fetch errors | `Dialogs/Sync/SyncWindowController.swift:115, 144` | Use `@{upstream}` name; surface errors. |
| QF-13 | Request Pull start defaults to literal `origin/main` | `Dialogs/RequestPull/RequestPullWindowController.swift:52` | `@{upstream}`. |
| QF-14 | Rebase omits `reword` though README advertises it; in-progress state not detected | `Dialogs/Rebase/RebaseWindowController.swift:5-12` | RB-01, RB-02. |
| QF-15 | Worktree add always creates a new branch; header claims prune support | `Dialogs/Worktree/WorktreeWindowController.swift:6, 179` | WT-01/02. |
| QF-16 | Submodule header claims removal; only deinit exists | `Dialogs/Submodule/SubmoduleWindowController.swift:6, 264` | SU-04. |
| QF-17 | Most dialogs never post `RepositoryEvents`; app never invalidates the Finder cache | inventory §Cross-cutting; `PangolinGitAgent/main.swift:54-57` | PR-03. |
| QF-18 | RefLog parser truncates subjects containing a pipe character | `Dialogs/RefLog/RefLogWindowController.swift:114-126` | RL-02. |
| QF-19 | Context Menu settings omit `merge`, `rebase`, `filediff`, `branch`, `clone`, `firstrun` so they cannot be hidden | `Dialogs/Settings/ContextMenuSettingsView.swift:13-44` | SH-14. |
| QF-20 | `SparkleUpdater` is not Sparkle; plan/README claim Sparkle | `App/SparkleUpdater.swift:5-7` | UP-01. |
| QF-21 | Export directory mode runs `tar` synchronously on the main actor | `Dialogs/Export/ExportWindowController.swift:165-169` | Async + PR-01. |
| QF-22 | SSH key generation passes the passphrase on argv | `Dialogs/SSH/SSHKeyWindowController.swift:215` | SK-01. |
| QF-23 | `pangolin-wcrev` hard-codes `/usr/bin/git` and hides git failures | `tools/pangolin-wcrev.swift:38-42, 91` | WC-01. |
| QF-24 | `create_dmg.sh` fabricates an empty bundle; cask SHA placeholder; purge misses Group Container | `tools/create_dmg.sh:24-30`, `PangolinGit.rb:3`, `tools/uninstall.sh` | IN-01. |
| QF-25 | Localisation: 11-key string catalog, zero `NSLocalizedString` call sites; no accessibility labels | `PangolinGit/Resources/Localizable.xcstrings`; grep | CC-06. |
| QF-26 | Blame ignores `blameDateFormat`; rows rebuilt on every draw; Log cells not reused | `Dialogs/Blame/BlameWindowController.swift:308, 494-500`; `LogWindowController.swift:256-273` | BL-03, LG-15. |
| QF-27 | Revert dialog shows raw enum names (`Stagedmodified`) and resets conflicted files to HEAD silently | `Dialogs/Revert/RevertWindowController.swift:164-186, 290` | RV-05. |
| QF-28 | Merge editor reports "Clean merge" for any non-UTF-8 or non-conflicted file | `Dialogs/Merge/MergeWindowController.swift:205-243, 287-296` | MG-04/MG-06. |
| QF-29 | Stale status tables in `doc/IMPLEMENTATION_PLAN.md` (e.g. log listed as missing graph/filter/context menu that now exist; Sparkle, Keychain, progress listed as completed) | `doc/IMPLEMENTATION_PLAN.md:881-1041` | Regenerate from this document. |

### CC-06 Localisation and accessibility `⚠️ Partial`
- **What it does:** TortoiseGit ships language packs and the UI language is selectable (Settings ▸ General); dialogs are screen-reader friendly.
- **PangolinGit today:** Every string is a hard-coded English literal; `LocalizationHelper` and the RTL helpers are unused; no accessibility identifiers.
- **To implement:** Adopt `String(localized:)` across dialogs, grow the catalog, add `setAccessibilityLabel` on icon-only controls.

---

## 19. Suggested implementation order

The order below front-loads shared infrastructure that many later items depend on, then walks the everyday workflow (status → commit → log → diff → sync), then the advanced tools. Each phase is sized so it can be a single milestone.

| Phase | Goal | Items |
|---|---|---|
| **P0 — Foundations** | Make settings and refresh work; one progress/error surface; one revision chooser; log picker. | SE-01, SE-02, PR-01, PR-02, PR-03, PR-07, SH-17, CV-01, LG-23, BR-10, QF-01…QF-13 |
| **P1 — Finder parity** | State-aware menu, placement settings, badge coverage, missing entry points. | SH-01, SH-02, SH-03, SH-14, SH-15, SH-16, SH-04, SH-05, SH-06, SH-21, CR-01, SE-05, SE-16 |
| **P2 — Status & commit** | Everyday loop. | ST-01…ST-19, CM-01…CM-23, AD-01, AD-02, DL-01…DL-03, IG-01…IG-04, CU-01, RV-01…RV-07, RS-01…RS-05 |
| **P3 — Log** | Full log dialog. | LG-01…LG-25, SE-06, SE-07 |
| **P4 — Diff & merge editor** | Editor-grade diff/merge. | DF-01…DF-17, MG-01…MG-17, SE-11, SE-13 |
| **P5 — Branching & history rewriting** | Switch/branch/refs/merge/rebase/cherry-pick/bisect/reflog/stash. | SW-01…SW-06, BT-01, BT-02, BR-01…BR-12, RB-01…RB-08, BI-01, BI-02, RL-01…RL-05, SS-01…SS-05 |
| **P6 — Remote workflow** | Pull/push/sync/clone/remotes/credentials. | PF-01…PF-07, PU-01…PU-05, SY-01…SY-04, CN-01, CN-02, RM-01…RM-03, DA-01…DA-03, SE-09, SE-10 |
| **P7 — Patches, export, mail** | Patch series, apply series, send mail, request pull, export. | PT-01…PT-05, SM-01, RP-01, EX-01, EX-02 |
| **P8 — Advanced tools** | Submodules, worktrees, repo browser, revision graph, blame. | SU-01…SU-05, WT-01…WT-03, RBW-01…RBW-03, RG-01, BL-01…BL-06 |
| **P9 — Integrations** | LFS, daemon, git-svn, bug tracker, hooks. | LF-01…LF-04, GD-01, SV-01, BG-01, BG-02, SE-12, SE-08 |
| **P10 — Platform & polish** | CLI, wcrev, SSH, updater, wizard, localisation, help. | AU-01, AU-02, WC-01, SK-01, UP-01, UP-02, FW-01, FW-02, IN-01, PR-04…PR-10, SE-03, SE-14, SE-15, SE-17, CC-06, QF-14…QF-29 |

Items marked 🍎 (SH-08, SH-10, SH-11, SH-13, SH-18, BG-02, DA-02, WT-03, SE-18, IN-01) need an explicit macOS design decision before scheduling; the suggested routes are given inline.

---

## Appendix A — Sources consulted

- TortoiseGit user guide: `doc/source/en/TortoiseGit/tgit_dug/dug_*.xml` (all 55 files), `tgit_introduction.xml`, `tgit_app_automation.xml`, `tgit_app_admins.xml`, `tgit_app_internals.xml`, `tgit_app_ssh.xml`, `tgit_bugtraqprovider.xml`, `tgit_gitwcrev.xml`; `doc/source/en/TortoiseMerge/*.xml`.
- TortoiseGit sources for undocumented controls: `src/Resources/TortoiseProcENG.rc`, `TortoiseMergeENG.rc`, `TortoiseGitBlameENG.rc`, `TortoiseGitMergeRibbon.xml`; `src/TortoiseShell/MenuInfo.cpp`, `ContextMenu.cpp`, `GITPropertyPage.cpp`; `src/TortoiseProc/*Dlg.cpp`, `GitLogListBase.cpp`, `GitStatusListCtrl.cpp`, `AppUtils.cpp`, `SettingsAdvanced.cpp`, `SetHooksAdv.cpp`, `StatGraphDlg.cpp`, `CheckForUpdatesDlg.cpp`; `src/TortoiseIDiff/*`, `src/TortoiseUDiff/*`, `src/TortoiseGitBlame/*`.
- PangolinGit: every `.swift` file under `PangolinGit/`, `PangolinGitCore/Sources`, `PangolinGitCore/Tests`, `PangolinGitAgent/`, `PangolinGitFinder/`, `PangolinGitAskPass/`, `tools/`; `project.yml`, `Info.plist` files, `README.md`, `docs/BUILDING.md`, `docs/QA_TEST_PLAN.md`, `doc/IMPLEMENTATION_PLAN.md`, `installer/scripts/*`, `PangolinGit.rb`.

## Appendix B — ID index

| Prefix | Area |
|---|---|
| SH | §1 Finder / shell integration |
| ST | §2 Check for Modifications / file list |
| AD, DL, RN, IG, CU | §3 Add / Delete / Rename / Ignore / Clean up |
| CM | §4 Commit |
| LG | §5 Log and Statistics |
| DF | §6 Diff family |
| MG | §7 Merge editor / patch apply |
| RV, RS | §8 Revert / Reset / Resolve |
| CV, SW, BT, BR | §9 Switch / Branch / Refs / Merge dialog |
| RB, BI, RL, SS | §10 Rebase / Bisect / RefLog / Stash |
| PF, PU, SY, CN, CR, RM, DA | §11 Remote operations |
| EX, PT, SM, RP | §12 Export / Patch / Mail / Request pull |
| SU, WT, RBW, RG, BL | §13 Submodules / Worktrees / Repo browser / Revision graph / Blame |
| LF, GD, SV, BG | §14 LFS / daemon / svn / bug tracker |
| SE | §15 Settings |
| PR | §16 Progress / cross-cutting |
| AU, WC, SK, UP, FW, IN | §17 CLI / WCRev / SSH / update / wizard / installer |
| QF, CC | §18 Quick fixes / cross-cutting defects |

