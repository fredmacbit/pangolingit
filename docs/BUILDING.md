# Building PangolinGit

## Prerequisites

- macOS 13 Ventura or later (deployment target); a current Xcode (tested with Xcode 27.1)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Git — Xcode Command Line Tools or Homebrew. PangolinGit prefers `/opt/homebrew/bin/git`,
  then `/usr/local/bin/git`, then `/usr/bin/git`, unless a path is set in Settings.

## The Xcode project is generated

`PangolinGit.xcodeproj` is generated from [`project.yml`](../project.yml) and should not be edited by hand.
Run `xcodegen generate` after adding, removing, or moving source files, then open `PangolinGit.xcworkspace`.

## Quick start

```bash
tools/build.sh            # generate project, run all tests, Debug build (unsigned)
tools/build.sh release    # ... plus build/Release/PangolinGit.app
```

Core library only (no Xcode project needed):

```bash
cd PangolinGitCore && swift test
```

## Icons

All icon assets (app icon set, Finder submenu icon, Installer artwork) are generated from
`images/icon.jpg`. After changing the artwork run `swift tools/generate_icons.swift`.

## Installer

```bash
tools/make_installer.sh        # → dist/PangolinGit-<version>.pkg
sudo installer -pkg dist/PangolinGit-1.0.0.pkg -target /      # or double-click the .pkg
```

The package installs `PangolinGit.app` into `/Applications` and its postinstall script, running as the
logged-in user, calls `PangolinGit --register-services`, which:

- registers the app with LaunchServices (the `pangolingit://` URLs used by the context menu) and
  unregisters other copies, such as Xcode build folders;
- registers and enables the Finder extension with PlugInKit (`pluginkit -a` / `pluginkit -e use`),
  removing registrations of other copies;
- registers the status agent with `SMAppService`, falling back to `~/Library/LaunchAgents/be.macbit.pangolingit.agent.plist`
  when Background Task Management refuses an ad-hoc-signed app.

It then restarts Finder. PangolinGit itself does not open: like TortoiseGitProc on Windows it is a
background process that Finder starts on demand, and the first context-menu command also shows the
first-run wizard. The installer opens it only when macOS still needs the user to approve the extension or
the agent. If no user is logged in (e.g. an MDM install), open PangolinGit once from Applications to
register it. Uninstall with
`/Applications/PangolinGit.app/Contents/Resources/uninstall.sh` (`--purge` also removes preferences).

## Signing

Without a certificate everything is ad-hoc signed, which is enough to install and run on the machine
that built it. No App Group or provisioning profile is involved: the sandboxed extension reaches the agent
through a `temporary-exception.mach-lookup.global-name` entitlement, and the agent relays the settings the
extension needs.

For distribution to other Macs:

```bash
APP_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
INSTALLER_SIGN_IDENTITY="Developer ID Installer: Name (TEAMID)" \
NOTARY_PROFILE=pangolin-notary \
tools/make_installer.sh
```

(`NOTARY_PROFILE` is a keychain profile created with `xcrun notarytool store-credentials`.) An unsigned,
un-notarized package copied to another Mac is blocked by Gatekeeper until the user right-clicks ▸ Open.

## Architecture at runtime

| Bundle location | Role |
|---|---|
| `Contents/MacOS/PangolinGit` | Background process (`LSUIElement`, TortoiseGitProc equivalent): command router and all dialogs. It has a Dock icon and menu bar only while a dialog is open; opened directly from Applications it shows Settings |
| `Contents/PlugIns/PangolinGitFinder.appex` | Sandboxed FinderSync extension: badges, context menu, toolbar button |
| `Contents/MacOS/PangolinGitAgent` | Non-sandboxed status-cache launch agent (TGitCache equivalent), registered with `SMAppService` |
| `Contents/Library/LaunchAgents/be.macbit.pangolingit.agent.plist` | launchd definition for the agent (Mach service `group.be.macbit.pangolingit.agent`) |
| `Contents/MacOS/pangolin-askpass` | `GIT_ASKPASS`/`SSH_ASKPASS` dialog (SshAskPass equivalent) |
| `Contents/MacOS/pangolin-wcrev` | SubWCRev equivalent CLI |

Finder → extension → (XPC over Mach service) → agent → `git status`; context-menu actions go
extension → `pangolingit://command?path=…` → app.

## Enabling the Finder extension manually

The installer and the first-run wizard do this automatically. If badges or menus are missing:

1. **System Settings ▸ General ▸ Login Items & Extensions**: enable *PangolinGit* under Finder extensions,
   and allow *PangolinGit* in the background-items list (the status agent).
2. `killall Finder` if badges don't appear.

Troubleshooting:

```bash
pluginkit -m -v -i be.macbit.pangolingit.finder     # extension registered? (+ = enabled)
launchctl print gui/$(id -u)/be.macbit.pangolingit.agent
log stream --predicate 'subsystem == "be.macbit.pangolingit"'
```
