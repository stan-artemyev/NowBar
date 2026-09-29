#!/usr/bin/env bash
#
# Builds NowBar and packages it as a signed app bundle at build/NowBar.app.
#
#   scripts/build-app.sh [--install] [--open] [--demo]
#
#   --install  also copy the app to ~/Applications/NowBar.app (quits a running NowBar first)
#   --open     launch the app afterwards: the installed copy with --install, otherwise build/NowBar.app
#   --demo     launch with --demo (a fake playlist, no Music needed); implies --open
#   -h, --help show this help
#
# Environment:
#   NOWBAR_BINARY       bundle this prebuilt executable instead of running `swift build`
#   SIGN_IDENTITY       codesign identity to sign with (default: ad-hoc, "-")
#   NOWBAR_INSTALL_DIR  where --install puts the app (default: ~/Applications)
#
# Works from any directory: it always operates on the repository this script lives in.

set -euo pipefail

START_DIR="$PWD"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="NowBar"
APP="$ROOT/build/$APP_NAME.app"
INSTALL_DIR="${NOWBAR_INSTALL_DIR:-$HOME/Applications}"
IDENTITY="${SIGN_IDENTITY:--}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '/^#$/d'
}

INSTALL=0
OPEN=0
DEMO=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --open) OPEN=1 ;;
    --demo) DEMO=1; OPEN=1 ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n\n' "$arg" >&2; usage >&2; exit 64 ;;
  esac
done

[[ -f Resources/Info.plist ]] || die "Resources/Info.plist is missing"
[[ -f Resources/AppIcon.icns ]] || die "Resources/AppIcon.icns is missing; generate it with 'make icon'"

# --- 1. The executable ---------------------------------------------------------------------------

if [[ -n "${NOWBAR_BINARY:-}" ]]; then
  BINARY="$NOWBAR_BINARY"
  [[ "$BINARY" == /* ]] || BINARY="$START_DIR/$BINARY"   # relative to where the caller ran this, not the repo root
  [[ -f "$BINARY" && -x "$BINARY" ]] || die "NOWBAR_BINARY is not an executable file: $BINARY"
  BINARY="$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")"
  log "Bundling prebuilt binary $BINARY (skipping swift build)"
else
  command -v swift >/dev/null 2>&1 || die "swift not found; install Xcode or the Command Line Tools (xcode-select --install)"
  log "swift build -c release --product $APP_NAME"
  swift build -c release --product "$APP_NAME"
  # Never hardcode the products directory: it depends on the toolchain's build system.
  BIN_DIR="$(swift build -c release --show-bin-path | tail -n 1)"
  BINARY="$BIN_DIR/$APP_NAME"
  [[ -f "$BINARY" && -x "$BINARY" ]] || die "expected the release binary at $BINARY, but it is not there"
fi

# --- 2. The bundle -------------------------------------------------------------------------------

log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
chmod 755 "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist is not a valid property list"
declared_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
[[ "$declared_executable" == "$APP_NAME" ]] || die "Info.plist declares CFBundleExecutable '$declared_executable', expected '$APP_NAME'"

# --- 3. Signing ----------------------------------------------------------------------------------

if [[ "$IDENTITY" == "-" ]]; then SIGN_LABEL="ad-hoc"; else SIGN_LABEL="$IDENTITY"; fi
log "Signing ($SIGN_LABEL)"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP" || die "codesign --verify failed for $APP"

# --- 4. Install and launch -----------------------------------------------------------------------

# Quits any running NowBar and waits for it to exit. An app that is already running would only be
# brought to the front by `open`, ignoring --args, and can't be replaced on disk while it runs.
quit_running() {
  pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
  log "Quitting the running $APP_NAME"
  pkill -x "$APP_NAME" || true
  local tries
  for tries in $(seq 1 50); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  die "$APP_NAME is still running after 10 seconds; quit it and try again"
}

FINAL_APP="$APP"
if [[ $INSTALL -eq 1 || $OPEN -eq 1 ]]; then
  quit_running
fi
if [[ $INSTALL -eq 1 ]]; then
  FINAL_APP="$INSTALL_DIR/$APP_NAME.app"
  log "Installing to $FINAL_APP"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$FINAL_APP"
  ditto "$APP" "$FINAL_APP"
  codesign --verify --strict "$FINAL_APP" || die "codesign --verify failed for the installed copy $FINAL_APP"
fi
if [[ $OPEN -eq 1 ]]; then
  log "Opening $FINAL_APP"
  if [[ $DEMO -eq 1 ]]; then
    open "$FINAL_APP" --args --demo
  else
    open "$FINAL_APP"
  fi
fi

printf '\n'
printf 'App:      %s\n' "$FINAL_APP"
printf 'Signing:  %s\n' "$SIGN_LABEL"
if [[ "$IDENTITY" == "-" ]]; then
  printf 'Note:     ad-hoc signatures change with every build, so macOS may ask for the Automation and\n'
  printf '          Accessibility permissions again after a rebuild (see README.md).\n'
fi
