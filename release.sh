#!/bin/bash
#
# DynamicNotch release: archive -> Developer ID export -> notarize -> staple -> DMG ->
# Sparkle appcast. Adapted from WindowSmith's release.sh.
#
# Before running: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in the project, commit,
# and write release-notes/<version>.html (shown in the update window).
#
# Updates are hosted on GitHub Releases of Bauer-Haus/DynamicNotch: each release carries
# the DMG and appcast.xml, and the app reads
#   https://github.com/Bauer-Haus/DynamicNotch/releases/latest/download/appcast.xml
#
# Usage:
#   ./release.sh            build, notarize and sign; print how to publish
#   ./release.sh --publish  also push the commit, tag it and create the GitHub release
#
# One-time setup (already done on this Mac: the same team credentials as WindowSmith):
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" \
#          --apple-id <your-apple-id> --team-id MCKW93H2K7
#      (use an app-specific password from appleid.apple.com, not your account password)
#
# Then: ./release.sh
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

SCHEME="DynamicNotch"
APP_NAME="DynamicNotch"
TEAM_ID="MCKW93H2K7"
# Notary credentials are per team, not per app: WindowSmith's profile works here too.
KEYCHAIN_PROFILE="windowsmith"
# The EdDSA key that signs updates, in the login keychain under this account. Its public
# half is SUPublicEDKey in DynamicNotch/App/Info.plist.
SPARKLE_KEY_ACCOUNT="DynamicNotch"
REPO="Bauer-Haus/DynamicNotch"
GIT_REMOTE="fork"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"

PUBLISH=0
case "${1:-}" in
  --publish) PUBLISH=1 ;;
  "") ;;
  *) echo "Usage: $0 [--publish]" >&2; exit 2 ;;
esac

# Deliberately outside the project. The project used to sit on an iCloud-synced Desktop
# (its folder is now named .nosync to opt out), and the file provider stamped
# com.apple.FinderInfo on bundle directories as they appeared - on the .app,
# Sparkle.framework, its XPC services. codesign rejects that xattr outright, and it came
# back faster than it could be stripped, so a perfectly signed build could not be
# verified anywhere iCloud was watching. Building here keeps that from ever recurring.
BUILD_DIR="$HOME/Library/Caches/DynamicNotch-release"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_STAGE="$BUILD_DIR/dmg"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# notarytool exits 0 even when Apple rejects the upload ("status: Invalid"), so success is
# read from its output, and a rejection prints Apple's reasons straight away.
notarize() {
  local file="$1" label="$2" out id
  out=$(xcrun notarytool submit "$file" --keychain-profile "$KEYCHAIN_PROFILE" --wait 2>&1) || true
  echo "$out"
  if ! echo "$out" | grep -q "status: Accepted"; then
    id=$(echo "$out" | grep -oE "id: [0-9a-f-]{36}" | head -1 | cut -d' ' -f2)
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$KEYCHAIN_PROFILE" 2>&1 \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)
for i in d.get("issues") or []: print("  -", i.get("path","").split(".app/")[-1], ":", i.get("message"))' || true
    fail "$label notarization was not accepted (submission ${id:-unknown}). Apple's reasons are above."
  fi
}

step "Checking for a Developer ID Application certificate"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  fail "No 'Developer ID Application' certificate in the keychain.
  Create one in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application.
  An 'Apple Development' certificate is NOT sufficient for public distribution."
fi
SIGN_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
echo "Using: $SIGN_ID"

# Both notarization passes need this profile. Checking it up front turns a failure
# fifteen minutes into the run - after the archive, export and first notarization -
# into a two-second one.
step "Checking notary credentials"
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  fail "The notary profile '$KEYCHAIN_PROFILE' does not resolve.
  Re-create it with:
    xcrun notarytool store-credentials \"$KEYCHAIN_PROFILE\" --apple-id <your-apple-id> --team-id $TEAM_ID
  Note: an abandoned store-credentials sitting at its prompt will delete this item,
  so make sure no other copy is running first."
fi
echo "Profile '$KEYCHAIN_PROFILE' OK"

step "Cleaning build directory"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

step "Archiving"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  | grep -E "error:|warning:|BUILD|ARCHIVE" || true

# Note: the archive is signed with the automatic (Apple Development) identity. The
# Developer ID re-sign happens in exportArchive, driven by method=developer-id in
# ExportOptions.plist. Forcing CODE_SIGN_IDENTITY here conflicts with automatic signing.

[ -d "$ARCHIVE" ] || fail "Archive was not produced."

step "Exporting a Developer ID build"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$PROJECT_DIR/ExportOptions.plist"

APP="$EXPORT_DIR/$APP_NAME.app"
[ -d "$APP" ] || fail "Export did not produce $APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD_NUM=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
echo "Version $VERSION (build $BUILD_NUM)"

# Belt and braces alongside building outside iCloud: extended attributes are not part
# of the signature, so clearing them costs nothing and codesign refuses to look past
# even one of them.
step "Stripping extended attributes"
xattr -cr "$APP"

# Prebuilt helpers copied in as resources (MediaRemoteAdapterTestClient, which checks the
# Now Playing source still works) are re-signed by the export without the hardened runtime,
# and notarization rejects any executable without it. Sign them with it, then re-seal the
# app over them, keeping its entitlements.
step "Signing bundled helpers with the hardened runtime"
RESIGNED=0
while IFS= read -r helper; do
  file -b "$helper" | grep -q "Mach-O" || continue
  codesign -dv "$helper" 2>&1 | grep -q "(runtime)" && continue
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$helper"
  echo "Signed ${helper#"$APP"/}"
  RESIGNED=1
done < <(find "$APP/Contents/Resources" -type f -perm +111)
if [ "$RESIGNED" = 1 ]; then
  ENTITLEMENTS_FILE="$BUILD_DIR/app-entitlements.plist"
  codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS_FILE" 2>/dev/null
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_FILE" --sign "$SIGN_ID" "$APP"
fi
UNHARDENED=$(find "$APP/Contents" -type f -perm +111 -exec sh -c \
  'file -b "$1" | grep -q Mach-O && ! codesign -dv "$1" 2>&1 | grep -q "(runtime)" && echo "$1"' _ {} \;)
[ -z "$UNHARDENED" ] || fail "Executables without the hardened runtime (notarization would reject them):
$UNHARDENED"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "Authority|flags" || true

# DynamicNotch is sandboxed, and Sparkle can only install an update into a sandboxed app
# through its installer XPC service, which needs these two mach-lookup exceptions and
# SUEnableInstallerLauncherService. Without them the update downloads and then fails to
# install. Verify the shipped artifact, not the settings.
step "Verifying the sandbox and Sparkle's installer access"
ENTITLEMENTS=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
echo "$ENTITLEMENTS" | grep -q "com.apple.security.app-sandbox" \
  || fail "The exported app is not sandboxed. Refusing to ship."
for service in "$BUNDLE_ID-spks" "$BUNDLE_ID-spki"; do
  echo "$ENTITLEMENTS" | grep -q "<string>$service</string>" \
    || fail "Missing the mach-lookup exception for $service; Sparkle could not install updates."
done
[ "$(/usr/libexec/PlistBuddy -c "Print :SUEnableInstallerLauncherService" "$APP/Contents/Info.plist" 2>/dev/null)" = "true" ] \
  || fail "SUEnableInstallerLauncherService is not set; Sparkle could not install updates."
APP_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
[ -n "$APP_KEY" ] || fail "SUPublicEDKey is missing from the app's Info.plist."
APP_FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true)
[ "$APP_FEED" = "$FEED_URL" ] || fail "The app's SUFeedURL is '$APP_FEED', not $FEED_URL.
  Installed copies would never see this release's updates."
echo "Sandboxed, with Sparkle's installer service enabled (bundle $BUNDLE_ID)."

# The app gets its own notarization pass so the ticket can be stapled directly to the
# bundle. Stapling only the DMG leaves the app ticketless once it is dragged out, which
# means a first launch with no network has to fail open on a Gatekeeper lookup it cannot
# perform. Two passes, two waits, but the app works offline out of the box.
step "Notarizing the app (pass 1 of 2 — a few minutes)"
APP_ZIP="$BUILD_DIR/$APP_NAME-app.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP" "App"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Building the DMG"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
# diskutil rather than hdiutil, whose create is deprecated from macOS 27. The result is
# the same image: compressed UDZO holding one APFS volume, overwriting any older file.
diskutil image create from \
  --format UDZO \
  --volumeName "$APP_NAME" \
  "$DMG_STAGE" \
  "$DMG"

step "Signing the DMG"
codesign --sign "$SIGN_ID" --timestamp "$DMG"

step "Notarizing the DMG (pass 2 of 2 — a few minutes)"
notarize "$DMG" "DMG"

step "Stapling the ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

step "Gatekeeper check"
spctl -a -vvv -t open --context context:primary-signature "$DMG" || true

# Sparkle's appcast is the feed installed copies poll. generate_appcast reads the
# version out of the app inside the DMG and signs the entry with the EdDSA private
# key in the login keychain - the same key whose public half is in Info.plist.
step "Generating the Sparkle appcast"
# The tools come with the Sparkle package Xcode downloaded, in this project's DerivedData
# folder - the one the archive above was built in. Xcode is asked where that is: its
# location is a preference (here it is DerivedData.noindex), and the default folder still
# holds one DynamicNotch-* copy, with its own old Sparkle, for every place the project has
# lived. The tools must also be the Sparkle the app was just built against.
PROJECT_FILE="$PROJECT_DIR/$APP_NAME.xcodeproj"
BUILD_ROOT=$(xcodebuild -showBuildSettings -project "$PROJECT_FILE" -scheme "$SCHEME" 2>/dev/null \
  | awk -F' = ' '$1 ~ /^ *BUILD_ROOT$/ { print $2; exit }')
SPARKLE_BIN="${BUILD_ROOT%/Build/Products}/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [ -z "$BUILD_ROOT" ] || [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  fail "Sparkle's tools are missing. Build the app once in Xcode to fetch them, then re-run."
fi
# Found by name: Sparkle isn't the first package here, as it is in WindowSmith.
PINNED_SPARKLE=$(python3 -c 'import json,sys; print(next(p["state"]["version"] for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "sparkle"))' \
  "$PROJECT_FILE/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
TOOLS_SPARKLE=$(plutil -extract CFBundleShortVersionString raw \
  "$SPARKLE_BIN"/../Sparkle.xcframework/macos-*/Sparkle.framework/Versions/B/Resources/Info.plist)
[ "$TOOLS_SPARKLE" = "$PINNED_SPARKLE" ] || fail "Sparkle's tools are $TOOLS_SPARKLE but the app pins $PINNED_SPARKLE.
  Open the project in Xcode so it fetches $PINNED_SPARKLE, then re-run."
echo "Using Sparkle $TOOLS_SPARKLE tools"

APPCAST_DIR="$BUILD_DIR/appcast"
mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"

# generate_appcast embeds release notes from an .html file named after the archive.
# Without one the update dialog shows a version number and nothing else.
NOTES="$PROJECT_DIR/release-notes/$VERSION.html"
if [ -f "$NOTES" ]; then
  cp "$NOTES" "$APPCAST_DIR/$APP_NAME-$VERSION.html"
  echo "Including release notes from release-notes/$VERSION.html"
else
  echo "WARNING: no release-notes/$VERSION.html - the update dialog will have no description."
fi
# The signing key must be the one the app trusts, or installed copies reject the update.
KEY_PUBLIC=$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p 2>/dev/null || true)
[ "$KEY_PUBLIC" = "$APP_KEY" ] || fail "The keychain's '$SPARKLE_KEY_ACCOUNT' key ($KEY_PUBLIC) is not the app's SUPublicEDKey ($APP_KEY)."
"$SPARKLE_BIN/generate_appcast" \
  --account "$SPARKLE_KEY_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO/releases/tag/v$VERSION" \
  "$APPCAST_DIR"

APPCAST="$APPCAST_DIR/appcast.xml"
[ -f "$APPCAST" ] || fail "generate_appcast did not produce $APPCAST"

# generate_appcast silently omits the EdDSA signature when the app inside the archive
# has no SUPublicEDKey. An unsigned entry would ship an update installed copies cannot
# verify, so treat a missing signature as a hard failure rather than a warning.
if ! grep -q "sparkle:edSignature" "$APPCAST"; then
  fail "The appcast entry has no sparkle:edSignature.
  The app inside the DMG is probably missing SUPublicEDKey in its Info.plist,
  or the EdDSA private key is not in this machine's login keychain."
fi

echo "Signed entry:"
grep -E "sparkle:version|sparkle:edSignature|<enclosure" "$APPCAST" | sed 's/^[[:space:]]*/  /'

# Copied back into the project purely so the release artifacts sit where they always
# have. Everything is notarized and stapled by this point, so whatever iCloud stamps on
# the copies is of no consequence.
step "Copying the artifacts into the project"
mkdir -p "$PROJECT_DIR/build"
cp "$DMG" "$APPCAST" "$PROJECT_DIR/build/"
echo "$PROJECT_DIR/build/$(basename "$DMG")"
echo "$PROJECT_DIR/build/appcast.xml"

DMG_MB=$(awk -v bytes="$(stat -f%z "$DMG")" 'BEGIN { printf "%.1f", bytes / 1000000 }')
printf '\n\033[1;32mBuilt: %s (%s MB)\033[0m\n' "$DMG" "$DMG_MB"

# Publishing is public and can't be quietly undone, so it only happens when asked for.
if [ "$PUBLISH" != 1 ]; then
  cat <<NEXT

Not published. To publish this build as a GitHub Release, run:

  ./release.sh --publish

(or by hand: push $GIT_REMOTE, tag v$VERSION, and create the release with
 $(basename "$DMG") and appcast.xml attached; installed copies read appcast.xml
 from the latest release.)
NEXT
  exit 0
fi

step "Publishing v$VERSION on GitHub"
command -v gh >/dev/null || fail "The GitHub CLI (gh) is needed to publish."
[ -z "$(git status --porcelain)" ] || fail "Uncommitted changes; commit them so the tag matches what was built."
COMMIT=$(git rev-parse HEAD)
git push "$GIT_REMOTE" HEAD:main
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  [ "$(git rev-list -n1 "v$VERSION")" = "$COMMIT" ] || fail "Tag v$VERSION already exists on a different commit."
else
  git tag -a "v$VERSION" -m "DynamicNotch $VERSION (build $BUILD_NUM), released $(date +%Y-%m-%d)"
fi
git push "$GIT_REMOTE" "v$VERSION"
gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 \
  && fail "A GitHub release v$VERSION already exists. Delete it or bump the version."
NOTES_ARGS=(--notes "DynamicNotch $VERSION (build $BUILD_NUM)")
[ -f "$NOTES" ] && NOTES_ARGS=(--notes-file "$NOTES")
gh release create "v$VERSION" "$DMG" "$APPCAST" \
  --repo "$REPO" --title "DynamicNotch $VERSION" --latest "${NOTES_ARGS[@]}"

# What installed copies will actually fetch: the feed must resolve and name this build.
step "Checking the published feed"
FEED=$(curl -fsSL "$FEED_URL") || fail "Could not fetch $FEED_URL"
echo "$FEED" | grep -q "<sparkle:version>$BUILD_NUM</sparkle:version>" \
  || fail "The published feed doesn't list build $BUILD_NUM."
curl -fsIL "https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")" >/dev/null \
  || fail "The DMG download link doesn't resolve."
printf '\n\033[1;32mPublished: https://github.com/%s/releases/tag/v%s\033[0m\n' "$REPO" "$VERSION"
echo "Installed copies will offer $VERSION at their next check (daily, or Check for Updates…)."
