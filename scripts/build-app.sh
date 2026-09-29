#!/usr/bin/env bash
#
# Builds NowBar and packages it as a signed app bundle at build/NowBar.app, with the hardened runtime.
#
#   scripts/build-app.sh [--install] [--open] [--demo]
#
#   --install  also copy the app to /Applications/NowBar.app (quits a running NowBar first). If /Applications
#              isn't writable for you, it goes to ~/Applications/NowBar.app instead, and says so. An older
#              copy in ~/Applications is then moved to the Trash.
#   --open     launch the app afterwards: the installed copy with --install, otherwise build/NowBar.app
#   --demo     launch with --demo (a fake playlist, no Music needed); implies --open
#   -h, --help show this help
#
# Environment:
#   NOWBAR_BINARY       bundle this prebuilt executable instead of running `swift build`
#   SIGN_IDENTITY       codesign identity to sign with (default: ad-hoc, "-")
#   NOWBAR_INSTALL_DIR  where --install puts the app (default: /Applications, or ~/Applications when that
#                       isn't writable). A folder set here is used as given, with no fallback. A relative
#                       path is relative to the directory you run this from.
#
# The app is signed with the hardened runtime and the entitlement in Resources/NowBar.entitlements.
#
# The script only ever acts on NowBar itself: it replaces an existing app, quits a running process or moves an
# old copy to the Trash only when that app or process has the bundle identifier from Resources/Info.plist.
#
# Works from any directory: it always operates on the repository this script lives in.

set -euo pipefail

# An exported CDPATH makes `cd` print the directory it enters, which would corrupt every $(cd ... && pwd) below.
unset CDPATH

START_DIR="$PWD"
# This script's own absolute path, taken before the cd below: usage() reads the script again later.
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(dirname "$(dirname "$SCRIPT")")"
cd "$ROOT"

APP_NAME="NowBar"
APP="$ROOT/build/$APP_NAME.app"
SYSTEM_APPS_DIR="/Applications"
USER_APPS_DIR="$HOME/Applications"
INSTALL_DIR="${NOWBAR_INSTALL_DIR:-$SYSTEM_APPS_DIR}"
[[ "$INSTALL_DIR" == /* ]] || INSTALL_DIR="$START_DIR/$INSTALL_DIR"   # relative to where the caller ran this, like NOWBAR_BINARY
while [[ "$INSTALL_DIR" == ?*/ ]]; do INSTALL_DIR="${INSTALL_DIR%/}"; done   # "apps/" would print as "apps//NowBar.app"
IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="Resources/NowBar.entitlements"
# The one entitlement in that file. A hardened app can only send Apple Events to Music with it.
ENTITLEMENT_KEY="com.apple.security.automation.apple-events"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,/^$/p' "$SCRIPT" | sed -e 's/^# \{0,1\}//' -e '/^#$/d'
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
[[ -f "$ENTITLEMENTS" ]] || die "$ENTITLEMENTS is missing"

# NowBar's own bundle identifier. Existing apps and running processes are only touched when they have this one.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist 2>/dev/null)" \
  || die "Resources/Info.plist has no CFBundleIdentifier"
[[ -n "$BUNDLE_ID" ]] || die "Resources/Info.plist has an empty CFBundleIdentifier"

# --- 1. The executable ---------------------------------------------------------------------------

if [[ -n "${NOWBAR_BINARY:-}" ]]; then
  BINARY="$NOWBAR_BINARY"
  [[ "$BINARY" == /* ]] || BINARY="$START_DIR/$BINARY"   # relative to where the caller ran this, not the repo root
  [[ -f "$BINARY" && -x "$BINARY" ]] || die "NOWBAR_BINARY is not an executable file: $BINARY"
  BINARY="$(cd "$(dirname "$BINARY")" && pwd)/$(basename "$BINARY")"
  # The bundle is deleted and rebuilt below, so a binary inside it would be gone before it could be copied.
  # find -samefile compares the files themselves, so a symlink or a different spelling of the path can't hide it.
  if [[ -d "$APP" && -n "$(find "$APP" -samefile "$BINARY" 2>/dev/null)" ]]; then
    die "NOWBAR_BINARY ($BINARY) is inside $APP, which this script deletes and rebuilds; use a copy from somewhere else"
  fi
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

# Verifies the signature of the app bundle at $1, then that the hardened runtime and the Apple Events entitlement
# are really in it. Without the entitlement macOS would refuse every Apple Event NowBar sends to Music.
check_signature() {
  local bundle="$1" details entitlements
  local runtime_flag='flags=0x[0-9a-f]+\([^)]*runtime'
  codesign --verify --strict "$bundle" || die "codesign --verify failed for $bundle"
  # Captured first: with pipefail, `codesign | grep -q` can fail on SIGPIPE even when grep found its match.
  details="$(codesign -d --verbose=2 "$bundle" 2>&1)" || die "could not read the signature of $bundle"
  [[ "$details" =~ $runtime_flag ]] || die "$bundle is not signed with the hardened runtime"
  entitlements="$(codesign -d --entitlements - "$bundle" 2>/dev/null)" || die "could not read the entitlements of $bundle"
  [[ "$entitlements" == *"$ENTITLEMENT_KEY"* ]] || die "$bundle does not have the $ENTITLEMENT_KEY entitlement"
}

if [[ "$IDENTITY" == "-" ]]; then SIGN_LABEL="ad-hoc"; else SIGN_LABEL="$IDENTITY"; fi
log "Signing ($SIGN_LABEL, hardened runtime)"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
check_signature "$APP"

# --- 4. Install and launch -----------------------------------------------------------------------

# The CFBundleIdentifier of the app bundle at $1: nothing when $1 isn't an app bundle (or has no readable Info.plist).
bundle_id_of() {
  local plist="$1/Contents/Info.plist" id
  [[ -f "$plist" ]] || return 0
  # PlistBuddy reports some errors on stdout, so a failed read must not leave any output behind.
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" || return 0
  printf '%s\n' "$id"
}

# Quits the running NowBar and waits for it to exit. An app that is already running would only be brought to the
# front by `open`, ignoring --args, and can't be replaced on disk while it runs.
# Only a process of this user, called NowBar, whose executable sits in an app bundle with NowBar's own identifier
# is signalled. Any other process with that name (an unrelated app, a bare executable from `swift run`) is left
# alone, and logged.
quit_running() {
  local pid exe bundle tries alive ours=""
  for pid in $(pgrep -u "$(id -u)" -x "$APP_NAME" 2>/dev/null || true); do
    # On macOS this is the executable's full path: /Applications/NowBar.app/Contents/MacOS/NowBar
    exe="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    [[ -n "$exe" ]] || continue   # it exited in the meantime
    bundle="${exe%/Contents/MacOS/*}"
    if [[ "$bundle" != "$exe" && "$(bundle_id_of "$bundle")" == "$BUNDLE_ID" ]]; then
      ours="$ours $pid"
    else
      log "Leaving process $pid alone: $exe is not in an app bundle with the identifier $BUNDLE_ID"
    fi
  done
  [[ -n "$ours" ]] || return 0

  log "Quitting the running $APP_NAME"
  kill $ours 2>/dev/null || true
  for tries in $(seq 1 50); do
    alive=""
    for pid in $ours; do
      if kill -0 "$pid" 2>/dev/null; then alive="$alive $pid"; fi
    done
    [[ -n "$alive" ]] || return 0
    sleep 0.2
  done
  die "$APP_NAME is still running after 10 seconds; quit it and try again"
}

# Once the new copy is in place, moves an older NowBar in ~/Applications to the Trash. It never deletes anything,
# does nothing when the old copy is the one just installed, and leaves alone anything there that isn't NowBar.
# quit_running has already run, so the old copy isn't running.
trash_old_copy() {
  local old="$USER_APPS_DIR/$APP_NAME.app" old_id trash="$HOME/.Trash" target n=1
  [[ -e "$old" ]] || return 0
  if [[ "$old" -ef "$FINAL_APP" ]]; then return 0; fi   # -ef: the same directory, even through a symlink

  old_id="$(bundle_id_of "$old")"
  if [[ "$old_id" != "$BUNDLE_ID" ]]; then
    warn "leaving $old where it is: it is not NowBar (its bundle identifier is ${old_id:-missing}, NowBar's is $BUNDLE_ID)"
    return 0
  fi

  target="$trash/$APP_NAME.app"
  # Something with that name may already be in the Trash: pick a free one ("NowBar 2.app", ...), never overwrite.
  while [[ -e "$target" || -L "$target" ]]; do
    n=$((n + 1))
    target="$trash/$APP_NAME $n.app"
  done
  if mv "$old" "$target"; then
    log "Moved the old copy $old to the Trash ($target)"
  else
    warn "could not move the old copy $old to the Trash; move it there yourself"
  fi
}

FINAL_APP="$APP"
if [[ $INSTALL -eq 1 ]]; then
  # Without admin rights an account can't write to /Applications. Fall back to ~/Applications, and say so.
  # A folder chosen with NOWBAR_INSTALL_DIR is used as given: if it isn't writable, that is an error below.
  if [[ -z "${NOWBAR_INSTALL_DIR:-}" && ! -w "$INSTALL_DIR" ]]; then
    INSTALL_DIR="$USER_APPS_DIR"
    log "$SYSTEM_APPS_DIR is not writable for $(id -un); installing to $INSTALL_DIR instead"
  fi
  FINAL_APP="$INSTALL_DIR/$APP_NAME.app"
  mkdir -p "$INSTALL_DIR"
  [[ -w "$INSTALL_DIR" ]] || die "$INSTALL_DIR is not writable; choose another folder with NOWBAR_INSTALL_DIR"

  # Everything that can go wrong is checked here, before a running NowBar is quit or anything is replaced.
  # The target must not be the bundle just built (installing would delete it) or anything inside it.
  if [[ "$FINAL_APP" -ef "$APP" || -n "$(find "$APP" -samefile "$INSTALL_DIR" 2>/dev/null)" ]]; then
    die "cannot install to $FINAL_APP: that is, or lies inside, the app just built in $ROOT/build; choose another folder with NOWBAR_INSTALL_DIR"
  fi
  # Only a NowBar is replaced. Whatever else is at the target is none of this script's business.
  if [[ -e "$FINAL_APP" || -L "$FINAL_APP" ]]; then
    existing_id="$(bundle_id_of "$FINAL_APP")"
    if [[ "$existing_id" != "$BUNDLE_ID" ]]; then
      die "$FINAL_APP already exists and is not NowBar (its bundle identifier is ${existing_id:-missing}, NowBar's is $BUNDLE_ID); leaving it alone. Move it away yourself or choose another folder with NOWBAR_INSTALL_DIR"
    fi
  fi
fi
if [[ $INSTALL -eq 1 || $OPEN -eq 1 ]]; then
  quit_running
fi
if [[ $INSTALL -eq 1 ]]; then
  log "Installing to $FINAL_APP"
  rm -rf "$FINAL_APP"
  ditto "$APP" "$FINAL_APP"
  check_signature "$FINAL_APP"
  trash_old_copy
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
printf 'Signing:  %s, hardened runtime\n' "$SIGN_LABEL"
if [[ "$IDENTITY" == "-" ]]; then
  printf 'Note:     ad-hoc signatures change with every build, so macOS may ask for the Automation and\n'
  printf '          Accessibility permissions again after a rebuild. Sign with your own certificate\n'
  printf '          (SIGN_IDENTITY) to keep them; see README.md.\n'
fi
