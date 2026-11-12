#!/usr/bin/env bash
# Quality gate (SPEC 12.7): format lint + warning-free build + tests + security checks.
# Usage: scripts/check.sh [--audio] [--app]
#   --audio  also run tests tagged .audioHardware (SPEC 12.8.1); skipped by default.
#   --app    also build the release bundle (scripts/build-app.sh) and run the binary security
#            checks on it (security-check.sh --app). Slower, so opt-in.
set -uo pipefail

cd "$(dirname "$0")/.."

RUN_AUDIO=0
RUN_APP=0
for arg in "$@"; do
  case "$arg" in
    --audio) RUN_AUDIO=1 ;;
    --app) RUN_APP=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# The Command Line Tools toolchain prints harmless "ld: warning: search path ... not found"
# lines. They are the ONLY warnings that may be ignored.
# Only this warning may be ignored: harmless Command Line Tools linker noise.
IGNORED_WARNING='ld: warning: search path .* not found'

# Runs a command, echoes its output without the ignored warnings, and fails on the command's
# exit status or on any other "warning:" line.
run_strict() {
  local label="$1"; shift
  local log status
  log="$(mktemp)"
  "$@" >"$log" 2>&1
  status=$?
  grep -Ev "$IGNORED_WARNING" "$log" | sed $'s/\x1b\\[[0-9;]*m//g'
  local warnings
  warnings="$(sed $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -E 'warning:' | grep -Ev "$IGNORED_WARNING" || true)"
  rm -f "$log"
  if [ "$status" -ne 0 ]; then
    echo "check: FAILED: $label (exit $status)" >&2
    exit "$status"
  fi
  if [ -n "$warnings" ]; then
    echo "check: FAILED: $label produced warnings (zero warnings required):" >&2
    echo "$warnings" >&2
    exit 1
  fi
}

TEST_FLAGS=()
# With only the Command Line Tools (no Xcode) Swift Testing's macro plugin lives outside the
# default search path. With Xcode installed the directory is absent and nothing is added.
CLT_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT_PLUGINS" ]; then
  TEST_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$CLT_PLUGINS")
fi

echo "==> swift format lint"
run_strict "swift format lint" swift format lint --strict -r Sources Tests

echo "==> swift build"
run_strict "swift build" swift build

echo "==> swift test"
if [ "$RUN_AUDIO" -eq 1 ]; then
  export VOLUME_AUDIO_TESTS=1
else
  unset VOLUME_AUDIO_TESTS
fi
run_strict "swift test" swift test ${TEST_FLAGS[@]+"${TEST_FLAGS[@]}"}

if [ "$RUN_APP" -eq 1 ]; then
  echo "==> build-app"
  scripts/build-app.sh || { echo "check: FAILED: build-app" >&2; exit 1; }
  echo "==> security-check --app"
  scripts/security-check.sh --app || { echo "check: FAILED: security-check --app" >&2; exit 1; }
else
  echo "==> security-check (source checks only; use --app for the bundle)"
  scripts/security-check.sh || { echo "check: FAILED: security-check" >&2; exit 1; }
fi

echo "check: OK"
