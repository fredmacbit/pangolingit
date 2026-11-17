#!/bin/bash
# Builds dist/PangolinGit-<version>.pkg: installs PangolinGit.app into /Applications, then registers
# the Finder extension and status agent for the logged-in user (installer/scripts/postinstall).
#
#   tools/make_installer.sh
#
# Optional environment:
#   APP_SIGN_IDENTITY        "Developer ID Application: Name (TEAMID)"  (default: ad-hoc "-")
#   INSTALLER_SIGN_IDENTITY  "Developer ID Installer: Name (TEAMID)"    (default: unsigned package)
#   NOTARY_PROFILE           notarytool keychain profile; notarizes and staples the package
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

if ! xcode-select -p | grep -q "Xcode.app"; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -1)
APP_IDENTITY="${APP_SIGN_IDENTITY:--}"
WORK="$ROOT/build/installer"
STAGE="$WORK/root"
OUTPUT="$ROOT/dist/PangolinGit-$VERSION.pkg"

echo "==> Building PangolinGit $VERSION (signing identity: $APP_IDENTITY)"
xcodegen generate --quiet
SIGN_FLAGS=(CODE_SIGN_IDENTITY="$APP_IDENTITY" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
if [[ "$APP_IDENTITY" != "-" ]]; then
    SIGN_FLAGS+=(OTHER_CODE_SIGN_FLAGS="--timestamp")
fi
xcodebuild -workspace PangolinGit.xcworkspace -scheme PangolinGit -configuration Release \
    -derivedDataPath build/DerivedData "${SIGN_FLAGS[@]}" build -quiet

APP="build/DerivedData/Build/Products/Release/PangolinGit.app"
codesign --verify --deep --strict "$APP"

echo "==> Staging"
rm -rf "$WORK"
mkdir -p "$STAGE" "$ROOT/dist"
ditto "$APP" "$STAGE/PangolinGit.app"

# Always install to /Applications: without this, Installer "upgrades" any other copy it finds
# (e.g. an Xcode build folder) in place instead.
pkgbuild --analyze --root "$STAGE" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$WORK/components.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/components.plist"

echo "==> Packaging"
pkgbuild --root "$STAGE" \
    --component-plist "$WORK/components.plist" \
    --install-location /Applications \
    --scripts installer/scripts \
    --identifier be.macbit.pangolingit.pkg \
    --version "$VERSION" \
    "$WORK/PangolinGit-component.pkg" >/dev/null

cp LICENSE "$WORK/LICENSE.txt"
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>PangolinGit $VERSION</title>
    <background file="background.tiff" mime-type="image/tiff" alignment="bottomleft" scaling="none"/>
    <background-darkAqua file="background.tiff" mime-type="image/tiff" alignment="bottomleft" scaling="none"/>
    <welcome file="welcome.html" mime-type="text/html"/>
    <license file="LICENSE.txt"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="true" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="PangolinGit">
        <pkg-ref id="be.macbit.pangolingit.pkg"/>
    </choice>
    <pkg-ref id="be.macbit.pangolingit.pkg" version="$VERSION" onConclusion="none">PangolinGit-component.pkg</pkg-ref>
</installer-gui-script>
XML
cp installer/resources/*.html "$WORK/"
# One multi-resolution TIFF so the sidebar artwork is sharp on Retina displays.
tiffutil -cathidpicheck installer/resources/background.png installer/resources/background@2x.png \
    -out "$WORK/background.tiff" >/dev/null

PRODUCT_FLAGS=()
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
    PRODUCT_FLAGS+=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
fi
productbuild --distribution "$WORK/distribution.xml" \
    --resources "$WORK" \
    --package-path "$WORK" \
    "${PRODUCT_FLAGS[@]+"${PRODUCT_FLAGS[@]}"}" \
    "$OUTPUT" >/dev/null

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$OUTPUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUTPUT"
fi

# Give the package file the app icon in Finder (stored in extended attributes; lost if uploaded).
ICON="$STAGE/PangolinGit.app/Contents/Resources/AppIcon.icns"
if [[ -f "$ICON" ]]; then
    swift -e "import AppKit; _ = NSWorkspace.shared.setIcon(NSImage(contentsOfFile: \"$ICON\"), forFile: \"$OUTPUT\", options: [])" 2>/dev/null || true
fi

# Build-folder copies must not stay registered: Finder could load their extension and the
# pangolingit:// URLs could open them instead of the installed app.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in "$ROOT"/build/DerivedData/Build/Products/*/PangolinGit.app "$STAGE/PangolinGit.app" "$ROOT/build/Release/PangolinGit.app"; do
    [[ -d "$copy" ]] || continue
    pluginkit -r "$copy/Contents/PlugIns/PangolinGitFinder.appex" 2>/dev/null || true
    "$LSREGISTER" -u "$copy" 2>/dev/null || true
done
rm -rf "$STAGE"

echo "==> $OUTPUT"
if [[ "$APP_IDENTITY" == "-" ]]; then
    echo "    Ad-hoc signed: install locally with  sudo installer -pkg \"$OUTPUT\" -target /"
    echo "    or double-click it (if Gatekeeper objects: right-click ▸ Open)."
fi
