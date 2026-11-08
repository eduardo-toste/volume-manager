#!/usr/bin/env bash
# Builds build/Volume.app (release), signs with Hardened Runtime and verifies the signature.
# Signing identity: $VOLUME_SIGN_IDENTITY, otherwise ad-hoc ("-", development only; SPEC 13.2).
# vmctl is a development tool and is NEVER copied into the bundle (SPEC 12.9.6).
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Volume.app"
IDENTITY="${VOLUME_SIGN_IDENTITY:--}"
# Only this warning may be ignored: harmless Command Line Tools linker noise.
IGNORED_WARNING='ld: warning: search path .* not found'

# Single source of truth for the version.
VERSION="$(sed -n 's/^VERSION=//p' Resources/Version)"
BUILD="$(sed -n 's/^BUILD=//p' Resources/Version)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-app: invalid VERSION '$VERSION'" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "build-app: invalid BUILD '$BUILD'" >&2; exit 1; }

echo "==> swift build -c release"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
if ! swift build -c release --product VolumeManager >"$LOG" 2>&1; then
  grep -Ev "$IGNORED_WARNING" "$LOG" >&2
  exit 1
fi
if grep -E 'warning:' "$LOG" | grep -Ev "$IGNORED_WARNING" >&2; then
  echo "build-app: release build produced warnings" >&2
  exit 1
fi
BIN_DIR="$(swift build -c release --show-bin-path 2>/dev/null)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VolumeManager" "$APP/Contents/MacOS/VolumeManager"
strip -x "$APP/Contents/MacOS/VolumeManager"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Compile Localizable.xcstrings into <lang>.lproj/Localizable.strings. The catalog is UTF-8:
# it is decoded with ->utf8 (bytes to characters) and written back as UTF-8, so accented text
# is not encoded twice. security-check.sh --app compares the result with the catalog.
# Only simple string units are supported.
/usr/bin/perl -MJSON::PP -e '
  use strict; use warnings;
  my ($src, $out) = @ARGV;
  open(my $fh, "<:raw", $src) or die "cannot read $src";
  my $catalog = JSON::PP->new->utf8->decode(do { local $/; <$fh> });
  my %langs;
  for my $key (sort keys %{ $catalog->{strings} }) {
    my $locs = $catalog->{strings}{$key}{localizations} // {};
    for my $lang (keys %$locs) {
      my $unit = $locs->{$lang}{stringUnit} or die "unsupported localization for $key/$lang";
      my $v = $unit->{value}; my $k = $key;
      for ($v, $k) { s/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; }
      push @{ $langs{$lang} }, "\"$k\" = \"$v\";\n";
    }
  }
  for my $lang (keys %langs) {
    my $dir = "$out/$lang.lproj";
    mkdir $dir or die "mkdir $dir" unless -d $dir;
    open(my $o, ">:utf8", "$dir/Localizable.strings") or die;
    print $o @{ $langs{$lang} };
    close $o;
  }
' Resources/Localizable.xcstrings "$APP/Contents/Resources"

echo "==> codesign (Hardened Runtime, identity: $IDENTITY)"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/VolumeManager.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "build-app: OK -> $APP ($VERSION build $BUILD)"
