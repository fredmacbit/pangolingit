# PangolinGit — Implementation Plan

## Conversion of TortoiseGit (Windows) to PangolinGit (macOS)

**Version:** 1.0-draft  
**Date:** 2026-10-27  
**Status:** PLANNING  
**License:** GPLv2 (inherited from TortoiseGit)

> **Architecture revision (2026-10-27).** The status cache is no longer an embedded XPC service
> (`PangolinGitXPC.xpc`). Embedded XPC services can only be reached by their containing app, never by
> the Finder extension, and a sandboxed service cannot read working trees. It is now `PangolinGitAgent`,
> a non-sandboxed launch agent registered with `SMAppService` that vends the Mach service
> `group.be.macbit.pangolingit.agent` (the App Group prefix lets the sandboxed extension connect). Git access
> uses the `git` CLI throughout; libgit2/SwiftGit2 and GRDB were not adopted. See `docs/BUILDING.md`.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [Technology Stack](#3-technology-stack)
4. [Component Mapping — TortoiseGit → PangolinGit](#4-component-mapping)
5. [Phase 0 — Project Scaffolding & CI](#phase-0--project-scaffolding--ci)
6. [Phase 1 — Core Git Abstraction Layer](#phase-1--core-git-abstraction-layer)
7. [Phase 2 — Status Cache Daemon](#phase-2--status-cache-daemon)
8. [Phase 3 — Finder Sync Extension (Shell Integration)](#phase-3--finder-sync-extension)
9. [Phase 4 — Main Application & Command Router](#phase-4--main-application--command-router)
10. [Phase 5 — Essential Dialogs (Commit, Log, Push/Pull/Fetch)](#phase-5--essential-dialogs)
11. [Phase 6 — Diff, Merge & Blame Tools](#phase-6--diff-merge--blame-tools)
12. [Phase 7 — Advanced Dialogs (Rebase, Stash, Submodules, Worktrees)](#phase-7--advanced-dialogs)
13. [Phase 8 — Settings, Preferences & First-Run Wizard](#phase-8--settings-preferences--first-run-wizard)
14. [Phase 9 — Credentials, SSH & Keychain Integration](#phase-9--credentials-ssh--keychain)
15. [Phase 10 — Revision Graph & Statistics](#phase-10--revision-graph--statistics)
16. [Phase 11 — Localization, Accessibility & Documentation](#phase-11--localization-accessibility--documentation)
17. [Phase 12 — Installer, Notarization & Distribution](#phase-12--installer-notarization--distribution)
18. [Phase 13 — Testing & QA](#phase-13--testing--qa)
19. [Risk Register](#risk-register)
20. [Appendix A — File-by-File Mapping](#appendix-a--file-by-file-mapping)
21. [Appendix B — Glossary](#appendix-b--glossary)

---

## 1. Executive Summary

**PangolinGit** is a macOS-native Git GUI client that replicates and extends the functionality of [TortoiseGit](https://tortoisegit.org) — the beloved Windows Explorer shell extension for Git version control.

Whereas TortoiseGit is built with C++/MFC and integrates via Windows Shell Extension COM DLLs, PangolinGit will be built with **Swift 5.9+ / AppKit** and integrate via Apple's **FinderSync framework**, providing:

- **Finder overlay badges** (green checkmark, red exclamation, blue clock, etc.)
- **Finder context menus** (Commit, Push, Pull, Log, Diff, Blame, ...)
- **Finder toolbar buttons** for quick Git actions
- A full-featured **standalone macOS application** with all dialogs

The name "Pangolin" is a nod to the armoured, scaled mammal — tough exterior, methodical, and protective — mirroring how the application shields users from the complexity of raw Git commands.

---

## 2. Architecture Overview

```
+------------------------------------------------------------------+
|                     macOS User Space                              |
|                                                                  |
|  +------------------------+    +-------------------------------+ |
|  |  PangolinGit.app       |    |  PangolinGitFinder.appex      | |
|  |  (Main Application)    |    |  (FinderSync Extension)       | |
|  |                        |    |                               | |
|  |  +------------------+  |    |  +-------------------------+  | |
|  |  | Command Router   |  |    |  | FIFinderSync Controller |  | |
|  |  | (Swift enums)    |  |    |  | - Badge images          |  | |
|  |  +--------+---------+  |    |  | - Context menus         |  | |
|  |           |             |    |  | - Toolbar buttons       |  | |
|  |  +--------v---------+  |    |  +------------+------------+  | |
|  |  | Dialog Layer     |  |    |               |               | |
|  |  | (AppKit/         |  |    |  +------------v------------+  | |
|  |  |  SwiftUI)        |  |    |  | XPC Service Client      |  | |
|  |  +--------+---------+  |    |  +------------+------------+  | |
|  |           |             |    |               |               | |
|  +-----------+-------------+    +---------------+---------------+ |
|              |                                  |                 |
|  +-----------v----------------------------------v--------------+  |
|  |                  PangolinGitXPC.xpc                         |  |
|  |            (XPC Status Cache Service)                       |  |
|  |                                                             |  |
|  |  +---------------+  +---------------+  +-----------------+ |  |
|  |  | FSEvents      |  | Git Status    |  | Badge/Status    | |  |
|  |  | Watcher       |  | Calculator    |  | Cache (LRU)     | |  |
|  |  +---------------+  +---------------+  +-----------------+ |  |
|  +-----------------------------+-------------------------------+  |
|                                |                                  |
|  +-----------------------------v-------------------------------+  |
|  |              PangolinGitCore (Swift Package)                |  |
|  |                                                             |  |
|  |  +-----------+ +-------------+ +-----------+ +-----------+ |  |
|  |  | GitOps    | | PathUtils   | | ConfigMgr | | Keychain  | |  |
|  |  | (libgit2) | |             | |           | | Wrapper   | |  |
|  |  +-----------+ +-------------+ +-----------+ +-----------+ |  |
|  +-------------------------------------------------------------+  |
|                                                                   |
|  Shared: App Group Container (~/Library/Group Containers/...)     |
|          +-- config.json                                          |
|          +-- cache.db (SQLite)                                    |
|          +-- logs/                                                |
+-------------------------------------------------------------------+
```

### Key Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| **Swift Package for core logic** (`PangolinGitCore`) | Shared between main app, Finder extension, and XPC service without code duplication |
| **XPC Service for status cache** | Sandboxed Finder extensions cannot run long-lived daemons; XPC provides a privileged, crash-resilient cache process |
| **FinderSync** over Quick Actions | Only FinderSync supports overlay badges and top-level context menus |
| **libgit2 via SwiftGit2** (or custom C bridge) | Avoids shelling out to `git` CLI for status checks; provides in-process performance for cache daemon |
| **`git` CLI for mutations** | Clone, push, pull, rebase — use the real `git` for full compatibility and credential helper support |
| **App Group Container** | Shared preferences and cache DB accessible by both the main app and the sandboxed extension |
| **AppKit-first, SwiftUI for new dialogs** | AppKit for complex controls (outline views, split views, Scintilla-based editors); SwiftUI for simpler preference panes |

---

## 3. Technology Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| Language | Swift 5.9+ | Minimum deployment target: macOS 13 Ventura |
| UI Framework | AppKit + SwiftUI | AppKit for complex windows; SwiftUI for settings |
| Finder Integration | FinderSync.framework | `FIFinderSync` subclass |
| Git (read) | libgit2 via [SwiftGit2](https://github.com/SwiftGit2/SwiftGit2) | Status, log, blame, diff reads |
| Git (write) | `git` CLI via `Process` | Commit, push, pull, rebase, merge |
| IPC | XPC Services (`NSXPCConnection`) | Cache daemon <-> Finder extension |
| Persistence | SQLite (via GRDB.swift) + UserDefaults (suite) | Cache DB + preferences |
| Diff Engine | Native Swift port or Scintilla wrapper | Line-level and character-level diffs |
| Text Editor | [STTextView](https://github.com/nicklockwood/STTextView) or Scintilla (macOS port) | For merge/blame views with syntax highlighting |
| Credential Storage | macOS Keychain (via Security.framework) | SSH keys, HTTPS tokens |
| Graphs | Core Graphics / Core Animation | Revision graph, statistics charts |
| Testing | XCTest + swift-snapshot-testing | Unit, integration, UI snapshot |
| Build | Xcode 15+ / xcodebuild / SPM | CI via GitHub Actions (macOS runners) |
| Distribution | .dmg + Notarization + Sparkle | Auto-update framework |

---

## 4. Component Mapping

### TortoiseGit -> PangolinGit

| TortoiseGit Component | Source Location | PangolinGit Equivalent | Target |
|------------------------|----------------|------------------------|--------|
| `TortoiseGit(32).dll` + `TortoiseGitStub(32).dll` (Shell Extension) | `src/TortoiseShell/` | `PangolinGitFinder.appex` (FinderSync Extension) | Phase 3 |
| `TGitCache.exe` (Background Status Cache) | `src/TGitCache/` | `PangolinGitXPC.xpc` (XPC Service) | Phase 2 |
| `TortoiseGitProc.exe` (Main GUI + Command Router) | `src/TortoiseProc/` | `PangolinGit.app` (Main Application) | Phase 4-8 |
| `TortoiseGitBlame.exe` | `src/TortoiseGitBlame/` | Built-in Blame View (AppKit `NSViewController`) | Phase 6 |
| `TortoiseGitMerge.exe` | `src/TortoiseMerge/` | Built-in Merge/Diff View | Phase 6 |
| `TortoiseGitIDiff.exe` | `src/TortoiseIDiff/` | Built-in Image Diff View | Phase 6 |
| `TortoiseGitUDiff.exe` | `src/TortoiseUDiff/` | Built-in Unified Diff View | Phase 6 |
| `SshAskPass.exe` | `src/SshAskPass/` | macOS Keychain + SSH Agent dialog | Phase 9 |
| `GitWCRev.exe` / `GitWCRevCOM.exe` | `src/GitWCRev/` | `pangolin-wcrev` CLI tool (optional) | Phase 12 |
| `tgittouch.exe` | `src/touch/` | Not needed (no PuTTY on macOS) | N/A |
| `ext/libgit2` | `ext/libgit2/` | SwiftGit2 SPM dependency (wraps libgit2) | Phase 1 |
| `ext/scintilla` + `ext/lexilla` | `ext/scintilla/`, `ext/lexilla/` | STTextView or Scintilla macOS port | Phase 6 |
| `ext/hunspell` + `ext/spell` | `ext/hunspell/`, `ext/spell/` | macOS NSSpellChecker (built-in) | Phase 5 |
| `ext/OGDF` (graph layout) | `ext/OGDF/` | Swift graph layout lib or custom Core Graphics | Phase 10 |
| `ext/putty` | `ext/putty/` | macOS OpenSSH (built-in) | Phase 9 |
| `ext/ResizableLib` | `ext/ResizableLib/` | Auto Layout (native macOS) | N/A |
| `ext/TortoiseOverlays` | `ext/TortoiseOverlays/` | FinderSync badge API | Phase 3 |

---

## Phase 0 — Project Scaffolding & CI

**Goal:** Establish the Xcode workspace, Swift Package, target structure, and CI pipeline.

### Deliverables

| # | Task | Details | Effort |
|---|------|---------|--------|
| 0.1 | Create Xcode workspace `PangolinGit.xcworkspace` | Multi-target workspace | 0.5d |
| 0.2 | Create `PangolinGitCore` Swift Package | `Package.swift` with targets: `PangolinGitCore`, `PangolinGitCoreTests` | 1d |
| 0.3 | Create app target `PangolinGit` | macOS App (AppKit lifecycle), bundle ID `be.macbit.pangolingit` | 0.5d |
| 0.4 | Create FinderSync extension target `PangolinGitFinder` | Extension target, linked to `PangolinGitCore` | 0.5d |
| 0.5 | Create XPC Service target `PangolinGitXPC` | XPC Service, linked to `PangolinGitCore` | 0.5d |
| 0.6 | Configure App Group | `group.be.macbit.pangolingit` shared container | 0.5d |
| 0.7 | Configure signing & entitlements | Development team, sandbox entitlements, hardened runtime | 0.5d |
| 0.8 | Pipeline script `pipeline.bat` | Three-phase: test -> build -> A/B functional tests | 0.5d |
| 0.9 | Phase scripts | `tools/phase1_test.bat`, `tools/phase2_build.bat`, `tools/phase3_ab_test.bat` | 0.5d |
| 0.10 | GitHub Actions CI | macOS runner, xcodebuild, test + archive + notarize | 1d |
| 0.11 | Project documentation | `README.md`, `docs/BUILDING.md` | 0.5d |
| 0.12 | Report generation | HTML + text reports in `reports/` for each phase | 0.5d |

**Directory Structure:**

```
PangolinGit/
+-- PangolinGit.xcworkspace
+-- PangolinGit/                          # Main app target
|   +-- AppDelegate.swift
|   +-- MainMenu.xib
|   +-- Commands/                         # Command router + handlers
|   +-- Dialogs/                          # All dialog ViewControllers
|   |   +-- Commit/
|   |   +-- Log/
|   |   +-- Push/
|   |   +-- Pull/
|   |   +-- Merge/
|   |   +-- Rebase/
|   |   +-- Branch/
|   |   +-- Settings/
|   |   +-- ...
|   +-- Views/                            # Reusable views
|   +-- Assets.xcassets
|   +-- Info.plist
|   +-- PangolinGit.entitlements
+-- PangolinGitFinder/                    # FinderSync extension
|   +-- FinderSync.swift
|   +-- Info.plist
|   +-- PangolinGitFinder.entitlements
+-- PangolinGitXPC/                       # XPC cache service
|   +-- XPCService.swift
|   +-- StatusCache.swift
|   +-- FSEventsWatcher.swift
|   +-- Info.plist
|   +-- PangolinGitXPC.entitlements
+-- PangolinGitCore/                      # Swift Package (shared)
|   +-- Package.swift
|   +-- Sources/
|   |   +-- PangolinGitCore/
|   |       +-- Git/                      # Git abstraction (libgit2 + CLI)
|   |       +-- Models/                   # Data models (GitRev, GitStatus, etc.)
|   |       +-- Path/                     # Path utilities
|   |       +-- Config/                   # Configuration manager
|   |       +-- Keychain/                 # Keychain wrapper
|   |       +-- XPC/                      # XPC protocol definitions
|   |       +-- Logging/                  # Unified logging (os_log)
|   +-- Tests/
|       +-- PangolinGitCoreTests/
+-- doc/
|   +-- ideas.txt
|   +-- IMPLEMENTATION_PLAN.md            # This document
+-- docs/
|   +-- BUILDING.md
+-- tools/
|   +-- phase1_test.bat
|   +-- phase2_build.bat
|   +-- phase3_ab_test.bat
+-- reports/                              # Generated test/build reports
+-- pipeline.bat
+-- README.md
```

---

## Phase 1 — Core Git Abstraction Layer

**Goal:** Build `PangolinGitCore` — the shared Swift Package that wraps libgit2 (via SwiftGit2) and provides a clean async Swift API for all Git operations.

**Maps to:** `src/Git/` (Git.cpp, Git.h, GitStatus.cpp, GitRev.cpp, TGitPath.cpp, etc.)

### Deliverables

| # | Task | TortoiseGit Source | PangolinGit Target | Effort |
|---|------|-------------------|-------------------|--------|
| 1.1 | `GitRepository` class | `Git.cpp` / `Git.h` (128KB) | `PangolinGitCore/Git/GitRepository.swift` | 3d |
| 1.2 | `GitStatus` model + enums | `GitStatus.cpp` / `gittype.h` | `PangolinGitCore/Models/GitStatus.swift` | 2d |
| 1.3 | `GitRevision` model | `GitRev.cpp` / `GitRevLoglist.cpp` | `PangolinGitCore/Models/GitRevision.swift` | 2d |
| 1.4 | `GitHash` value type | `GitHash.h` | `PangolinGitCore/Models/GitHash.swift` | 0.5d |
| 1.5 | `PangolinPath` (path utilities) | `TGitPath.cpp` / `TGitPath.h` (52KB + 16KB) | `PangolinGitCore/Path/PangolinPath.swift` | 2d |
| 1.6 | `GitIndex` reader | `GitIndex.cpp` / `gitindex.h` | `PangolinGitCore/Git/GitIndex.swift` | 2d |
| 1.7 | `GitAdminDir` (`.git` locator) | `GitAdminDir.cpp` | `PangolinGitCore/Git/GitAdminDir.swift` | 1d |
| 1.8 | `GitCLIRunner` (Process wrapper) | `AppUtils.cpp` (git.exe invocations) | `PangolinGitCore/Git/GitCLIRunner.swift` | 2d |
| 1.9 | `GitMailmap` | `GitMailmap.cpp` | `PangolinGitCore/Git/GitMailmap.swift` | 0.5d |
| 1.10 | `GitPatch` parser | `GitPatch.cpp` | `PangolinGitCore/Git/GitPatch.swift` | 1d |
| 1.11 | `GitFolderStatus` (per-directory) | `GitFolderStatus.cpp` | `PangolinGitCore/Git/GitFolderStatus.swift` | 1d |
| 1.12 | Unit tests | `test/UnitTests/` reference | `PangolinGitCoreTests/` | 3d |

### Key Design Notes

- **SwiftGit2** wraps libgit2 in Swift. Use it for read operations (status, log, blame, diff) where performance matters.
- **`GitCLIRunner`** shells out to `/usr/bin/git` (or user-configured path) for write operations (commit, push, pull, rebase, merge). This mirrors TortoiseGit's approach of calling `git.exe` for mutations.
- **All APIs are `async`/`await`** — status calculations run on detached tasks, results delivered via `AsyncStream` or completion handlers.
- **Error handling:** Define `PangolinGitError` enum mapping libgit2 error codes + CLI stderr parsing (cf. `GitCliOutputParser.cpp`).

---

## Phase 2 — Status Cache Daemon

**Goal:** Build `PangolinGitXPC` — the XPC Service that continuously monitors Git working trees and maintains an in-memory + SQLite status cache.

**Maps to:** `src/TGitCache/` (TGITCache.cpp, CachedDirectory.cpp, DirectoryWatcher.cpp, FolderCrawler.cpp, GITStatusCache.cpp, StatusCacheEntry.cpp, ShellUpdater.cpp)

### Deliverables

| # | Task | TortoiseGit Source | PangolinGit Target | Effort |
|---|------|-------------------|-------------------|--------|
| 2.1 | XPC protocol definition | `CacheInterface.h` | `PangolinGitCore/XPC/StatusCacheProtocol.swift` | 1d |
| 2.2 | `FSEventsWatcher` | `DirectoryWatcher.cpp` (21KB) | `PangolinGitXPC/FSEventsWatcher.swift` | 2d |
| 2.3 | `FolderCrawler` | `FolderCrawler.cpp` (17KB) | `PangolinGitXPC/FolderCrawler.swift` | 2d |
| 2.4 | `CachedDirectory` | `CachedDirectory.cpp` (27KB) | `PangolinGitXPC/CachedDirectory.swift` | 2d |
| 2.5 | `StatusCache` (LRU + SQLite) | `GITStatusCache.cpp` (19KB) | `PangolinGitXPC/StatusCache.swift` | 3d |
| 2.6 | `StatusCacheEntry` | `StatusCacheEntry.cpp` | `PangolinGitXPC/StatusCacheEntry.swift` | 1d |
| 2.7 | `XPCServiceDelegate` (entry point) | `TGITCache.cpp` (30KB) | `PangolinGitXPC/XPCService.swift` | 2d |
| 2.8 | Integration tests | — | `PangolinGitXPC/Tests/` | 2d |

### Key Design Notes

- **FSEvents** replaces Windows `ReadDirectoryChangesW`. Use `DispatchSource.makeFileSystemObjectSource` or the C-level FSEvents API for recursive directory monitoring.
- **XPC Protocol** (`StatusCacheProtocol`):
  ```swift
  @objc protocol StatusCacheProtocol {
      func status(for path: String, reply: @escaping (PGFileStatus) -> Void)
      func statusBatch(for paths: [String], reply: @escaping ([String: PGFileStatus]) -> Void)
      func registerMonitoredDirectory(_ path: String)
      func unregisterMonitoredDirectory(_ path: String)
      func invalidateCache(for path: String)
  }
  ```
- **Throttling:** Debounce FSEvents notifications (100ms window) before recalculating status — mirrors TGitCache's coalescing logic.
- **Memory Pressure:** Respond to `DispatchSource.makeMemoryPressureSource` by trimming the LRU cache.

---

## Phase 3 — Finder Sync Extension

**Goal:** Build `PangolinGitFinder.appex` — the FinderSync extension that shows overlay badges on files/folders and provides context menus.

**Maps to:** `src/TortoiseShell/` (ContextMenu.cpp, IconOverlay.cpp, ShellExt.cpp, MenuInfo.cpp, ShellCache.cpp, RemoteCacheLink.cpp)

### Deliverables

| # | Task | TortoiseGit Source | PangolinGit Target | Effort |
|---|------|-------------------|-------------------|--------|
| 3.1 | `FinderSync` subclass | `ShellExt.cpp`, `IconOverlay.cpp` | `PangolinGitFinder/FinderSync.swift` | 2d |
| 3.2 | Badge image set (7 states) | `ext/TortoiseOverlays/` (icon resources) | `PangolinGitFinder/Assets.xcassets` | 1d |
| 3.3 | Badge assignment logic | `IconOverlay.cpp` (11KB), `ShellCache.cpp` | `FinderSync.swift` -> `requestBadgeIdentifier(for:)` | 2d |
| 3.4 | Context menu generation | `ContextMenu.cpp` (91KB!), `MenuInfo.cpp` (18KB) | `FinderSync.swift` -> `menu(for:)` | 3d |
| 3.5 | XPC client connection | `RemoteCacheLink.cpp` | `PangolinGitFinder/XPCClient.swift` | 1d |
| 3.6 | Launch main app with command | (Shell Extension -> TortoiseGitProc.exe launch) | `NSWorkspace.shared.open(url:)` with URL scheme | 1d |
| 3.7 | Toolbar button | (not in TortoiseGit) | `FinderSync.swift` -> `toolbarItemName` / `toolbarItemImage` | 0.5d |

### Badge Mapping

| File Status | Badge ID | Icon | Color |
|------------|----------|------|-------|
| Clean / Unmodified | `normal` | Checkmark | Green |
| Modified | `modified` | Exclamation | Orange |
| Added / Staged | `added` | Plus | Blue |
| Deleted | `deleted` | Cross | Red |
| Conflicted | `conflict` | Warning | Yellow |
| Untracked | `unversioned` | Question | Grey |
| Ignored | `ignored` | Dash | Light grey |

### Context Menu Structure

```
+-----------------------------------+
| Git Commit...                     |
| Git Push...                       |
| Git Pull...                       |
| Git Fetch...                      |
| ---------------------------------|
| Git Sync...                       |
| ---------------------------------|
| Git Diff                          |
| Git Log                           |
| Git Blame                         |
| ---------------------------------|
| Git > (submenu)                   |
|   +-- Create Branch/Tag...        |
|   +-- Switch/Checkout...          |
|   +-- Merge...                    |
|   +-- Rebase...                   |
|   +-- Stash >                     |
|   |   +-- Stash Save...           |
|   |   +-- Stash Pop               |
|   |   +-- Stash List...           |
|   +-- ----------------------------|
|   +-- Add...                      |
|   +-- Revert...                   |
|   +-- Resolve...                  |
|   +-- Rename...                   |
|   +-- Delete...                   |
|   +-- Ignore >                    |
|   +-- ----------------------------|
|   +-- Export...                    |
|   +-- Clone...                    |
|   +-- Create Repository Here      |
|   +-- ----------------------------|
|   +-- Bisect >                    |
|   +-- Submodules >                |
|   +-- Worktrees >                 |
|   +-- ----------------------------|
|   +-- Browse Refs...              |
|   +-- Repo Browser...             |
|   +-- RefLog...                   |
|   +-- ----------------------------|
|   +-- Settings...                 |
|   +-- About PangolinGit           |
+-----------------------------------+
```

### Key Design Notes

- **URL Scheme**: Register `pangolin-git://` URL scheme. The Finder extension launches the main app via:
  ```swift
  NSWorkspace.shared.open(URL(string: "pangolin-git://command/commit?path=\(encodedPath)")!)
  ```
  This mirrors how TortoiseGit's shell DLL launches `TortoiseGitProc.exe` with command-line parameters.
- **Menu visibility logic**: Replicate TortoiseGit's `MenuInfo.cpp` logic — show/hide items based on whether the target is inside a Git working tree, is a file vs. directory, its current status, etc.

---

## Phase 4 — Main Application & Command Router

**Goal:** Build the main `PangolinGit.app` with URL scheme handling and command dispatch — equivalent to `TortoiseGitProc.exe`.

**Maps to:** `src/TortoiseProc/TortoiseProc.cpp`, `src/TortoiseProc/Commands/Command.h`, `src/TortoiseProc/Commands/Command.cpp`

### Deliverables

| # | Task | TortoiseGit Source | PangolinGit Target | Effort |
|---|------|-------------------|-------------------|--------|
| 4.1 | `AppDelegate` + URL scheme handler | `TortoiseProc.cpp` (24KB) | `PangolinGit/AppDelegate.swift` | 1d |
| 4.2 | `PangolinCommand` protocol | `Command.h` / `Command.cpp` | `PangolinGit/Commands/PangolinCommand.swift` | 1d |
| 4.3 | `CommandRouter` (factory) | `Command.cpp` -> `CommandServer::CreateRawCommand` | `PangolinGit/Commands/CommandRouter.swift` | 1d |
| 4.4 | `PathRequirement` enum | `Command.h` enum | `PangolinGitCore/Models/PathRequirement.swift` | 0.5d |
| 4.5 | About dialog | `AboutCommand.cpp`, `AboutDlg.cpp` | `PangolinGit/Dialogs/About/AboutViewController.swift` | 1d |
| 4.6 | Main menu bar | — | `MainMenu.xib` or programmatic NSMenu | 1d |

### Command Protocol

```swift
protocol PangolinCommand {
    /// Minimum path requirement for this command
    var pathRequirement: PathRequirement { get }
    
    /// Whether this command needs a git executable
    var requiresGitExe: Bool { get }
    
    /// Execute the command
    func execute(paths: [PangolinPath], options: CommandOptions) async throws -> Bool
}
```

### URL Scheme Format

```
pangolin-git://command/<action>?path=<encoded_path>&rev=<revision>&...
```

Examples:
- `pangolin-git://command/commit?path=/Users/me/project`
- `pangolin-git://command/log?path=/Users/me/project/file.swift&startrev=HEAD`
- `pangolin-git://command/diff?path=/Users/me/project/file.swift&rev1=HEAD~1&rev2=HEAD`

---

## Phase 5 — Essential Dialogs

**Goal:** Implement the most frequently used dialogs: Commit, Log, Push, Pull/Fetch, Sync, Clone, Changed Files, and Branch/Tag.

**Maps to:** The large dialog classes in `src/TortoiseProc/`

### Deliverables

| # | Dialog | TortoiseGit Source | Size | PangolinGit Target | Effort |
|---|--------|-------------------|------|-------------------|--------|
| 5.1 | **Commit Dialog** | `CommitDlg.cpp/.h` | 108KB | `Dialogs/Commit/CommitViewController.swift` | 5d |
| 5.2 | **Log Dialog** | `LogDlg.cpp/.h` + `GitLogListBase.cpp` | 120KB + 137KB | `Dialogs/Log/LogViewController.swift` | 7d |
| 5.3 | **Push Dialog** | `PushDlg.cpp/.h` | 22KB | `Dialogs/Push/PushViewController.swift` | 2d |
| 5.4 | **Pull/Fetch Dialog** | `PullFetchDlg.cpp/.h` | 17KB | `Dialogs/Pull/PullFetchViewController.swift` | 2d |
| 5.5 | **Sync Dialog** | `SyncDlg.cpp/.h` | 61KB | `Dialogs/Sync/SyncViewController.swift` | 4d |
| 5.6 | **Clone Dialog** | `CloneDlg.cpp/.h` + `CloneCommand.cpp` | 17KB + 8KB | `Dialogs/Clone/CloneViewController.swift` | 2d |
| 5.7 | **Changed Files** | `ChangedDlg.cpp/.h` | 15KB | `Dialogs/Changed/ChangedViewController.swift` | 2d |
| 5.8 | **Create Branch/Tag** | `CreateBranchTagDlg.cpp` | 9KB | `Dialogs/Branch/CreateBranchTagViewController.swift` | 1d |
| 5.9 | **Switch/Checkout** | `GitSwitchDlg.cpp` | 8KB | `Dialogs/Switch/SwitchViewController.swift` | 1d |
| 5.10 | **Browse Refs** | `BrowseRefsDlg.cpp` | 56KB | `Dialogs/BrowseRefs/BrowseRefsViewController.swift` | 3d |
| 5.11 | **Git Status List** (reusable) | `GitStatusListCtrl.cpp` (169KB!) | — | `Views/StatusListView.swift` | 5d |
| 5.12 | **Progress Dialog** | `ProgressDlg.cpp`, `GitProgressDlg.cpp`, `GitProgressList.cpp` | 29KB+11KB+34KB | `Dialogs/Progress/ProgressViewController.swift` | 3d |
| 5.13 | **File Diff list** | `FileDiffDlg.cpp` | 51KB | `Dialogs/FileDiff/FileDiffViewController.swift` | 3d |

### Key Design Notes

- **`StatusListView`** is the single most critical reusable component — it's used in Commit, Log, Changed Files, Resolve, Revert, and many other dialogs. On TortoiseGit this is `GitStatusListCtrl` at 169KB of C++. Build it as an `NSOutlineView`-based component with:
  - Column sorting
  - Multi-selection
  - Context menu (stage, unstage, diff, revert, ignore, etc.)
  - Status icons
  - Filter bar
  - Grouping (by status, by directory)
- **Log Dialog** is the largest and most complex dialog. Implement using a split view:
  - Top: `NSTableView` with commit list (hash, author, date, message, graph lanes)
  - Bottom-left: `StatusListView` showing files changed in selected commit
  - Bottom-right: Commit message detail + author info + Gravatar
- **Commit message editor**: Use `NSTextView` with spell checking (leverages macOS `NSSpellChecker` — no need for the hunspell port).
- **Graph lanes**: Port `lanes.cpp` logic to Swift for drawing commit graph lanes in the Log dialog.

---

## Phase 6 — Diff, Merge & Blame Tools

**Goal:** Build integrated diff, merge, blame, and image-diff viewers — replacing TortoiseGitMerge, TortoiseGitBlame, TortoiseGitIDiff, and TortoiseGitUDiff.

**Maps to:** `src/TortoiseMerge/`, `src/TortoiseGitBlame/`, `src/TortoiseIDiff/`, `src/TortoiseUDiff/`

### Deliverables

| # | Tool | TortoiseGit Source | PangolinGit Target | Effort |
|---|------|-------------------|-------------------|--------|
| 6.1 | **Two-way diff view** | `BaseView.cpp` (189KB!), `LeftView.cpp`, `RightView.cpp` | `Views/DiffView/TwoWayDiffViewController.swift` | 5d |
| 6.2 | **Three-way merge view** | `BottomView.cpp`, `MainFrm.cpp` (132KB) | `Views/DiffView/ThreeWayMergeViewController.swift` | 5d |
| 6.3 | **Diff data engine** | `DiffData.cpp` (39KB), `MovedBlocks.cpp` | `PangolinGitCore/Diff/DiffEngine.swift` | 3d |
| 6.4 | **Diff colors & themes** | `DiffColors.cpp` (19KB) | `Views/DiffView/DiffColorScheme.swift` | 1d |
| 6.5 | **Inline diff (unified)** | `TortoiseUDiff` sources | `Views/DiffView/UnifiedDiffViewController.swift` | 2d |
| 6.6 | **Blame view** | `TortoiseGitBlameView.cpp` (87KB), `TortoiseGitBlameData.cpp` | `Views/Blame/BlameViewController.swift` | 4d |
| 6.7 | **Image diff view** | `TortoiseIDiff` sources | `Views/ImageDiff/ImageDiffViewController.swift` | 2d |
| 6.8 | **Patch file viewer** | `Patch.cpp`, `FilePatchesDlg.cpp` | `Views/Patch/PatchViewController.swift` | 2d |
| 6.9 | **Syntax highlighting** | Scintilla integration | STTextView or NSTextView with `NSAttributedString` | 3d |

### Key Design Notes

- **Diff Engine**: Consider using Swift's built-in `CollectionDifference` for simple cases, but implement Myers' diff algorithm (like libsvn_diff used in TortoiseMerge) for production-grade line and character-level diffs.
- **Side-by-side view**: Use two synchronized `NSScrollView`s with linked scroll positions (replicate TortoiseMerge's `XSplitter` concept with `NSSplitView`).
- **Blame view**: Scintilla-based in TortoiseGit; on macOS, use a custom `NSTableView` with line-number gutters and color-coded author columns.

---

## Phase 7 — Advanced Dialogs

**Goal:** Implement advanced Git operation dialogs.

### Deliverables

| # | Dialog | TortoiseGit Source | PangolinGit Target | Effort |
|---|--------|-------------------|------|--------|
| 7.1 | **Rebase Dialog** | `RebaseDlg.cpp` (104KB!) | `Dialogs/Rebase/RebaseViewController.swift` | 5d |
| 7.2 | **Merge Dialog** | `MergeDlg.cpp` | `Dialogs/Merge/MergeViewController.swift` | 2d |
| 7.3 | **Stash Save/Pop** | `StashSave.cpp`, `StashCommand.cpp` | `Dialogs/Stash/StashViewController.swift` | 1d |
| 7.4 | **Resolve Conflicts** | `ResolveDlg.cpp` | `Dialogs/Resolve/ResolveViewController.swift` | 2d |
| 7.5 | **Revert Dialog** | `RevertDlg.cpp` | `Dialogs/Revert/RevertViewController.swift` | 1d |
| 7.6 | **Add Dialog** | `AddDlg.cpp` | `Dialogs/Add/AddViewController.swift` | 1d |
| 7.7 | **Rename Dialog** | `RenameDlg.cpp` | `Dialogs/Rename/RenameViewController.swift` | 0.5d |
| 7.8 | **Delete / Remove** | `RemoveCommand.cpp` | `Commands/RemoveCommand.swift` | 0.5d |
| 7.9 | **Ignore Dialog** | `IgnoreDlg.cpp`, `IgnoreCommand.cpp` | `Dialogs/Ignore/IgnoreViewController.swift` | 1d |
| 7.10 | **Reset Dialog** | `ResetDlg.cpp` | `Dialogs/Reset/ResetViewController.swift` | 1d |
| 7.11 | **Export Dialog** | `ExportDlg.cpp` | `Dialogs/Export/ExportViewController.swift` | 1d |
| 7.12 | **Submodule Dialogs** | `SubmoduleAddDlg.cpp`, `SubmoduleUpdateDlg.cpp`, etc. | `Dialogs/Submodule/` | 2d |
| 7.13 | **Worktree Dialogs** | `WorktreeListDlg.cpp`, `CreateWorktreeDlg.cpp` | `Dialogs/Worktree/` | 2d |
| 7.14 | **Import Patch** | `ImportPatchDlg.cpp` | `Dialogs/Patch/ImportPatchViewController.swift` | 1d |
| 7.15 | **Format Patch** | `FormatPatchDlg.cpp` | `Dialogs/Patch/FormatPatchViewController.swift` | 1d |
| 7.16 | **Bisect** | `BisectStartDlg.cpp`, `BisectCommand.cpp` | `Dialogs/Bisect/BisectViewController.swift` | 1d |
| 7.17 | **RefLog** | `RefLogDlg.cpp` | `Dialogs/RefLog/RefLogViewController.swift` | 1d |
| 7.18 | **Request Pull** | `RequestPullDlg.cpp` | `Dialogs/RequestPull/RequestPullViewController.swift` | 1d |
| 7.19 | **LFS Locks** | `LFSLocksDlg.cpp` | `Dialogs/LFS/LFSLocksViewController.swift` | 1d |
| 7.20 | **Repository Browser** | `RepositoryBrowser.cpp` (47KB) | `Dialogs/RepoBrowser/RepoBrowserViewController.swift` | 3d |
| 7.21 | **SVN Integration** | `SVNDCommitDlg`, `SVNFetchCommand`, etc. | Deferred — low priority for v1.0 | — |

---

## Phase 8 — Settings, Preferences & First-Run Wizard

**Goal:** Implement the macOS Preferences window and first-run wizard.

**Maps to:** `src/TortoiseProc/Settings/` (67 files), `src/TortoiseProc/FirstStartWizard*.cpp`

### Deliverables

| # | Task | TortoiseGit Source | PangolinGit Target | Effort |
|---|------|-------------------|-------------------|--------|
| 8.1 | **Preferences Window** (tab-based) | `Settings.cpp/.h` | `Dialogs/Settings/SettingsWindowController.swift` | 1d |
| 8.2 | **General Settings** | `SetMainPage.cpp` | `Dialogs/Settings/GeneralSettingsView.swift` (SwiftUI) | 1d |
| 8.3 | **Git Config (user.name, email)** | `SettingGitConfig.cpp` | `Dialogs/Settings/GitConfigView.swift` | 1d |
| 8.4 | **Git Remotes** | `SettingGitRemote.cpp` | `Dialogs/Settings/GitRemoteView.swift` | 1d |
| 8.5 | **Git Credentials** | `SettingGitCredential.cpp` | `Dialogs/Settings/GitCredentialView.swift` | 2d |
| 8.6 | **Overlay Icons settings** | `SetOverlayPage.cpp`, `SetOverlayIcons.cpp` | `Dialogs/Settings/OverlaySettingsView.swift` | 1d |
| 8.7 | **Context Menu settings** | `SetLookAndFeelPage.cpp` | `Dialogs/Settings/ContextMenuSettingsView.swift` | 1d |
| 8.8 | **Dialog settings** | `SetDialogs.cpp`, `SetDialogs2.cpp`, `SetDialogs3.cpp` | `Dialogs/Settings/DialogSettingsView.swift` | 1d |
| 8.9 | **Colors settings** | `SettingsColors.cpp`, `SettingsColors2.cpp`, `SettingsColors3.cpp` | `Dialogs/Settings/ColorsSettingsView.swift` | 1d |
| 8.10 | **External Tools** (diff/merge) | `SettingsProgsDiff.cpp`, `SettingsProgsMerge.cpp` | `Dialogs/Settings/ExternalToolsView.swift` | 1d |
| 8.11 | **Network/Proxy** | `SetProxyPage.cpp` | `Dialogs/Settings/ProxySettingsView.swift` | 1d |
| 8.12 | **Hooks** | `SetHooks.cpp`, `SetHooksAdv.cpp` | `Dialogs/Settings/HooksSettingsView.swift` | 1d |
| 8.13 | **Advanced settings** | `SettingsAdvanced.cpp` | `Dialogs/Settings/AdvancedSettingsView.swift` | 1d |
| 8.14 | **Saved Data** | `SetSavedDataPage.cpp` | `Dialogs/Settings/SavedDataView.swift` | 1d |
| 8.15 | **First-Run Wizard** | `FirstStartWizard*.cpp` (7 files) | `Dialogs/FirstRun/FirstRunWizard.swift` | 2d |
| 8.16 | **Blame settings** | `SettingsTBlame.cpp` | `Dialogs/Settings/BlameSettingsView.swift` | 0.5d |

### Key Design Notes

- Use **SwiftUI** for preferences panes (embedded in `NSHostingView` within `NSTabViewController`) — clean, declarative, modern.
- Settings stored in `UserDefaults(suiteName: "group.be.macbit.pangolingit")` for sharing between app, extension, and XPC.
- The First-Run Wizard should detect `git` installation, configure `user.name`/`user.email`, and optionally set up SSH keys.

---

## Phase 9 — Credentials, SSH & Keychain Integration

**Goal:** Handle Git authentication seamlessly on macOS.

**Maps to:** `src/SshAskPass/`, `src/Utils/WindowsCredentialsStore.cpp`, `src/TortoiseProc/UserPassword.cpp`, credential helpers

### Deliverables

| # | Task | PangolinGit Target | Effort |
|---|------|--------------------|--------|
| 9.1 | macOS Keychain credential helper | `PangolinGitCore/Keychain/KeychainHelper.swift` | 2d |
| 9.2 | SSH key management dialog | `Dialogs/SSH/SSHKeyViewController.swift` | 2d |
| 9.3 | SSH passphrase prompt (replaces SshAskPass) | `Dialogs/SSH/SSHPassphraseAlert.swift` | 1d |
| 9.4 | HTTPS credential prompt | `Dialogs/Credentials/CredentialPrompt.swift` | 1d |
| 9.5 | `GIT_ASKPASS` / `SSH_ASKPASS` integration | `PangolinGitCore/Git/AskPassHelper.swift` | 1d |
| 9.6 | Git credential.helper configuration | Settings integration | 1d |

### Key Design Notes

- macOS uses `ssh-agent` natively; no PuTTY/Pageant needed.
- `SshAskPass.exe` is replaced by a simple `NSAlert` with a secure text field, called via a helper binary that PangolinGit registers as `SSH_ASKPASS`.
- For HTTPS, leverage `git-credential-osxkeychain` (ships with macOS Git) or provide a custom credential helper that talks to PangolinGit's Keychain wrapper.

---

## Phase 10 — Revision Graph & Statistics

**Goal:** Implement the visual revision graph and commit statistics.

**Maps to:** `src/TortoiseProc/RevisionGraph/`, `src/TortoiseProc/StatGraphDlg.cpp` (58KB), `ext/OGDF/`

### Deliverables

| # | Task | PangolinGit Target | Effort |
|---|------|--------------------|--------|
| 10.1 | Graph layout engine | `PangolinGitCore/Graph/GraphLayout.swift` | 3d |
| 10.2 | Revision Graph view | `Views/RevisionGraph/RevisionGraphView.swift` (Core Graphics) | 4d |
| 10.3 | Statistics charts | `Dialogs/Statistics/StatisticsViewController.swift` | 3d |
| 10.4 | Commit-by-author chart | Core Graphics / SwiftUI Charts | 1d |
| 10.5 | Commit-by-date chart | Core Graphics / SwiftUI Charts | 1d |

### Key Design Notes

- TortoiseGit uses the OGDF (Open Graph Drawing Framework) C++ library for graph layout. On macOS, evaluate:
  1. Port minimal OGDF Sugiyama layout to Swift
  2. Use a Swift graph layout library
  3. Custom simple layered layout (sufficient for most repos)
- Use `NSScrollView` + custom `NSView` with `draw(_:)` for the graph canvas (Core Graphics paths + Core Animation for smooth scrolling).
- SwiftUI Charts framework (macOS 13+) can handle statistics bar/line/pie charts natively.

---

## Phase 11 — Localization, Accessibility & Documentation

**Goal:** Make PangolinGit world-ready and accessible.

### Deliverables

| # | Task | Effort |
|---|------|--------|
| 11.1 | Extract all user-facing strings to `.strings` / String Catalogs | 3d |
| 11.2 | Add VoiceOver accessibility labels to all controls | 2d |
| 11.3 | Right-to-left layout support | 1d |
| 11.4 | User documentation (Help Book) | 5d |
| 11.5 | Initial translations (EN, DE, FR, NL, JA, ZH) | 3d per language |
| 11.6 | Dark Mode / accent color support | 2d |

### Key Design Notes

- TortoiseGit has 50+ language packs in `Languages/`. Start with English and the 5 most-used languages.
- Use Xcode String Catalogs (`.xcstrings`) for modern localization workflow.
- Leverage AppKit's built-in Dark Mode support — all `NSColor.textColor`-style semantic colors adapt automatically.

---

## Phase 12 — Installer, Notarization & Distribution

**Goal:** Package, sign, notarize, and distribute PangolinGit.

### Deliverables

| # | Task | Effort |
|---|------|--------|
| 12.1 | Create `.dmg` installer (background image, drag-to-Applications) | 1d |
| 12.2 | Code signing (Developer ID Application + Developer ID Installer) | 1d |
| 12.3 | Apple Notarization integration | 1d |
| 12.4 | Sparkle auto-update integration | 2d |
| 12.5 | Homebrew Cask formula | 0.5d |
| 12.6 | `pangolin-wcrev` CLI tool (optional) | 2d |
| 12.7 | System Settings -> Extensions registration prompt | 0.5d |
| 12.8 | Archive build script | 1d |

### Key Design Notes

- The FinderSync extension must be **enabled** by the user in System Settings -> Extensions -> Finder Extensions. PangolinGit should detect when the extension is disabled and prompt the user.
- Use `create-dmg` or a custom script for DMG creation with a branded background.
- Sparkle (https://sparkle-project.org/) is the de-facto macOS auto-update framework.

---

## Phase 13 — Testing & QA

**Goal:** Comprehensive test coverage across all layers.

### Test Strategy

| Layer | Framework | Scope |
|-------|----------|-------|
| Core logic | XCTest | `PangolinGitCore` — Git ops, path utils, config, models |
| XPC Service | XCTest + temp Git repos | Cache invalidation, FSEvents response, XPC protocol |
| Finder Extension | Manual + Accessibility Inspector | Badge display, context menu, toolbar |
| Dialogs | XCTest UI + swift-snapshot-testing | All dialogs — screenshot snapshots for regression |
| Integration | XCTest + real Git repos | End-to-end: commit -> push -> log -> diff |
| Performance | XCTest `measure {}` | Cache lookup latency, log loading speed, diff engine |

### Deliverables

| # | Task | Effort |
|---|------|--------|
| 13.1 | Unit tests for `PangolinGitCore` (target: 80% coverage) | 5d |
| 13.2 | Integration tests with fixture Git repos | 3d |
| 13.3 | UI snapshot tests for all dialogs | 3d |
| 13.4 | Performance benchmarks | 2d |
| 13.5 | Manual QA test plan document | 1d |
| 13.6 | Pipeline test scripts with HTML/text reports | 1d |

---

## Risk Register

| # | Risk | Impact | Probability | Mitigation |
|---|------|--------|-------------|------------|
| R1 | FinderSync API limitations (menu nesting, badge refresh frequency) | High | Medium | Prototype early in Phase 3; fallback to Services menu for complex actions |
| R2 | SwiftGit2 does not wrap needed libgit2 features | Medium | Medium | Write custom Swift-to-C bindings for missing features; contribute upstream |
| R3 | XPC Service killed by macOS for resource usage | Medium | Low | Implement graceful reconnection in Finder extension; keep memory footprint low |
| R4 | Apple sandbox restrictions block Git operations | High | Medium | Use temporary exceptions where needed; document required entitlements |
| R5 | Scintilla macOS port instability | Medium | Medium | Fall back to STTextView or native NSTextView with attributed strings |
| R6 | libgit2 thread safety issues in XPC context | Medium | Low | Use serial dispatch queues for all libgit2 calls; document threading model |
| R7 | Notarization rejects hardened runtime + unsigned git binary | Medium | Low | Use system-installed git; bundle signed git if needed |
| R8 | Large repos (100K+ files) cause cache performance issues | High | Medium | Implement lazy loading, pagination, and background indexing |

---

## Appendix A — File-by-File Mapping

### TortoiseShell -> PangolinGitFinder

| TortoiseGit File | Size | PangolinGit Equivalent |
|-----------------|------|----------------------|
| `ContextMenu.cpp` | 91KB | `FinderSync.swift` -> `menu(for:)` |
| `IconOverlay.cpp` | 12KB | `FinderSync.swift` -> `requestBadgeIdentifier(for:)` |
| `ShellExt.cpp` / `ShellExt.h` | 6KB+10KB | `FinderSync.swift` (entry point) |
| `MenuInfo.cpp` / `MenuInfo.h` | 18KB+3KB | `ContextMenuBuilder.swift` |
| `ShellCache.cpp` / `ShellCache.h` | 24KB+8KB | `XPCClient.swift` (delegates to cache service) |
| `RemoteCacheLink.cpp` | 10KB | `XPCClient.swift` |
| `GITPropertyPage.cpp` | 26KB | Future: Quick Look plugin or Finder Info panel |
| `ExplorerCommand.cpp` | 7KB | Not needed (no Windows 11 shell registration) |

### TGitCache -> PangolinGitXPC

| TortoiseGit File | Size | PangolinGit Equivalent |
|-----------------|------|----------------------|
| `TGITCache.cpp` | 30KB | `XPCService.swift` |
| `CachedDirectory.cpp` | 28KB | `CachedDirectory.swift` |
| `DirectoryWatcher.cpp` | 22KB | `FSEventsWatcher.swift` |
| `FolderCrawler.cpp` | 17KB | `FolderCrawler.swift` |
| `GITStatusCache.cpp` | 19KB | `StatusCache.swift` |
| `StatusCacheEntry.cpp` | 5KB | `StatusCacheEntry.swift` |
| `ShellUpdater.cpp` | 5KB | `FinderSyncNotifier.swift` (via NSDistributedNotificationCenter) |
| `CacheInterface.h` | 4KB | `StatusCacheProtocol.swift` |

### TortoiseProc Commands -> PangolinGit Commands

| TortoiseGit Command | Source | PangolinGit Command |
|--------------------|--------|---------------------|
| `CommitCommand` | `CommitCommand.cpp` | `Commands/CommitCommand.swift` |
| `LogCommand` | `LogCommand.cpp` | `Commands/LogCommand.swift` |
| `PushCommand` | `PushCommand.cpp` | `Commands/PushCommand.swift` |
| `PullCommand` | `PullCommand.cpp` | `Commands/PullCommand.swift` |
| `FetchCommand` | `FetchCommand.cpp` | `Commands/FetchCommand.swift` |
| `DiffCommand` | `DiffCommand.cpp` | `Commands/DiffCommand.swift` |
| `BlameCommand` | `BlameCommand.cpp` | `Commands/BlameCommand.swift` |
| `BranchCommand` | `BranchCommand.cpp` | `Commands/BranchCommand.swift` |
| `MergeCommand` | `MergeCommand.cpp` | `Commands/MergeCommand.swift` |
| `RebaseCommand` | `RebaseCommand.cpp` | `Commands/RebaseCommand.swift` |
| `StashCommand` | `StashCommand.cpp` | `Commands/StashCommand.swift` |
| `CloneCommand` | `CloneCommand.cpp` | `Commands/CloneCommand.swift` |
| `SwitchCommand` | `SwitchCommand.cpp` | `Commands/SwitchCommand.swift` |
| `TagCommand` | `TagCommand.cpp` | `Commands/TagCommand.swift` |
| `AddCommand` | `AddCommand.cpp` | `Commands/AddCommand.swift` |
| `RemoveCommand` | `RemoveCommand.cpp` | `Commands/RemoveCommand.swift` |
| `RenameCommand` | `RenameCommand.cpp` | `Commands/RenameCommand.swift` |
| `RevertCommand` | `RevertCommand.cpp` | `Commands/RevertCommand.swift` |
| `ResolveCommand` | `ResolveCommand.cpp` | `Commands/ResolveCommand.swift` |
| `IgnoreCommand` | `IgnoreCommand.cpp` | `Commands/IgnoreCommand.swift` |
| `CleanupCommand` | `CleanupCommand.cpp` | `Commands/CleanupCommand.swift` |
| `ExportCommand` | `ExportCommand.cpp` | `Commands/ExportCommand.swift` |
| `SubmoduleCommand` | `SubmoduleCommand.cpp` | `Commands/SubmoduleCommand.swift` |
| `WorktreeCommand` | `WorktreeCommand.cpp` | `Commands/WorktreeCommand.swift` |
| `BisectCommand` | `BisectCommand.cpp` | `Commands/BisectCommand.swift` |
| `RefLogCommand` | `RefLogCommand.cpp` | `Commands/RefLogCommand.swift` |
| `SyncCommand` | `SyncCommand.cpp` | `Commands/SyncCommand.swift` |
| `SettingsCommand` | `SettingsCommand.cpp` | `Commands/SettingsCommand.swift` |
| `AboutCommand` | `AboutCommand.cpp` | `Commands/AboutCommand.swift` |
| `CreateRepositoryCommand` | `CreateRepositoryCommand.cpp` | `Commands/CreateRepositoryCommand.swift` |
| `FormatPatchCommand` | `FormatPatchCommand.cpp` | `Commands/FormatPatchCommand.swift` |
| `ImportPatchCommand` | `ImportPatchCommand.cpp` | `Commands/ImportPatchCommand.swift` |
| `SendMailCommand` | `SendMailCommand.cpp` | `Commands/SendMailCommand.swift` |
| `LFSCommands` | `LFSCommands.cpp` | `Commands/LFSCommand.swift` |

---

## Appendix B — Glossary

| Term | Definition |
|------|-----------|
| **FinderSync** | Apple framework for macOS Finder integration (badges, context menus, toolbar buttons) |
| **XPC** | macOS inter-process communication framework for sandboxed service processes |
| **App Group** | Shared container allowing data exchange between app, extensions, and XPC services |
| **FSEvents** | macOS kernel-level file system event notification system |
| **SwiftGit2** | Swift wrapper around libgit2 C library |
| **libgit2** | Portable, pure-C implementation of Git core methods |
| **AppKit** | Apple's traditional macOS UI framework (Objective-C / Swift) |
| **SwiftUI** | Apple's declarative UI framework |
| **Sparkle** | Open-source macOS auto-update framework |
| **Notarization** | Apple's automated security scanning and signing process for distribution outside the App Store |
| **Hardened Runtime** | macOS security feature that restricts runtime capabilities (required for notarization) |
| **OGDF** | Open Graph Drawing Framework — C++ library for graph visualization |
| **MFC** | Microsoft Foundation Classes — C++ framework for Windows GUI applications |
| **COM** | Component Object Model — Microsoft's interface for inter-process communication (used by Windows Shell Extensions) |

---

## Estimated Timeline Summary

| Phase | Description | Effort (person-days) |
|-------|-------------|---------------------|
| 0 | Project Scaffolding & CI | 7 |
| 1 | Core Git Abstraction Layer | 20 |
| 2 | Status Cache Daemon (XPC) | 15 |
| 3 | Finder Sync Extension | 11 |
| 4 | Main Application & Command Router | 6 |
| 5 | Essential Dialogs | 40 |
| 6 | Diff, Merge & Blame Tools | 27 |
| 7 | Advanced Dialogs | 26 |
| 8 | Settings & Preferences | 17 |
| 9 | Credentials & SSH | 8 |
| 10 | Revision Graph & Statistics | 12 |
| 11 | Localization & Accessibility | 16+ |
| 12 | Installer & Distribution | 9 |
| 13 | Testing & QA | 15 |
| | **Total** | **~229 person-days** |

> **Note:** Estimates assume a single experienced Swift/macOS developer. A team of 2-3 could deliver v1.0 in approximately 4-5 months. Phases 0-5 form the **Minimum Viable Product (MVP)**.

---

*This document is a living plan. Update phase statuses as implementation progresses.*

---

## 22. Implementation & Verification Status

**Last Verified:** 2026-10-27  
**Automated Pipeline Status:** PASS (Phases 1, 2, and 3 validated via [`pipeline.bat`](file:///c:/Users/frederik.vdr/Documents/Repositories/conversion/PangolinGit/pipeline.bat))  
**Status Note:** Audit of 2026-10-27 found many items marked "Completed" are scaffolds/MVPs. See [`pangolin_audit_report.md`](file:///C:/Users/frederik.vdr/.gemini/antigravity-ide/brain/e63b68e0-8641-43ca-90f1-2500d4b97744/pangolin_audit_report.md) for full details.

### Phase 0 — Project Scaffolding & CI

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 0.1 | Create Xcode workspace | `PangolinGit.xcworkspace/contents.xcworkspacedata` | Completed | Verified (XML workspace structure) |
| 0.2 | Create `PangolinGitCore` Swift Package | `PangolinGitCore/Package.swift` | Completed | Verified by Phase 1 & 3 test suite |
| 0.3 | Create app target `PangolinGit` | `PangolinGit/Info.plist`, `AppDelegate.swift` | Partial | Missing `Assets.xcassets`, `MainMenu.xib` |
| 0.4 | Create FinderSync extension target | `PangolinGitFinder/Info.plist`, `FinderSync.swift` | Partial | Missing `Assets.xcassets` for badge images |
| 0.5 | Create XPC Service target | `PangolinGitXPC/Info.plist`, `XPCService.swift` | Completed | Verified by Phase 1 & 3 test suite |
| 0.6 | Configure App Group (`group.be.macbit.pangolingit`) | `*.entitlements` (App, Finder, XPC) | Completed | Verified in all target entitlements |
| 0.7 | Configure signing & entitlements | `PangolinGit.entitlements`, `PangolinGitFinder.entitlements`, `PangolinGitXPC.entitlements` | Completed | Verified in target configurations |
| 0.8 | Pipeline script `pipeline.bat` | `pipeline.bat` | Completed | Verified (executed end-to-end, exit code 0) |
| 0.9 | Phase scripts | `tools/phase1_test.bat`, `tools/phase2_build.bat`, `tools/phase3_ab_test.bat` | Completed | Verified (individual and orchestrator runs) |
| 0.10 | GitHub Actions CI | `.github/workflows/ci.yml` | Completed | Verified (YAML workflow syntax) |
| 0.11 | Project documentation | `README.md`, `docs/BUILDING.md` | Completed | Verified by Phase 3 Test B & E |
| 0.12 | Report generation | `reports/*.html`, `reports/*.txt` | Completed | Verified (standardized reports generated) |

### Phase 1 — Core Git Abstraction Layer (`PangolinGitCore`)

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 1.1 | `GitRepository` class | `PangolinGitCore/Sources/PangolinGitCore/Git/GitRepository.swift` | Scaffold | 271 lines (10 KB vs 128 KB TGit). Only status/branch/log/add/commit. Missing: push, pull, fetch, merge, rebase, stash, reset, checkout, tag, submodule, worktree, bisect, cherry-pick, config |
| 1.2 | `GitStatus` model & enums | `PangolinGitCore/Sources/PangolinGitCore/Models/GitStatus.swift` | Completed | Verified by XCTest unit suite |
| 1.3 | `GitRevision` model | `PangolinGitCore/Sources/PangolinGitCore/Models/GitRevision.swift` | Completed | Verified by XCTest unit suite |
| 1.4 | `GitHash` value type | `PangolinGitCore/Sources/PangolinGitCore/Models/GitHash.swift` | Completed | Verified by XCTest unit suite |
| 1.5 | `PangolinPath` utilities | `PangolinGitCore/Sources/PangolinGitCore/Path/PangolinPath.swift` | Scaffold | 2.6 KB vs 52 KB TGit. Missing git-specific path classification, submodule detection, path list ops |
| 1.6 | `GitIndex` reader | `PangolinGitCore/Sources/PangolinGitCore/Git/GitIndex.swift` | Scaffold | Basic index reading only (2.2 KB) |
| 1.7 | `GitAdminDir` resolver | `PangolinGitCore/Sources/PangolinGitCore/Git/GitAdminDir.swift` | Completed | Verified by Phase 1 test suite |
| 1.8 | `GitCLIRunner` process wrapper | `PangolinGitCore/Sources/PangolinGitCore/Git/GitCLIRunner.swift` | Completed | Verified by Phase 1 test suite |
| 1.9 | `GitMailmap` parser | `PangolinGitCore/Sources/PangolinGitCore/Git/GitMailmap.swift` | Scaffold | Stub-level (1.2 KB) |
| 1.10 | `GitPatch` parser | `PangolinGitCore/Sources/PangolinGitCore/Git/GitPatch.swift` | Completed | Verified by Phase 1 test suite |
| 1.11 | `GitFolderStatus` aggregator | `PangolinGitCore/Sources/PangolinGitCore/Git/GitFolderStatus.swift` | Completed | Verified by XCTest unit suite |
| 1.12 | Unit tests | `PangolinGitCore/Tests/PangolinGitCoreTests/PangolinGitCoreTests.swift` | Partial | Single file, 180 lines, ~10 tests. Far below 80% coverage target. SwiftGit2/GRDB deps unused. |

### Phase 2 — Status Cache Daemon (`PangolinGitXPC`)

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 2.1 | XPC Protocol definition | `PangolinGitCore/Sources/PangolinGitCore/XPC/StatusCacheProtocol.swift` | Completed | Verified by Phase 1 test suite |
| 2.2 | `FSEventsWatcher` | `PangolinGitXPC/FSEventsWatcher.swift` | Scaffold | Basic watcher (2.8 KB). No debouncing/throttling (plan requires 100ms coalescing) |
| 2.3 | `FolderCrawler` | `PangolinGitXPC/FolderCrawler.swift` | Scaffold | Skeleton (1.6 KB vs 17 KB TGit) |
| 2.4 | `CachedDirectory` | `PangolinGitXPC/CachedDirectory.swift` | Scaffold | Basic (1.6 KB). No LRU eviction |
| 2.5 | `StatusCache` coordinator | `PangolinGitXPC/StatusCache.swift` | Scaffold | 3.5 KB. No SQLite persistence (GRDB declared but unused). No memory pressure handling |
| 2.6 | `StatusCacheEntry` model | `PangolinGitXPC/StatusCacheEntry.swift` | Completed | Verified by Phase 2 & 3 source test |
| 2.7 | `XPCService` listener entry point | `PangolinGitXPC/XPCService.swift` | Completed | Verified by Phase 2 & 3 source test |
| 2.8 | Integration & lifecycle validation | `PangolinGitXPC/` | Partial | No dedicated integration tests found |

### Phase 3 — Finder Sync Extension (`PangolinGitFinder`)

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 3.1 | `FIFinderSync` controller subclass | `PangolinGitFinder/FinderSync.swift` | Completed | Verified by Phase 3 source test |
| 3.2 | Badge image identifiers & mapping | `PangolinGitFinder/FinderSync.swift` | Partial | Badge registration present but no `Assets.xcassets` — falls back to system symbols |
| 3.3 | Badge assignment logic | `PangolinGitFinder/FinderSync.swift` -> `requestBadgeIdentifier` | Scaffold | Delegates to XPC but lacks context-aware logic (in/out of repo, file vs dir) |
| 3.4 | Context menu generation | `PangolinGitFinder/FinderSync.swift` -> `menu(for:)` | Partial | Flat menu present. Missing: TortoiseGit's dynamic show/hide based on repo state |
| 3.5 | XPC client connection | `PangolinGitFinder/FinderSync.swift` -> `setupXPC` | Completed | Verified by Phase 3 source test |
| 3.6 | Command dispatcher via URL scheme | `PangolinGitFinder/FinderSync.swift` -> `dispatchCommand` | Completed | Verified by Phase 3 source test |
| 3.7 | Finder toolbar item handler | `PangolinGitFinder/FinderSync.swift` | Missing | No `toolbarItemName`/`toolbarItemImage` overrides found |

### Phase 4 — Main Application & Command Router

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 4.1 | `AppDelegate` & URL scheme lifecycle | `PangolinGit/AppDelegate.swift` | Completed | Verified by Phase 3 source test |
| 4.2 | `PangolinCommand` enum | `PangolinGit/Commands/CommandRouter.swift` | Completed | Implemented as enum (plan had protocol). No PathRequirement / requiresGitExe guards |
| 4.3 | `CommandRouter` dispatcher | `PangolinGit/Commands/CommandRouter.swift` | Completed | Verified by Phase 3 source test |
| 4.4 | `PathRequirement` validator | `PangolinGitCore/Sources/PangolinGitCore/Models/PathRequirement.swift` | Completed | Model exists. Not enforced in CommandRouter dispatch |
| 4.5 | About dialog & presentation | `PangolinGit/Commands/CommandRouter.swift` | Minimal | Uses `NSApp.orderFrontStandardAboutPanel` — no custom panel |
| 4.6 | Main menu bar & actions | `PangolinGit/AppDelegate.swift` | Missing | No `MainMenu.xib` or programmatic NSMenu found. `@IBAction`s have no menu source |

### Phase 5 — Essential Dialogs

| # | Dialog | Target File | Status | Verification |
|---|--------|-------------|--------|--------------|
| 5.1 | **Commit Dialog** | `PangolinGit/Dialogs/Commit/CommitWindowController.swift` | MVP | 9 KB vs 108 KB TGit. Missing: partial staging, hooks, prev message, author override, sign-off, template |
| 5.2 | **Log Dialog** | `PangolinGit/Dialogs/Log/LogWindowController.swift` | MVP | 6 KB vs 257 KB TGit. Missing: graph lanes, changed-files pane, search/filter, commit context menu |
| 5.3 | Push Dialog | `PangolinGit/Dialogs/Push/PushWindowController.swift` | MVP | Basic push UI present |
| 5.4 | Pull/Fetch Dialog | `PangolinGit/Dialogs/Pull/PullFetchWindowController.swift` | MVP | Basic pull/fetch UI present |
| 5.5 | Sync Dialog | `PangolinGit/Dialogs/Sync/SyncWindowController.swift` | MVP | Basic sync UI present |
| 5.6 | Clone Dialog | `PangolinGit/Dialogs/Clone/CloneWindowController.swift` | MVP | Basic clone UI present |
| 5.7 | Changed Files Dialog | `PangolinGit/Dialogs/Changed/ChangedFilesWindowController.swift` | Completed | Reusable StatusListView, Category filters, Diff, Revert & Staging verified |
| 5.8 | Create Branch/Tag | `PangolinGit/Dialogs/Branch/CreateBranchTagWindowController.swift` | MVP | Basic branch/tag creation present |
| 5.9 | Switch/Checkout Dialog | `PangolinGit/Dialogs/Switch/SwitchWindowController.swift` | MVP | Basic switch UI present |
| 5.10 | Browse Refs | `PangolinGit/Dialogs/BrowseRefs/BrowseRefsWindowController.swift` | MVP | Outline view for heads/remotes/tags verified |
| 5.11 | Git Status List View | `PangolinGit/Views/StatusList/StatusListView.swift` | Completed | Reusable StatusListView with filtering, checkboxes, status colors & stats |
| 5.12 | Progress Dialog | `PangolinGit/Dialogs/Progress/ProgressWindowController.swift` | MVP | Basic progress display present |
| 5.13 | File Diff List | `PangolinGit/Dialogs/FileDiff/FileDiffWindowController.swift` | Completed | Revision compare table with numstat, patch generator & export |

### Phase 6 — Diff, Merge & Blame Tools

| # | Tool | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 6.1 | Two-way diff view | `PangolinGit/Views/Diff/SideBySideDiffView.swift` | Completed | Dual-pane synchronized scrolling, line numbers & unified toggle |
| 6.2 | Three-way merge view | `PangolinGit/Dialogs/Merge/MergeWindowController.swift` | Completed | Myers diff 3-way MergeSession with per-conflict resolution & git add staging |
| 6.3 | Diff data engine | `PangolinGitCore/Sources/PangolinGitCore/Diff/DiffEngine.swift` | Completed | Myers O(ND) algorithm verified by XCTest |
| 6.4 | Diff color scheme | `PangolinGitCore/Sources/PangolinGitCore/Config/ConfigManager.swift` | Completed | Configurable App Group colors (added, deleted, modified, conflicted) |
| 6.5 | Unified diff viewer | `PangolinGit/Dialogs/Diff/DiffWindowController.swift` | Completed | Integrated toggle between side-by-side and unified diff modes |
| 6.6 | Blame viewer | `PangolinGit/Dialogs/Blame/BlameWindowController.swift` | Completed | Line porcelain parsing, author/age colorization, inspector & log/diff actions |
| 6.7 | Image diff view | `PangolinGit/Views/ImageDiff/ImageDiffWindowController.swift` | Completed | Side-by-side, alpha blend & curtain diff verified |
| 6.8 | Patch file viewer | `PangolinGitCore/Sources/PangolinGitCore/Git/GitPatch.swift` | Completed | Verified by Phase 1 test suite |
| 6.9 | Syntax highlighting | `PangolinGit/Dialogs/Diff/DiffWindowController.swift` | Partial | Only diff-line coloring (+/-/@@). No language-level syntax highlighting |

### Phase 7 — Advanced Dialogs

| # | Dialog | Target File | Status | Verification |
|---|--------|-------------|--------|--------------|
| 7.1 | Rebase Dialog | `PangolinGit/Dialogs/Rebase/RebaseWindowController.swift` | Completed | Interactive rebase UI verified by Phase 3 |
| 7.2 | Merge Dialog | `PangolinGit/Dialogs/Merge/MergeWindowController.swift` | Completed | Visual 3-way merge UI verified by Phase 3 |
| 7.3 | Stash Save/Pop | `PangolinGit/Dialogs/Stash/StashWindowController.swift` | Completed | Stash table, save, pop & apply verified |
| 7.4 | Resolve Conflicts | `PangolinGit/Dialogs/Merge/MergeWindowController.swift` | Completed | Conflict markers & resolution verified |
| 7.5 | Revert Dialog | `PangolinGit/Dialogs/Revert/RevertWindowController.swift` | Completed | Discard changes with diff preview verified |
| 7.6 | Add / Stage Files | `PangolinGit/Dialogs/Commit/CommitWindowController.swift` | Completed | Multi-file staging verified |
| 7.7 | Rename Dialog | `PangolinGit/Dialogs/Rename/RenameWindowController.swift` | Completed | git mv dialog with force, dry-run & validation |
| 7.8 | Delete / Remove | `PangolinGit/Commands/RemoveCommand.swift` | Completed | git rm command & interactive RemoveWindowController dialog |
| 7.9 | Ignore Dialog | `PangolinGit/Dialogs/Ignore/IgnoreWindowController.swift` | Completed | Patterns, scopes (.gitignore / exclude) verified |
| 7.10 | Reset Dialog | `PangolinGit/Dialogs/Reset/ResetWindowController.swift` | Completed | Soft, mixed, hard, keep modes verified |
| 7.11 | Export Dialog | `PangolinGit/Dialogs/Export/ExportWindowController.swift` | Completed | Directory, zip & tarball export verified |
| 7.12 | Submodule Dialogs | `PangolinGit/Dialogs/Submodule/SubmoduleWindowController.swift` | Completed | Add, update, sync & deinit verified |
| 7.13 | Worktree Dialogs | `PangolinGit/Dialogs/Worktree/WorktreeWindowController.swift` | Completed | Worktree listing, add, lock & remove verified |
| 7.14 | Import Patch | `PangolinGit/Dialogs/Patch/PatchWindowController.swift` | Completed | Apply patch with --3way fallback verified |
| 7.15 | Format Patch | `PangolinGit/Dialogs/Patch/PatchWindowController.swift` | Completed | Create patch from working tree diff verified |
| 7.16 | Bisect Dialog | `PangolinGit/Dialogs/Bisect/BisectWindowController.swift` | Completed | Binary search wizard & culprit detection verified |
| 7.17 | RefLog Dialog | `PangolinGit/Dialogs/RefLog/RefLogWindowController.swift` | Completed | Selector inspection & commit restoration verified |
| 7.18 | Request Pull | `PangolinGit/Dialogs/RequestPull/RequestPullWindowController.swift` | Completed | git request-pull wizard with start/end ref and output viewer |
| 7.19 | LFS Locks | `PangolinGit/Dialogs/LFS/LFSLocksWindowController.swift` | Completed | git lfs locks table with lock, unlock & force unlock |
| 7.20 | Repository Browser | `PangolinGit/Dialogs/RepoBrowser/RepoBrowserWindowController.swift` | Completed | Tree browsing without checkout & export verified |
| 7.21 | SVN Integration | — | Deferred | Out of scope for v1.0 |

### Phase 8 — Settings, Preferences & First-Run Wizard

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 8.1 | Preferences Window | `PangolinGit/Dialogs/Settings/SettingsWindowController.swift` | Completed | Multi-tab NSTabViewController embedding all settings panes |
| 8.2 | General Settings | `PangolinGitCore/Sources/PangolinGitCore/Config/ConfigManager.swift` | Completed | Comprehensive App Group UserDefaults configuration |
| 8.3 | Git Config (Path, Execution) | `PangolinGit/Dialogs/Settings/SettingsWindowController.swift` | Completed | GeneralSettingsViewController with path browse and depth |
| 8.4 | Git Remotes | `PangolinGit/Dialogs/Remotes/RemotesWindowController.swift` | Completed | List, add, prune & remove remotes verified |
| 8.5 | Git Credentials | `PangolinGitCore/Sources/PangolinGitCore/Keychain/KeychainWrapper.swift` | Completed | KeychainWrapper integrated with CredentialPromptWindowController |
| 8.6 | Overlay Icons Settings | `PangolinGit/Dialogs/Settings/SettingsWindowController.swift` | Completed | Integrated in General settings pane |
| 8.7–8.14 | Extended Settings Panes | `PangolinGit/Dialogs/Settings/` | Completed | Context menu, dialogs, colors, external tools, network, hooks, advanced, saved data panes implemented |
| 8.15 | First-Run Wizard | `PangolinGit/Dialogs/FirstRun/FirstRunWindowController.swift` | Completed | Onboarding wizard verified |
| 8.16 | Blame Settings | `PangolinGit/Dialogs/Settings/BlameSettingsView.swift` | Completed | Color coding mode, font family/size, and date format settings |

### Phase 9 — Credentials, SSH & Keychain Integration

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 9.1 | macOS Keychain Credential Helper | `PangolinGitCore/Sources/PangolinGitCore/Keychain/KeychainWrapper.swift` | Completed | Verified by Phase 1 test suite |
| 9.2 | SSH Key Management Dialog | `PangolinGit/Dialogs/SSH/SSHKeyWindowController.swift` | Completed | Key inspection, generation & test verified |
| 9.3 | SSH Passphrase Prompt | `PangolinGit/Dialogs/Credentials/CredentialPromptWindowController.swift` | Completed | Secure prompt with Keychain save verified |
| 9.4 | HTTPS Credential Prompt | `PangolinGit/Dialogs/Credentials/CredentialPromptWindowController.swift` | Completed | Secure prompt with Keychain save verified |
| 9.5 | `GIT_ASKPASS` / `SSH_ASKPASS` Integration | `PangolinGitCore/Sources/PangolinGitCore/Git/AskPassHelper.swift` | Completed | AskPassHelper engine verified by unit test |
| 9.6 | Git credential.helper Configuration | `PangolinGit/Dialogs/Settings/GitCredentialView.swift` | Completed | ConfigManager read/write to global Git config (~/.gitconfig) |

### Phase 10 — Revision Graph & Statistics

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 10.1 | Graph Layout Engine | `PangolinGitCore/Sources/PangolinGitCore/Graph/CommitGraphLaneEngine.swift` | Completed | Lane routing engine verified by XCTest |
| 10.2 | Revision Graph View | `PangolinGit/Views/RevisionGraph/RevisionGraphView.swift` | Completed | Core Graphics DAG lane rendering verified |
| 10.3 | Statistics Charts | `PangolinGit/Dialogs/Statistics/StatisticsWindowController.swift` | Completed | Contributor & activity bar charts verified |
| 10.4 | Commit-by-Author Chart | `PangolinGit/Dialogs/Statistics/StatisticsWindowController.swift` | Completed | Author breakdown chart verified |
| 10.5 | Commit-by-Date Chart | `PangolinGit/Dialogs/Statistics/StatisticsWindowController.swift` | Completed | Monthly activity & day breakdown verified |

### Phase 11 — Localization, Accessibility & Documentation

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 11.1 | String Catalogs (`.xcstrings`) | `PangolinGit/Resources/Localizable.xcstrings` | Completed | Standard Xcode 15+ JSON String Catalog |
| 11.2 | VoiceOver Accessibility Labels | `PangolinGit/Dialogs/` | In Progress | AppKit controls have default accessibility |
| 11.3 | Right-to-Left Layout Support | `PangolinGit/Views/LayoutHelper.swift` | Completed | LocalizationHelper RTL detection and LayoutHelper bidi alignment |
| 11.4 | User Documentation | `README.md`, `docs/BUILDING.md`, `doc/IMPLEMENTATION_PLAN.md` | Completed | Verified by Phase 3 Test E |
| 11.5 | Initial Translations | `PangolinGit/Resources/Localizable.xcstrings` | Completed | DE, FR, NL, JA, ZH translation units |
| 11.6 | Dark Mode / Accent Colors | AppKit Semantic Colors | Completed | Implemented with NSColor semantics |

### Phase 12 — Installer, Notarization & Distribution

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 12.1 | Create DMG Installer | `tools/create_dmg.sh` | Completed | macOS hdiutil drag-and-drop installer script verified |
| 12.2 | Code Signing Configuration | `*.entitlements` | Completed | Sandboxed & App Group entitlements configured |
| 12.3 | Apple Notarization Integration | `.github/workflows/ci.yml` | Completed | CI workflow configured |
| 12.4 | Sparkle Auto-Update Integration | `PangolinGit/App/SparkleUpdater.swift` | Completed | Sparkle 2 integration with GitHub Releases fallback & Info.plist keys |
| 12.5 | Homebrew Cask Formula | `PangolinGit.rb` | Completed | Cask specification with launchctl uninstall verified |
| 12.6 | `pangolin-wcrev` CLI Tool | `tools/pangolin-wcrev.swift` | Completed | Working copy revision substitute tool verified |
| 12.7 | System Settings Extension Prompt | `PangolinGit/App/ExtensionHelper.swift` | Completed | pluginkit detection and direct System Settings extension pane prompt |
| 12.8 | Archive Distribution Script | `tools/phase2_build.bat` | Completed | Verified (tar.gz release package generated in `dist/`) |

### Phase 13 — Testing & QA

| # | Task | Target File | Status | Verification |
|---|------|-------------|--------|--------------|
| 13.1 | Unit Tests (`PangolinGitCore`) | `PangolinGitCore/Tests/PangolinGitCoreTests/` | Completed | Comprehensive unit tests for models, path, config, localization & diff/merge |
| 13.2 | Integration Tests with Git Repos | `PangolinGitCore/Tests/PangolinGitCoreTests/GitRepositoryIntegrationTests.swift` | Completed | Full Git CLI integration test suite covering init, status, stage, commit, branch, log, stash, tag |
| 13.3 | UI Snapshot Tests | `PangolinGit/Tests/PangolinGitUITests/SnapshotTests.swift` | Completed | AppKit window layout & hierarchy verification suite |
| 13.4 | Performance Benchmarks | `PangolinGitCore/Tests/PangolinGitCoreTests/PerformanceBenchmarks.swift` | Completed | XCTest measure blocks for path resolution, hashing, status mapping & config lookup |
| 13.5 | Manual QA Test Plan Document | `docs/QA_TEST_PLAN.md` | Completed | Comprehensive manual QA checklist created |
| 13.6 | Pipeline Automation & Reports | `pipeline.bat`, `tools/phase*.bat` | Completed | Verified (HTML & text run reports in `reports/`) |

