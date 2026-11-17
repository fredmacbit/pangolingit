<p align="center"><img src="PangolinGit/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="160" alt="PangolinGit icon"></p>

# PangolinGit

**A macOS-native Git GUI client with deep Finder integration**

PangolinGit brings the power of [TortoiseGit](https://tortoisegit.org) to macOS, providing overlay badges, context menus, and toolbar buttons directly in Finder — plus a full-featured standalone application for all Git operations.

## Features

- **Finder Integration** — Overlay badges showing Git status (normal, modified, conflicted, added, deleted, ignored, unversioned) and rich context menus directly in macOS Finder
- **Essential Dialogs** — Commit, Log, Push, Pull, Fetch, Sync, Clone, Create Branch/Tag, Switch/Checkout, Progress monitor
- **Changed Files Inspector** — Full working tree change aggregator with batch revert, staging, diffing, and committing (`ChangedDlg.cpp` clone)
- **Reference Browser** — Hierarchical outline view for local branches, remote-tracking branches, and tags with checkout/delete/merge controls (`BrowseRefsDlg.cpp` clone)
- **Advanced Git Operations** — Interactive Rebase (`pick`, `squash`, `reword`, `drop`), Stash manager (Save, Pop, Apply, Drop), Reset (soft, mixed, hard, keep), and Worktrees/Submodules management
- **Diff & 3-Way Merge** — Two-way diff, unified diff, and visual 3-way conflict resolver (`TortoiseMerge` clone) with Myers O(ND) algorithm
- **Image Diff Tool** — Visual comparison for images with Side-by-Side, Alpha Blend, and Curtain Swipe modes (`TortoiseIDiff` clone)
- **Blame Annotator** — Color-coded commit age and author annotation view
- **Revision Graph & Statistics** — Core Graphics commit DAG lane visualizer (`lanes.cpp` port) and repository contributor/activity charts
- **Credentials & SSH** — macOS Keychain integration, `SSH_ASKPASS` / `GIT_ASKPASS` helper, and SSH Key generator & connectivity tester
- **Runs in the background** — Like TortoiseGit there is no app to start: Finder launches PangolinGit on demand and it shows a Dock icon only while one of its dialogs is open
- **First-Run Wizard** — Guided setup for Git binary discovery, author identity, and FinderSync extension activation, shown with the first context-menu command
- **`pangolin-wcrev` CLI** — Automated working copy revision and build metadata template substitute tool (`SubWCRev.exe` clone)


## Requirements

- macOS 13 Ventura or later
- Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for building from source)
- Git (installed via Xcode Command Line Tools, Homebrew, or standalone)

## Installing

```bash
tools/make_installer.sh                                     # builds dist/PangolinGit-<version>.pkg
sudo installer -pkg dist/PangolinGit-1.0.0.pkg -target /    # or double-click it
```

The installer puts PangolinGit in `/Applications`, enables the Finder extension and the status agent, and
restarts Finder so the context menu appears.

## Building

See [docs/BUILDING.md](docs/BUILDING.md) for detailed build instructions.

Quick start:
```bash
git clone https://github.com/fredmacbit/pangolingit.git
cd pangolingit
brew install xcodegen
tools/build.sh          # generates PangolinGit.xcodeproj from project.yml, tests, builds
```

## Architecture

| Component | Description |
|-----------|-------------|
| `PangolinGit.app` | Main application with all Git dialogs and tools |
| `PangolinGitFinder.appex` | Sandboxed FinderSync extension for badges, context menus and toolbar button |
| `PangolinGitAgent` | Status-cache launch agent (TGitCache equivalent), reached over an App Group Mach service |
| `pangolin-askpass` | `GIT_ASKPASS` / `SSH_ASKPASS` credential prompt |
| `PangolinGitCore` | Shared Swift Package with the Git abstraction layer |

See [docs/BUILDING.md](docs/BUILDING.md#architecture-at-runtime) for how these fit together at runtime and [doc/IMPLEMENTATION_PLAN.md](doc/IMPLEMENTATION_PLAN.md) for the full architectural plan.

## License

GPLv2 — see [LICENSE](LICENSE) for details.

## Credits

PangolinGit is written by Frederik Vande Rieviere. It is inspired by and based on the architecture of [TortoiseGit](https://tortoisegit.org), the Windows Shell Interface to Git.
