#!/bin/zsh
# Builds the app and publishes it to your download page over SSH: Un-remarkable-mac.zip, install-mac.sh,
# mac-version.json (the in-app updater's feed) and the <!--mac-meta--> version line in index.html.
# Settings come from config.local.env (see config.example.env): DOWNLOAD_URL, PAGES_HOST, PAGES_DIR.
# With PUBLIC_REPO set it also runs scripts/release-public.sh.
# Usage: scripts/publish.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f config.local.env ]] && source config.local.env
: "${DOWNLOAD_URL:?Set DOWNLOAD_URL in config.local.env (see config.example.env)}"
HOST="${PAGES_HOST:?Set PAGES_HOST in config.local.env (see config.example.env)}"
DIR="${PAGES_DIR:?Set PAGES_DIR in config.local.env (see config.example.env)}"

scripts/build-app.sh release
VERSION=$(cat VERSION)
COMMIT=$(git rev-parse --short HEAD)
DATE=$(date "+%-d %b %Y")
OUT=dist/Un-remarkable-mac.zip
rm -f "$OUT"
ditto -c -k --keepParent dist/Unremarkable.app "$OUT"
SIZE=$(du -m "$OUT" | cut -f1)

SHA=$(shasum -a 256 "$OUT" | cut -d' ' -f1)
BYTES=$(stat -f%z "$OUT")
# Release notes for the in-app updater: the commit message without its trailer.
NOTES=$(git log -1 --format=%B | grep -v '^Co-Authored-By:' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
MANIFEST=dist/mac-version.json
python3 -c 'import json,sys; print(json.dumps(dict(version=sys.argv[1], date=sys.argv[2], commit=sys.argv[3], size=int(sys.argv[4]), sha256=sys.argv[5], notes=sys.argv[6].strip(), zip="Un-remarkable-mac.zip"), indent=2))' \
  "$VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$COMMIT" "$BYTES" "$SHA" "$NOTES" > "$MANIFEST"

scp -q "$OUT" "$HOST:$DIR/Un-remarkable-mac.zip"
# The manifest goes up last so the updater never sees a version whose zip isn't there yet.
sed "s|__DOWNLOAD_URL__|$DOWNLOAD_URL|" scripts/install.sh > dist/install-mac.sh
scp -q dist/install-mac.sh "$HOST:$DIR/install-mac.sh"
# The pages mark the Mac version line with <!--mac-meta--> … <!--/mac-meta-->.
META="v$VERSION • $DATE • <code>$COMMIT</code> • $SIZE MB"
scp -q "$MANIFEST" "$HOST:$DIR/mac-version.json"
PAGES=("~/$DIR/index.html")
for p in ${=PAGES_EXTRA_INDEX:-}; do PAGES+=("~/$p"); done
ssh "$HOST" "for f in ${PAGES[*]}; do [ -f \$f ] && sed -i 's|<!--mac-meta-->.*<!--/mac-meta-->|<!--mac-meta-->$META<!--/mac-meta-->|' \$f; done; true"
echo "Published Un-remarkable for Mac $VERSION ($SIZE MB) to $DOWNLOAD_URL/"

# Then the public repository, if you have one (PUBLIC_REPO in config.local.env): same version, one commit.
if [[ -n "${PUBLIC_REPO:-}" ]]; then
  scripts/release-public.sh || echo "Warning: the public release to $PUBLIC_REPO didn't go out; run scripts/release-public.sh to retry." >&2
fi
