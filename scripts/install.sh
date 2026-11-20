#!/bin/zsh
# Installs or updates Un-remarkable for Mac from a download page made by scripts/publish.sh.
#   curl -fsSL <your download page>/install-mac.sh | zsh
# It replaces the copy you already have, wherever it is (/Applications or ~/Applications), even when another
# account on this Mac installed it (then it asks for your Mac password).
# scripts/publish.sh uploads it as install-mac.sh with your DOWNLOAD_URL filled in; edit it here, not there.
set -euo pipefail
BASE="${UNREMARKABLE_URL:-__DOWNLOAD_URL__}"
if [[ "$BASE" == __*__ ]]; then
  echo "No download address: run the install-mac.sh from your download page, or set UNREMARKABLE_URL." >&2
  echo "To install from source instead: scripts/build-app.sh, then copy dist/Unremarkable.app to Applications." >&2
  exit 1
fi
APP=Unremarkable.app
# Folders searched for an existing copy, shared one first (UNREMARKABLE_APPS overrides, for testing).
DIRS=(${=UNREMARKABLE_APPS:-/Applications $HOME/Applications})

[ "$(uname -m)" = "arm64" ] || { echo "This build is for Apple silicon Macs only (you have $(uname -m))." >&2; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || { echo "Un-remarkable needs macOS 15 or later (meeting mode needs macOS 26)." >&2; exit 1; }

version_of() { defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?"; }

# Where it goes: the existing copy if there is one (the shared /Applications one first), else /Applications.
existing=()
for d in $DIRS; do [ -d "$d/$APP" ] && existing+=("$d"); done
DEST="${existing[1]:-${DIRS[1]}}"
if [ ${#existing[@]} -gt 0 ]; then
  echo "Found Un-remarkable $(version_of "$DEST/$APP") in $DEST."
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "Downloading the latest version from $BASE ..."
curl -fSL "$BASE/Un-remarkable-mac.zip" -o "$TMP/app.zip"
ditto -x -k "$TMP/app.zip" "$TMP"
NEW=$(version_of "$TMP/$APP")
echo "Downloaded Un-remarkable $NEW."

# Quit this account's running copy so the new one opens fresh.
if pgrep -xu "$(id -u)" Unremarkable >/dev/null; then
  echo "Quitting the running copy ..."
  osascript -e 'quit app id "com.unremarkable.mac"' 2>/dev/null || true
  for _ in {1..20}; do pgrep -xu "$(id -u)" Unremarkable >/dev/null || break; sleep 0.5; done
  pkill -xu "$(id -u)" Unremarkable 2>/dev/null || true
fi
if pgrep -x Unremarkable >/dev/null; then
  echo "Note: it's also open in another account on this Mac. That copy keeps running the old version until it's reopened."
fi

# Replace in place: copy next to the old app, then swap, so a failure never leaves you without one.
replace() {  # $1 = command prefix ("" or "sudo")
  local run=(${=1})
  $run rm -rf "$DEST/.$APP.new" &&
  $run ditto "$TMP/$APP" "$DEST/.$APP.new" &&
  $run rm -rf "$DEST/$APP" &&
  $run mv "$DEST/.$APP.new" "$DEST/$APP" || return 1
  $run xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
  # Let every account on this Mac open it.
  $run chmod -R a+rX "$DEST/$APP" 2>/dev/null || true
}

mkdir -p "$DEST" 2>/dev/null || true
if ! replace "" 2>/dev/null; then
  echo
  echo "The copy in $DEST belongs to another account on this Mac (or the folder is protected)."
  echo "Enter your Mac password to update it (your account needs to be an administrator):"
  if ! replace sudo </dev/tty; then
    if [ "$DEST" = "${DIRS[1]}" ] && [ -n "${DIRS[2]:-}" ]; then
      DEST="${DIRS[2]}"
      mkdir -p "$DEST"
      echo
      echo "Couldn't update the shared copy, so installing a copy just for you in $DEST instead."
      echo "Open Un-remarkable from there (or ask an administrator to run this command to update the shared copy)."
      replace "" || { echo "Install failed." >&2; exit 1; }
    else
      echo "Install failed." >&2; exit 1
    fi
  fi
fi

installed=$(version_of "$DEST/$APP")
echo
if [ "$installed" = "$NEW" ]; then
  echo "Installed Un-remarkable $installed -> $DEST/$APP"
else
  echo "Something went wrong: $DEST/$APP is version $installed, expected $NEW." >&2
  exit 1
fi
# Another copy elsewhere would be the old version; say so, since Spotlight may open that one.
for d in $DIRS; do
  if [ "$d" != "$DEST" ] && [ -d "$d/$APP" ]; then
    echo "Note: there's an older copy ($(version_of "$d/$APP")) in $d. Delete it so Spotlight and the Dock open the new one."
  fi
done
[ -n "${UNREMARKABLE_NO_OPEN:-}" ] || open "$DEST/$APP"
