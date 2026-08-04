#!/bin/sh
# ============================================================
# make_release.sh — cut an OTA release for lmepisowifi
#
# Run this on your PC inside a clone of:
#   https://github.com/lmepisowifi/tmwipgn6401v
#
# Repo layout expected:
#   payload/            <- exactly the tree that maps onto /lmepisowifi on the
#                          device (hotspot/, www2/, lmehspt.sh, ota.sh, ota.env,
#                          ota-tools/, cacert.pem ...). NO runtime data here.
#   ota-tools/make_release.sh   (this script)
#
# Usage:
#   ./ota-tools/make_release.sh 1.0.1 "What changed in this release"
#
# It produces:
#   dist/lmepisowifi-<ver>.tar.gz   (the release asset to upload)
#   manifest.txt                    (commit this to main)
# and prints the exact gh/git commands to publish.
# ============================================================
set -e

REPO="lmepisowifi/tmwipgn6401v"
BRANCH="main"

VER="$1"
NOTES="${2:-Release $1}"
[ -n "$VER" ] || { echo "usage: $0 <version> [notes]"; exit 2; }
case "$VER" in *[!0-9.]*) echo "version must be dotted numeric, e.g. 1.0.1"; exit 2 ;; esac

[ -d payload ] || { echo "ERROR: run from the repo root; expected a payload/ directory"; exit 1; }

# stamp the version into the payload so the device's VERSION matches after install
printf '%s\n' "$VER" > payload/VERSION

# ------------------------------------------------------------------
# Cache-busting: stamp ?v=$VER onto every local static asset reference
# so browsers fetch fresh CSS/JS/fonts/icons after each OTA update.
# Re-stamping strips any previous ?v=... first, so this is idempotent.
# (User-uploadable assets — audio, promo images, logo — are busted
#  separately at request time via portal_config.sh using file mtime.)
# ------------------------------------------------------------------
echo "Stamping cache-buster ?v=$VER onto static assets…"
find payload -name '*.html' -type f | while read -r f; do
    sed -i -E \
        -e 's#(href|src)="(/(css|js|graphics|font)/[^"?]*)(\?v=[^"]*)?"#\1="\2?v='"$VER"'"#g' \
        -e 's#(href|src)="(/img/(favicon\.ico|logo\.png))(\?v=[^"]*)?"#\1="\2?v='"$VER"'"#g' \
        "$f"
done
for css in payload/www2/css/style.css payload/hotspot/css/portal.css; do
    [ -f "$css" ] && sed -i -E \
        's#url\("(/(graphics|font)/Nunito\.ttf)(\?v=[^"]*)?"\)#url("\1?v='"$VER"'")#g' \
        "$css"
done

mkdir -p dist
ASSET="lmepisowifi-$VER.tar.gz"

# Exclude runtime state and transient files from the shipped payload.
tar --exclude='./hotspot_data' \
    --exclude='./globals.env' \
    --exclude='./ota.env' \
    --exclude='./.ota_stage' \
    --exclude='./*.ota_old' \
    --exclude='./www2/uploads/*' \
    -czf "dist/$ASSET" -C payload .

SHA=$(sha256sum "dist/$ASSET" | awk '{print $1}')
URL="https://github.com/$REPO/releases/download/v$VER/$ASSET"

cat > manifest.txt <<EOF
version=$VER
url=$URL
sha256=$SHA
min_version=0.0.0
notes=$NOTES
EOF

echo "=============================================================="
echo "Built dist/$ASSET"
echo "  sha256: $SHA"
echo "Wrote manifest.txt"
echo
echo "Publish with GitHub CLI:"
echo "  git add manifest.txt payload/VERSION && git commit -m \"release v$VER\" && git push"
echo "  gh release create v$VER dist/$ASSET --title \"v$VER\" --notes \"$NOTES\""
echo
echo "Or manually: create a release tagged v$VER and upload dist/$ASSET as an asset,"
echo "then commit manifest.txt to the $BRANCH branch."
echo "=============================================================="
