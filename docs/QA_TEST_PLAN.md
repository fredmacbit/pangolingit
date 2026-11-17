# PangolinGit — Manual QA Test Plan

## Overview
This document specifies the verification test cases for validating PangolinGit's desktop functionality, FinderSync shell integration, status cache daemon (XPC), and Git CLI operations on macOS 13+ (Ventura, Sonoma, Sequoia).

---

## 1. FinderSync Shell Integration Tests

### Test 1.1: Extension Activation & Overlay Badges
- **Objective:** Verify Finder displays status overlay badges on files and directories.
- **Steps:**
  1. Open **System Settings -> Privacy & Security -> Extensions -> Added Extensions**.
  2. Enable `PangolinGitFinder`.
  3. Navigate to a Git repository in Finder.
  4. Verify clean tracked files show a green checkmark badge (`badge-normal`).
  5. Edit a file. Verify badge changes dynamically to orange exclamation (`badge-modified`).
  6. Create an untracked file. Verify badge displays unversioned question mark (`badge-unversioned`).
  7. Introduce a Git merge conflict. Verify badge displays red cross/conflict badge (`badge-conflicted`).
- **Pass Criteria:** Badges update within 500ms of file system modification via FSEvents.

### Test 1.2: Context Menu Actions
- **Objective:** Verify right-click actions open the corresponding dialogs.
- **Steps:**
  1. Right-click on a repository directory in Finder.
  2. Verify top-level items appear: `Git Commit...`, `Diff`, `Show Log`, `Blame...`.
  3. Expand `PangolinGit` submenu. Verify all extended commands are present:
     - `Pull...`, `Push...`, `Sync...`
     - `Check for Modifications...`, `Revert...`, `Reset...`
     - `Switch/Checkout...`, `Browse References...`, `Stash Changes...`
     - `Worktrees...`, `Submodules...`, `Create/Apply Patch...`
     - `Revision Statistics...`, `Repository Browser...`, `Show RefLog...`, `Git Bisect...`
     - `Add to Ignore List...`, `Export...`, `Manage Remotes...`, `SSH Keys...`, `Settings`.
  4. Click `Git Commit...`. Verify `CommitWindowController` opens with the selected repository path prefilled.
- **Pass Criteria:** All menu items trigger custom URL scheme `pangolingit://<cmd>?path=...` and launch appropriate controllers.

---

## 2. Core Dialog Tests

### Test 2.1: Commit Dialog
- **Objective:** Stage modified files and make a new commit.
- **Steps:**
  1. Launch Commit dialog (`pangolingit://commit`).
  2. Verify list shows modified, untracked, and deleted files with checkboxes.
  3. Check specific files. Enter a commit message.
  4. Click **Commit**.
  5. Check `git log -1`.
- **Pass Criteria:** Selected files committed cleanly with correct author identity and message.

### Test 2.2: 3-Way Merge & Conflict Resolution
- **Objective:** Replicate TortoiseMerge visual 3-way conflict resolution.
- **Steps:**
  1. Create merge conflict on a file.
  2. Launch Merge dialog (`pangolingit://merge?path=...`).
  3. Verify left pane shows *Ours* (HEAD), right pane shows *Theirs* (incoming), and bottom pane shows editable *Merged Result*.
  4. Click **Use Ours** on a conflict block. Verify merged editor incorporates *Ours*.
  5. Click **Mark Resolved**.
- **Pass Criteria:** Conflict markers removed, resolved file staged in git index.

### Test 2.3: Image Diff Comparison
- **Objective:** Test visual image diff modes (`TortoiseIDiff`).
- **Steps:**
  1. Open an image diff between two image revisions (`pangolingit://imagediff`).
  2. Switch between **Side-by-Side**, **Alpha Blend**, and **Swipe / Curtain** modes.
  3. Drag the blend/curtain slider across 0.0 to 1.0.
  4. Verify zoom and pan stay synchronized across both images.
- **Pass Criteria:** Images render smoothly with hardware-accelerated Core Animation and Core Graphics clipping.

### Test 2.4: Interactive Rebase
- **Objective:** Test interactive rebase controls.
- **Steps:**
  1. Open Rebase dialog (`pangolingit://rebase`).
  2. Select 3 recent commits. Change action of commit 2 to `squash` and commit 3 to `reword`.
  3. Reorder commits using **Move Up** / **Move Down**.
  4. Click **Start Rebase**.
- **Pass Criteria:** Git interactive rebase executes according to selected sequence.

---

## 3. Tooling & CLI Utilities

### Test 3.1: `pangolin-wcrev` Build Replacement
- **Objective:** Substitute working copy keywords in templates.
- **Steps:**
  1. Create `version.h.in` with `$WCREV$`, `$WCDATE$`, `$WCMODS?DIRTY:CLEAN$`.
  2. Run `pangolin-wcrev . version.h.in version.h`.
  3. Verify `version.h` contains actual commit hash, ISO date, and clean/dirty state.
- **Pass Criteria:** All tokens substituted accurately without regex errors.

---

## 4. Pipeline & Automated Smoke Tests
- Run `pipeline.bat` on Windows or `pipeline.sh` on macOS.
- Phase 1: Functional and source structure verification -> exit code 0.
- Phase 2: Packaging tar.gz distribution in `dist/` -> exit code 0.
- Phase 3: A/B verification suite (6/6 tests passing) -> exit code 0.
