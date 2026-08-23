#!/bin/bash
#
# release.sh — build, sign, notarize, and package ClaudeCodeRemoteServer.app
# for distribution to testers.
#
#   bash mac/release.sh                 # archive + Developer ID export + DMG
#   bash mac/release.sh --no-notarize   # skip notarization (local testing only)
#
# Why not TestFlight: macOS TestFlight ships through App Store Connect, which
# requires a Mac App Store provisioning profile, which requires the App Sandbox.
# This app execs the `claude` CLI outside its container, lets Claude edit
# arbitrary working directories, and posts synthetic input events through the
# computer-use MCP. None of that survives sandboxing, so the distribution route
# is Developer ID + notarization: testers download the DMG and it opens with no
# Gatekeeper warning.
#
# One-time prerequisites:
#
#   1. A "Developer ID Application" certificate (paid Apple Developer Program).
#      Xcode → Settings → Accounts → your team → Manage Certificates →
#      + → Developer ID Application.
#
#   2. A stored notarization credential:
#      xcrun notarytool store-credentials ClaudeCodeRemoteNotary \
#          --apple-id <your-apple-id> --team-id KUGPEZH97N \
#          --password <app-specific-password>
#
#      Create the app-specific password at appleid.apple.com → Sign-In and
#      Security → App-Specific Passwords. notarytool keeps it in your keychain;
#      it is never stored in this repo.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="ClaudeCodeRemoteServer"
APP_NAME="ClaudeCodeRemoteServer"
NOTARY_PROFILE="${CCR_NOTARY_PROFILE:-ClaudeCodeRemoteNotary}"
TEAM_ID="${CCR_TEAM_ID:-KUGPEZH97N}"

BUILD_DIR="${REPO_ROOT}/build/mac"
ARCHIVE="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG="${BUILD_DIR}/${APP_NAME}.dmg"

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

log() { echo ""; echo "▸ $*"; }

cd "${REPO_ROOT}"

# ── 0. Preflight ──────────────────────────────────────────────────────────────

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    cat >&2 <<'MSG'
error: no "Developer ID Application" certificate in the keychain.

  Create one in Xcode → Settings → Accounts → select your team →
  Manage Certificates → + → Developer ID Application.
  (Requires a paid Apple Developer Program membership and Admin/Account Holder
  role on the team.)

  To build an unsigned bundle for local testing only:
      bash mac/release.sh --no-notarize
MSG
    [[ ${NOTARIZE} -eq 1 ]] && exit 1
fi

# Check the notary credential up front. It is only *used* after the archive and
# export, and discovering it is missing there costs a full rebuild.
if [[ ${NOTARIZE} -eq 1 ]]; then
    if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
        cat >&2 <<MSG
error: no stored notarization credential named "${NOTARY_PROFILE}".

  Create it (note the xcrun prefix — notarytool ships inside Xcode and is not
  on PATH by itself). Omit --password so it prompts, keeping the secret out of
  your shell history:

      xcrun notarytool store-credentials ${NOTARY_PROFILE} \\
          --apple-id <your-apple-id> --team-id ${TEAM_ID}

  The password it asks for is an app-specific password, not your Apple ID
  password: appleid.apple.com -> Sign-In and Security -> App-Specific Passwords.

  To build a signed but un-notarized bundle for local testing:
      bash mac/release.sh --no-notarize
MSG
        exit 1
    fi
fi

command -v xcodegen >/dev/null && { log "Regenerating Xcode project"; xcodegen generate; }

# ── 1. Archive ────────────────────────────────────────────────────────────────

log "Archiving ${SCHEME}"
rm -rf "${ARCHIVE}" "${EXPORT_DIR}" "${DMG}"
mkdir -p "${BUILD_DIR}"

xcodebuild archive \
    -project "${REPO_ROOT}/ClaudeCodeRemote.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE}" \
    -destination 'generic/platform=macOS' \
    | tail -5

# ── 2. Export with Developer ID ───────────────────────────────────────────────

log "Exporting Developer ID build"
EXPORT_PLIST="${BUILD_DIR}/ExportOptions.plist"
cat > "${EXPORT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>destination</key>
	<string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "${ARCHIVE}" \
    -exportOptionsPlist "${EXPORT_PLIST}" \
    -exportPath "${EXPORT_DIR}" \
    | tail -5

APP="${EXPORT_DIR}/${APP_NAME}.app"
[[ -d "${APP}" ]] || { echo "error: export produced no .app at ${APP}" >&2; exit 1; }

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP}"

# ── 3. Notarize ───────────────────────────────────────────────────────────────

if [[ ${NOTARIZE} -eq 1 ]]; then
    log "Notarizing (this uploads the app to Apple and can take a few minutes)"
    ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
    rm -f "${ZIP}"
    ditto -c -k --keepParent "${APP}" "${ZIP}"

    xcrun notarytool submit "${ZIP}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    log "Stapling ticket"
    xcrun stapler staple "${APP}"
    xcrun stapler validate "${APP}"
    rm -f "${ZIP}"
else
    log "Skipping notarization (--no-notarize) — this build will trip Gatekeeper on other Macs"
fi

# ── 4. DMG ────────────────────────────────────────────────────────────────────

log "Building DMG"
STAGE="${BUILD_DIR}/dmg-stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

hdiutil create \
    -volname "Claude Code Remote Server" \
    -srcfolder "${STAGE}" \
    -ov -format UDZO \
    "${DMG}" >/dev/null

rm -rf "${STAGE}"

if [[ ${NOTARIZE} -eq 1 ]]; then
    log "Notarizing the DMG itself so the download is clean"
    xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${DMG}"
fi

log "Done: ${DMG}"
echo ""
echo "  Send testers the DMG. They drag the app to Applications, launch it once,"
echo "  then use the ☁ menu → Configure ngrok… and → Copy Magic Link."
echo ""
