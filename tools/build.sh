#!/bin/bash
# PangolinGit build pipeline (replaces the Windows pipeline.bat / phase*.bat scripts).
#   tools/build.sh            regenerate project, run all tests, build Debug
#   tools/build.sh release    ... and build an unsigned Release app into build/Release
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcode-select -p | grep -q "Xcode.app"; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }

# Signing: set DEVELOPMENT_TEAM to sign for real; otherwise build unsigned (compile/test only —
# the Finder extension and app group need a real team to run).
SIGNING=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    SIGNING=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development")
fi

echo "==> Generating Xcode project"
xcodegen generate --quiet

echo "==> Testing"
xcodebuild -workspace PangolinGit.xcworkspace -scheme PangolinGit -derivedDataPath build/DerivedData \
    "${SIGNING[@]}" test | tail -n 3

if [[ "${1:-}" == "release" ]]; then
    echo "==> Building Release"
    xcodebuild -workspace PangolinGit.xcworkspace -scheme PangolinGit -configuration Release \
        -derivedDataPath build/DerivedData "${SIGNING[@]}" build | tail -n 1
    mkdir -p build/Release
    rm -rf build/Release/PangolinGit.app
    cp -R build/DerivedData/Build/Products/Release/PangolinGit.app build/Release/
    echo "==> build/Release/PangolinGit.app"
fi
