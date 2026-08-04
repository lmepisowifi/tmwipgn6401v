#!/bin/sh
# release.sh — lmepisowifi release helper
# Usage: ./release.sh "your commit message"
#        ./release.sh "your commit message" 1.0.5   (force a specific version)
set -e
MSG="$1"
FORCE_VER="$2"

# ── Require a commit message ─────────────────────────────────────────────────
if [ -z "$MSG" ]; then
    echo "Usage: $0 \"commit message\" [version]"
    echo "  e.g. $0 \"Fix wlanbasic wget issue\""
    echo "  e.g. $0 \"Fix wlanbasic wget issue\" 1.0.5"
    exit 1
fi

# ── Auto-increment patch version from latest git tag ────────────────────────
if [ -n "$FORCE_VER" ]; then
    NEW_VER="$FORCE_VER"
else
    LATEST=$(git tag --sort=-v:refname | grep '^v' | head -1)
    if [ -z "$LATEST" ]; then
        LATEST="v1.0.0"
    fi
    VER="${LATEST#v}"
    MAJOR=$(echo "$VER" | cut -d. -f1)
    MINOR=$(echo "$VER" | cut -d. -f2)
    PATCH=$(echo "$VER" | cut -d. -f3)
    PATCH=$((PATCH + 1))
    NEW_VER="$MAJOR.$MINOR.$PATCH"
fi
TAG="v$NEW_VER"

echo "┌─────────────────────────────────────────┐"
echo "  lmepisowifi release helper"
echo "  Message : $MSG"
echo "  Version : $TAG"
echo "└─────────────────────────────────────────┘"
echo ""

# ── Confirm ──────────────────────────────────────────────────────────────────
printf "Proceed? [y/N] "
read -r CONFIRM
case "$CONFIRM" in
    y|Y) ;;
    *) echo "Aborted."; exit 0 ;;
esac
echo ""
find ./ -type f \( -name "*.cgi" -o -name "*.sh" \) -exec chmod +x {} +
# ── Stage and commit ─────────────────────────────────────────────────────────
echo "► Staging all changes..."
git add .

if git diff --cached --quiet; then
    echo "  No changes to commit — skipping commit step."
else
    echo "► Committing..."
    git commit -m "$MSG" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
fi
echo ""

# ── Pull with rebase (avoids divergent branch errors) ────────────────────────
echo "► Pulling latest from GitHub..."
git pull --rebase origin main
echo ""

# ── Push main ────────────────────────────────────────────────────────────────
echo "► Pushing main branch..."
git push origin main
echo ""

# ── Tag and push — this is what triggers GitHub Actions to do the release ────
# DO NOT run gh release create here. The release.yml workflow handles:
#   building NodeMCU firmware, packing the tarball, computing sha256,
#   writing manifest.txt, committing it, and creating the GitHub Release.
# Running any of that here would race against the workflow and corrupt
# the manifest sha256.
if git tag | grep -q "^${TAG}$"; then
    echo "  Tag $TAG already exists locally — removing and recreating..."
    git tag -d "$TAG"
fi
echo "► Tagging $TAG..."
git tag "$TAG"
git push origin "$TAG"
echo ""

echo "┌─────────────────────────────────────────┐"
echo "  Done! $TAG pushed to GitHub."
echo "  GitHub Actions is now building the release."
echo "  Check: https://github.com/lmepisowifi/tmwipgn6401v/actions"
echo "└─────────────────────────────────────────┘"
