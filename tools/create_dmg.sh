#!/usr/bin/env bash
# ============================================================================
# PangolinGit - DMG Package Generator
# Builds a drag-and-drop disk image (dist/PangolinGit.dmg) from a Release build and updates the
# version and SHA-256 of the Homebrew cask (PangolinGit.rb) to match it.
#
#   tools/build.sh release      # produces build/Release/PangolinGit.app
#   tools/create_dmg.sh [path/to/PangolinGit.app]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist"
APP_NAME="PangolinGit"
VOL_NAME="PangolinGit"
DMG_NAME="${DIST_DIR}/${APP_NAME}.dmg"
DMG_TMP="${DIST_DIR}/tmp_${APP_NAME}.dmg"
STAGING_DIR="${PROJECT_ROOT}/build/dmg_staging"
CASK="${PROJECT_ROOT}/PangolinGit.rb"

# The app: an explicit argument, else tools/build.sh's output, else Xcode's Release products.
APP_PATH="${1:-}"
if [[ -z "${APP_PATH}" ]]; then
    for candidate in "${PROJECT_ROOT}/build/Release/${APP_NAME}.app" \
                     "${PROJECT_ROOT}/build/DerivedData/Build/Products/Release/${APP_NAME}.app"; do
        if [[ -d "${candidate}" ]]; then APP_PATH="${candidate}"; break; fi
    done
fi
if [[ -z "${APP_PATH}" || ! -x "${APP_PATH}/Contents/MacOS/${APP_NAME}" ]]; then
    echo "error: no Release build of ${APP_NAME}.app found. Run 'tools/build.sh release' first or pass the app path." >&2
    exit 1
fi
command -v hdiutil >/dev/null || { echo "error: hdiutil is required (macOS only)." >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"

mkdir -p "${DIST_DIR}"
rm -rf "${STAGING_DIR}" "${DMG_NAME}" "${DMG_TMP}"
mkdir -p "${STAGING_DIR}"
trap 'rm -rf "${STAGING_DIR}" "${DMG_TMP}"' EXIT

echo "==> Staging ${APP_PATH} (version ${VERSION})"
ditto "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"
cp "${PROJECT_ROOT}/README.md" "${STAGING_DIR}/README.md"

echo "==> Creating disk image"
hdiutil create -quiet -volname "${VOL_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDRW "${DMG_TMP}"
hdiutil convert -quiet "${DMG_TMP}" -format UDZO -imagekey zlib-level=9 -o "${DMG_NAME}"

SHA="$(shasum -a 256 "${DMG_NAME}" | awk '{print $1}')"
echo "${SHA}  ${APP_NAME}.dmg" > "${DMG_NAME}.sha256"

# Keep the cask in step with the image (the update checker also verifies against the .sha256 file).
if [[ -f "${CASK}" ]]; then
    sed -i '' -E "s/^  version \".*\"/  version \"${VERSION}\"/; s/^  sha256 .*/  sha256 \"${SHA}\"/" "${CASK}"
    echo "==> Updated ${CASK##*/}: version ${VERSION}, sha256 ${SHA}"
fi
echo "==> ${DMG_NAME}"
