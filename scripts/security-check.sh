#!/usr/bin/env bash
# Security checks of SPEC 12.9.7. Exits non-zero on ANY violation.
# Usage: scripts/security-check.sh [--app]
#   --app  require the built bundle (build/Volume Manager.app, or $VOLUME_APP) and fail if it is missing.
#          Without it, binary checks are skipped with a warning when the bundle does not exist.
#
# Search scope: tracked project files only. These are deliberately EXCLUDED from the searches:
#   .build/ and build/ (build products, third-party checkouts) and .git/.
set -uo pipefail

cd "$(dirname "$0")/.."

REQUIRE_APP=0
for arg in "$@"; do
  case "$arg" in
    --app) REQUIRE_APP=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

APP="${VOLUME_APP:-build/Volume Manager.app}"
FAILURES=0

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "ok:   $*"; }

# Project files to search (excludes build output and VCS data).
project_find() {
  find . \( -path ./.build -o -path ./build -o -path ./.git \) -prune -o "$@" -print
}

# ---------------------------------------------------------------- 3. forbidden APIs in Sources/
echo "== static analysis of Sources/"
SWIFT_FILES=()
while IFS= read -r f; do SWIFT_FILES+=("$f"); done < <(find Sources -name '*.swift' 2>/dev/null)

# pattern<TAB>description. Patterns avoid false positives such as Font.system( or blueprint(.
FORBIDDEN=(
  'URLSession@@URLSession'
  'NWConnection@@NWConnection'
  'import Network@@Network.framework'
  '(^|[^A-Za-z0-9_.])socket[[:space:]]*\(@@socket('
  'CFSocket@@CFSocket'
  'dlopen@@dlopen'
  'dlsym@@dlsym'
  'NSAppleScript@@NSAppleScript'
  '(^|[^A-Za-z0-9_])Process[[:space:]]*\(@@Process('
  '(^|[^A-Za-z0-9_.])system[[:space:]]*\(@@system('
  '(Glibc|Darwin)\.system[[:space:]]*\(@@Darwin.system('
  '(^|[^A-Za-z0-9_])popen@@popen'
  'AudioFileCreate@@AudioFileCreate'
  'ExtAudioFile@@ExtAudioFile'
  'AVAudioRecorder@@AVAudioRecorder'
  'AVAudioFile@@AVAudioFile'
  '(^|[^A-Za-z0-9_])try[[:space:]]*!@@try!'
  '(^|[^A-Za-z0-9_.])debugPrint[[:space:]]*\(@@debugPrint('
  '(^|[^A-Za-z0-9_.])NSLog[[:space:]]*\(@@NSLog('
  '(^|[^A-Za-z0-9_.])dump[[:space:]]*\(@@dump('
  '(^|[^A-Za-z0-9_])as[[:space:]]*!@@as!'
  '@_silgen_name@@@_silgen_name'
  'posix_spawn@@posix_spawn'
  'NSTask@@NSTask'
  '(^|[^A-Za-z0-9_])exec[lv][a-z]*[[:space:]]*\(@@execv/execl family'
  '(^|[^A-Za-z0-9_.])v?fork[[:space:]]*\(@@fork/vfork'
  'NSURLConnection@@NSURLConnection'
  'import[[:space:]]+CFNetwork@@CFNetwork'
  'CFStream@@CFStream'
  'CFReadStream@@CFReadStream'
  'CFWriteStream@@CFWriteStream'
  'CFHTTP@@CFHTTP'
  'NWPathMonitor@@NWPathMonitor'
  'NWListener@@NWListener'
  'URLRequest@@URLRequest'
)
for entry in "${FORBIDDEN[@]}"; do
  pattern="${entry%%@@*}"; label="${entry#*@@}"
  if [ "${#SWIFT_FILES[@]}" -gt 0 ] && hits="$(grep -nE -- "$pattern" "${SWIFT_FILES[@]}")"; then
    fail "forbidden API '$label' in Sources/:"; echo "$hits" >&2
  fi
done
PRINT_FILES=()
for f in ${SWIFT_FILES[@]+"${SWIFT_FILES[@]}"}; do
  case "$f" in Sources/vmctl/*) ;; *) PRINT_FILES+=("$f") ;; esac
done
# Console output is only allowed in Sources/vmctl (terminal tool, not shipped). Covers calls,
# the Swift. prefix and bare references (e.g. "let p = print").
NON_VMCTL=(
  '(^|[^A-Za-z0-9_.])(Swift\.)?(print|debugPrint|dump)([^A-Za-z0-9_]|$)@@print/debugPrint/dump (also Swift.-prefixed or as a reference)'
  '(^|[^A-Za-z0-9_])(fputs|fprintf)[[:space:]]*\(@@fputs/fprintf'
  'FileHandle[[:space:]]*\.[[:space:]]*standard(Output|Error)@@FileHandle.standardOutput/standardError'
)
for entry in "${NON_VMCTL[@]}"; do
  pattern="${entry%%@@*}"; label="${entry#*@@}"
  if [ "${#PRINT_FILES[@]}" -gt 0 ] && hits="$(grep -nE -- "$pattern" "${PRINT_FILES[@]}")"; then
    fail "$label is only allowed in Sources/vmctl (use os.Logger):"; echo "$hits" >&2
  fi
done

# C / Objective-C sources only inside Sources/CSystemShims.
stray="$(project_find -type f \( -name '*.c' -o -name '*.h' -o -name '*.m' -o -name '*.mm' -o -name '*.cpp' -o -name '*.cc' -o -name '*.hpp' \) | grep -v '^./Sources/CSystemShims/' || true)"
[ -n "$stray" ] && fail "C/Objective-C files outside Sources/CSystemShims:" && echo "$stray" >&2
# The shim target may only contain the single weak_import declaration of the one allowed private
# API, and no logic. Comments are stripped before checking so they cannot satisfy the rules.
strip_c_comments() { /usr/bin/perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$@"; }
if [ -d Sources/CSystemShims ]; then
  header_code="$(strip_c_comments Sources/CSystemShims/include/*.h)"
  extra="$(grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' <<<"$header_code" | tr -d ' \t' | sort -u | grep -vxE '__attribute__\(|responsibility_get_pid_responsible_for_pid\(' || true)"
  [ -n "$extra" ] && fail "CSystemShims declares more than the allowed private API: $extra"
  grep -qE '__attribute__[[:space:]]*\([[:space:]]*\([[:space:]]*weak_import[[:space:]]*\)[[:space:]]*\)' <<<"$header_code" \
    || fail "CSystemShims.h must declare the API with __attribute__((weak_import)) (comments do not count)"
  for c_file in Sources/CSystemShims/*.c; do
    [ -f "$c_file" ] || continue
    if [ -n "$(strip_c_comments "$c_file" | tr -d '[:space:]')" ]; then
      fail "$c_file must contain only comments (the shim target has no logic)"
    fi
  done
fi

# 8. Logger interpolation without privacy:
if [ "${#SWIFT_FILES[@]}" -gt 0 ]; then
  log_hits="$(/usr/bin/perl -e '
    # Any log-level call (whatever the variable is named) whose message has more "\(" interpolations than "privacy:" annotations.
    for my $file (@ARGV) {
      open(my $fh, "<", $file) or next;
      my @lines = <$fh>; close $fh;
      for (my $i = 0; $i < @lines; $i++) {
        next unless $lines[$i] =~ /\.\s*(debug|info|notice|warning|error|fault|critical|trace|log)\s*\(/;
        my $stmt = $lines[$i]; my $depth = 0; my $j = $i;
        while (1) {
          $depth += () = $lines[$j] =~ /\(/g; $depth -= () = $lines[$j] =~ /\)/g;
          last if $depth <= 0 || $j + 1 >= @lines;
          $j++; $stmt .= $lines[$j];
        }
        my $interp = () = $stmt =~ /\\\(/g;
        my $priv = () = $stmt =~ /privacy:/g;
        print "$file:" . ($i + 1) . ": $interp interpolation(s), $priv privacy annotation(s)\n" if $interp > $priv;
      }
    }
  ' "${SWIFT_FILES[@]}")"
  [ -n "$log_hits" ] && fail "Logger interpolation without privacy: annotation:" && echo "$log_hits" >&2
fi
[ "$FAILURES" -eq 0 ] && pass "Sources/ static analysis"

# ---------------------------------------------------------------- 4. secrets
echo "== secrets"
SECRET_START=$FAILURES
secret_files="$(project_find -type f \( -name '*.p12' -o -name '*.pfx' -o -name '*.pem' -o -name '*.key' -o -name '*.cer' -o -name '*.mobileprovision' -o -name '*.keychain*' -o -name '.env' -o -name 'id_rsa*' -o -name 'id_ed25519*' \))"
[ -n "$secret_files" ] && fail "secret-like files in the repository:" && echo "$secret_files" >&2
text_files="$(project_find -type f ! -name '*.png' ! -name '*.figcraft' ! -name '*.icns' ! -name 'security-check.sh')"
if [ -n "$text_files" ]; then
  secret_hits="$(echo "$text_files" | tr '\n' '\0' | xargs -0 grep -IlE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{32,}' 2>/dev/null)"
  [ -n "$secret_hits" ] && fail "possible secrets in:" && echo "$secret_hits" >&2
fi
[ "$FAILURES" -eq "$SECRET_START" ] && pass "no secrets found"

# ---------------------------------------------------------------- 7. dependencies
echo "== dependencies"
DEP_START=$FAILURES
# Zero external dependencies, no exception (CLAUDE.md rule 2). Count by the resolved manifest
# (dump-package) AND by textual occurrences; the larger number counts.
manifest_json="$(swift package dump-package 2>/dev/null)"
pkg_count="$(plutil -extract dependencies raw -o - - <<<"$manifest_json" 2>/dev/null || echo bad)"
text_count="$(grep -o '\.package[[:space:]]*(' Package.swift | wc -l | tr -d ' ')"
if ! [[ "$pkg_count" =~ ^[0-9]+$ ]]; then
  fail "could not read the dependency list with 'swift package dump-package'"
  pkg_count=99
elif [ "$text_count" -gt "$pkg_count" ]; then
  pkg_count="$text_count"
fi
[ "$pkg_count" -eq 0 ] || fail "Package.swift declares $pkg_count dependencies (none are allowed)"
# A binary target is a download in disguise (it also brings code the project did not write).
if grep -Eq 'binaryTarget|url:' Package.swift; then
  fail "Package.swift has a binaryTarget or a url: (no downloaded or prebuilt code is allowed)"
fi
if [ -f Package.resolved ]; then
  fail "Package.resolved exists (there must be no dependencies, so no resolved file)"
fi
[ "$FAILURES" -eq "$DEP_START" ] && pass "dependencies (zero)"

# ---------------------------------------------------------------- 1,6. source-level plist/entitlements
# Allowlist is empty (SPEC 12.9.2): the app needs no entitlement, so any key is a failure.
check_entitlements_text() { # $1 = entitlements plist text, $2 = origin
  local keys
  keys="$(grep -oE '<key>[^<]*</key>' <<<"$1" | sed -E 's/<\/?key>//g' || true)"
  [ -z "$keys" ] || fail "entitlements present in $2 (none are allowed): $(tr '\n' ' ' <<<"$keys")"
}
check_usage_descriptions() { # $1 = plist, $2 = origin
  local keys
  keys="$(plutil -convert xml1 -o - "$1" | grep -oE '<key>NS[A-Za-z]*UsageDescription</key>' | sed -E 's/<\/?key>//g' | grep -vx 'NSAudioCaptureUsageDescription' || true)"
  [ -n "$keys" ] && fail "extra permission descriptions in $2: $keys"
  plutil -extract NSAudioCaptureUsageDescription raw -o - "$1" >/dev/null 2>&1 || fail "NSAudioCaptureUsageDescription missing in $2"
}
echo "== Resources/"
RES_START=$FAILURES
for ent in Resources/*.entitlements; do
  [ -f "$ent" ] && check_entitlements_text "$(cat "$ent")" "$ent"
done
[ -f Resources/Info.plist ] && check_usage_descriptions Resources/Info.plist Resources/Info.plist
[ "$FAILURES" -eq "$RES_START" ] && pass "entitlements and Info.plist sources"

# ---------------------------------------------------------------- binary checks on the bundle
echo "== bundle ($APP)"
if [ ! -d "$APP" ]; then
  if [ "$REQUIRE_APP" -eq 1 ]; then
    fail "bundle $APP not found (run scripts/build-app.sh)"
  else
    echo "warn: $APP not found; skipping binary checks (run scripts/build-app.sh and use --app)" >&2
  fi
else
  APP_START=$FAILURES
  # 1. entitlements of the signed app
  ents="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
  check_entitlements_text "$ents" "$APP (signed)"
  # 2. Hardened Runtime + valid signature
  cs_flags="$(codesign -dv "$APP" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\).*/\1/p' | head -1)"
  if [ -z "$cs_flags" ] || [ $((cs_flags & 0x10000)) -eq 0 ]; then
    fail "Hardened Runtime (flag 0x10000) is not enabled on $APP (flags: ${cs_flags:-none})"
  fi
  codesign --verify --strict --deep "$APP" 2>/dev/null || fail "codesign --verify --strict --deep failed for $APP"
  # 5. no vmctl, no third-party code
  [ -n "$(find "$APP" -name 'vmctl*')" ] && fail "vmctl found inside the bundle"
  [ -n "$(find "$APP" \( -name '*.dylib' -o -name '*.framework' -o -name '*.so' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' \))" ] \
    && fail "unexpected dylib/framework/plugin in the bundle: $(find "$APP" \( -name '*.dylib' -o -name '*.framework' -o -name '*.so' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' \) | tr '\n' ' ')"
  extra_macos="$(ls "$APP/Contents/MacOS" 2>/dev/null | grep -vx 'VolumeManager' || true)"
  [ -n "$extra_macos" ] && fail "unexpected executables in Contents/MacOS: $extra_macos"
  [ -d "$APP/Contents/Frameworks" ] && fail "Contents/Frameworks must not exist"
  bad_libs="$(otool -L "$APP/Contents/MacOS/VolumeManager" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/Library/|/usr/lib/)' || true)"
  [ -n "$bad_libs" ] && fail "binary links libraries from outside the system: $bad_libs"
  # 7. compiled strings equal the catalog (catches double UTF-8 encoding: "saÃ­da"); the UI is
  #    pt-BR, so a bundle without it fails instead of skipping the check
  [ -f "$APP/Contents/Resources/pt-BR.lproj/Localizable.strings" ] \
    || fail "missing $APP/Contents/Resources/pt-BR.lproj/Localizable.strings"
  for lproj in "$APP"/Contents/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    lang="$(basename "$lproj" .lproj)"
    plutil -convert json -o - "$lproj/Localizable.strings" 2>/dev/null \
      | /usr/bin/perl -MJSON::PP -e '
          my ($lang, $catalog) = @ARGV;
          local $/;
          my $json = JSON::PP->new->utf8;
          my $got = $json->decode(<STDIN>);
          open(my $fh, "<:raw", $catalog) or die "cannot read $catalog\n";
          my $strings = $json->decode(<$fh>)->{strings};
          my $bad = 0;
          for my $key (keys %$strings) {
            my $unit = ($strings->{$key}{localizations} // {})->{$lang} or next;
            my $want = $unit->{stringUnit}{value};
            if (!defined $got->{$key} || $got->{$key} ne $want) { print "mismatch: $key\n"; $bad++ }
          }
          for my $key (keys %$got) {
            my $unit = ($strings->{$key}{localizations} // {})->{$lang};
            if (!$unit) { print "extra key: $key\n"; $bad++ }
          }
          for my $value (values %$got) { if ($value =~ /[\x{C2}\x{C3}][\x{80}-\x{BF}]/) { print "mojibake: $value\n"; $bad++ } }
          exit($bad ? 1 : 0);
        ' "$lang" Resources/Localizable.xcstrings \
      || fail "$lproj/Localizable.strings does not match Resources/Localizable.xcstrings"
  done
  # 6. permission descriptions
  check_usage_descriptions "$APP/Contents/Info.plist" "$APP/Contents/Info.plist"
  [ "$FAILURES" -eq "$APP_START" ] && pass "bundle checks"
fi

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "security-check: FAILED ($FAILURES violation(s))" >&2
  exit 1
fi
echo "security-check: OK"
