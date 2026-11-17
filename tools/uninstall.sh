#!/bin/bash
# Removes PangolinGit: unregisters the Finder extension and status agent, then deletes the app.
# Preferences and other saved data are kept unless --purge is given; --purge removes the shared
# App Group container (settings, stored decisions, hook table), caches, logs and saved window state.
set -u
APP="/Applications/PangolinGit.app"
[ -d "$APP" ] || { echo "PangolinGit is not installed in /Applications."; exit 1; }

"$APP/Contents/MacOS/PangolinGit" --unregister-services
/usr/bin/pkill -x PangolinGit 2>/dev/null
/usr/bin/pkill -x PangolinGitAgent 2>/dev/null
/bin/launchctl bootout "gui/$(id -u)/be.macbit.pangolingit.agent" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/be.macbit.pangolingit.agent.plist"

if ! rm -rf "$APP" 2>/dev/null || [ -d "$APP" ]; then
    echo "Administrator rights are needed to delete $APP."
    sudo rm -rf "$APP"
fi
/usr/sbin/pkgutil --forget be.macbit.pangolingit.pkg >/dev/null 2>&1 || sudo /usr/sbin/pkgutil --forget be.macbit.pangolingit.pkg >/dev/null 2>&1

if [ "${1:-}" = "--purge" ]; then
    defaults delete group.be.macbit.pangolingit 2>/dev/null
    defaults delete be.macbit.pangolingit 2>/dev/null
    rm -rf "$HOME/Library/Group Containers/group.be.macbit.pangolingit" \
           "$HOME/Library/Preferences/group.be.macbit.pangolingit.plist" \
           "$HOME/Library/Preferences/be.macbit.pangolingit.plist" \
           "$HOME/Library/Caches/be.macbit.pangolingit" \
           "$HOME/Library/Logs/PangolinGit" \
           "$HOME/Library/Application Support/PangolinGit" \
           "$HOME/Library/Saved Application State/be.macbit.pangolingit.savedState"
fi
/usr/bin/killall Finder 2>/dev/null
echo "PangolinGit has been removed."
