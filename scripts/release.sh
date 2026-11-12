#!/usr/bin/env bash
# Builds, signs (locally) and packages a release into dist/ (SPEC 12.9.5, 13.1). No network, no upload.
# Usage: [VOLUME_SIGN_IDENTITY="<certificate name>"] scripts/release.sh <version>
# Without VOLUME_SIGN_IDENTITY (or with "-") the app is signed ad hoc (SPEC 13.2).
# Refuses to run when: the working tree is not clean, tag v<version> does not exist, is not an
# annotated tag (git tag -a) or does not point at HEAD, or <version> differs from Resources/Version.
set -euo pipefail

cd "$(dirname "$0")/.."

die() { echo "release: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: scripts/release.sh <version>  (e.g. 1.0.0)"
VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version '$VERSION' (expected MAJOR.MINOR.PATCH)"
TAG="v$VERSION"

export VOLUME_SIGN_IDENTITY="${VOLUME_SIGN_IDENTITY:--}"
if [ "$VOLUME_SIGN_IDENTITY" = "-" ]; then
  echo "release: no VOLUME_SIGN_IDENTITY: signing AD HOC (users must grant the audio permission again after each update)" >&2
fi

# Includes ignored files, but only in the folders that go into the build (a stray ignored
# Sources/**/build/X.swift would be compiled into the release).
[ -z "$(git status --porcelain --ignored -- Sources Package.swift Resources scripts)" ] \
  || die "uncommitted or ignored files in the build folders; commit or remove them first"
[ -z "$(git status --porcelain)" ] || die "uncommitted changes in the working tree; commit first"
HEAD_COMMIT="$(git rev-parse HEAD)"
TAG_COMMIT="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")" || die "tag $TAG does not exist"
[ "$TAG_COMMIT" = "$HEAD_COMMIT" ] || die "tag $TAG does not point at HEAD"
[ "$(git cat-file -t "refs/tags/$TAG")" = "tag" ] || die "tag $TAG is not annotated; create it with git tag -a (docs/RELEASE.md)"
FILE_VERSION="$(sed -n 's/^VERSION=//p' Resources/Version)"
[ "$FILE_VERSION" = "$VERSION" ] || die "Resources/Version says $FILE_VERSION; set it to $VERSION and commit/tag again"

NAME="Volume-Manager-$VERSION"
VOLNAME="Volume Manager"
DIST="dist"
APP_NAME="Volume Manager.app"
APP="build/$APP_NAME"
DMG="$DIST/$NAME.dmg"
ZIP="$DIST/$NAME.zip"

if [ -e "/Volumes/$VOLNAME" ]; then die "a volume named '$VOLNAME' is already mounted; eject it first"; fi

WORK="$(mktemp -d)"
MOUNT_POINTS=()
cleanup() {
  local m
  for m in ${MOUNT_POINTS[@]+"${MOUNT_POINTS[@]}"}; do hdiutil detach "$m" -force >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> build ($VERSION, identity: $VOLUME_SIGN_IDENTITY)"
scripts/build-app.sh

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> staging the DMG contents"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
swift scripts/make-dmg-background.swift "$STAGE/.background/background.png"

echo "==> creating $DMG"
RW_DMG="$WORK/rw.dmg"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW_DMG"
# Window layout (background, icon positions) is stored by Finder in .DS_Store. macOS may ask
# once to let Terminal control Finder; allow it (docs/RELEASE.md).
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "/Volumes/$VOLNAME" "$RW_DMG" >/dev/null
MOUNT_POINTS+=("/Volumes/$VOLNAME")
osascript <<OSA || die "Finder layout failed (allow Terminal to control Finder, then run again)"
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.png"
    set position of item "$APP_NAME" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
sync
hdiutil detach -quiet "/Volumes/$VOLNAME"
MOUNT_POINTS=()
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG"

echo "==> verifying the app inside the DMG (the artifact users receive)"
VERIFY_MOUNT="$WORK/verify"
mkdir -p "$VERIFY_MOUNT"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$VERIFY_MOUNT" "$DMG" >/dev/null
MOUNT_POINTS+=("$VERIFY_MOUNT")
[ -d "$VERIFY_MOUNT/$APP_NAME" ] || die "DMG does not contain $APP_NAME"
[ -L "$VERIFY_MOUNT/Applications" ] || die "DMG does not contain the Applications shortcut"
[ -f "$VERIFY_MOUNT/.background/background.png" ] || die "DMG does not contain the background image"
cmp "$APP/Contents/MacOS/VolumeManager" "$VERIFY_MOUNT/$APP_NAME/Contents/MacOS/VolumeManager" \
  || die "binary inside the DMG differs from the built one"
VOLUME_APP="$VERIFY_MOUNT/$APP_NAME" scripts/security-check.sh --app || die "security-check failed on the app inside the DMG"
codesign -d -r- "$VERIFY_MOUNT/$APP_NAME" 2>&1 | sed -n 's/^# designated => /designated requirement: /p'
hdiutil detach -quiet "$VERIFY_MOUNT"
MOUNT_POINTS=()

echo "==> zip and checksums"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)
(cd "$DIST" && shasum -a 256 -c SHA256SUMS)

echo
echo "release: OK ($TAG, commit ${HEAD_COMMIT:0:12})"
cat "$DIST/SHA256SUMS"
echo
echo "Upload manually to https://github.com/eduardo-toste/volume-manager/releases (tag $TAG):"
echo "  $DMG"
echo "  $ZIP"
echo "  $DIST/SHA256SUMS   (also paste its contents in the release notes)"
