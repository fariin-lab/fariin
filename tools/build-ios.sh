#!/usr/bin/env bash
# Start an iOS build from this machine.
#
# There is no Mac here, so every compile is a round trip through Codemagic, and until now that meant
# opening a browser and pressing a button. This does the same thing from the terminal: it pushes
# whatever is committed and then pushes a `build-*` tag, which is the only thing codemagic.yaml
# triggers on. Commits stay free; one tag buys one build of everything that has landed.
#
#   ./tools/build-ios.sh              build the current branch
#   ./tools/build-ios.sh "voice fix"  same, with a note in the tag message
#
# It refuses to run with uncommitted changes, because the build would silently not contain them.
set -euo pipefail

cd "$(dirname "$0")/.."

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
NOTE="${1:-}"

if [ -n "$(git status --porcelain)" ]; then
  echo "✗ Uncommitted changes. The build would not include them:"
  git status --short
  echo
  echo "  Commit them first, then run this again."
  exit 1
fi

# Every tag is unique, and the name says when it was cut so a TestFlight build can be traced back to
# one without opening anything.
TAG="build-$(date +%Y%m%d-%H%M%S)"
SUBJECT="$(git log -1 --pretty=%s)"

echo "→ branch : $BRANCH"
echo "→ head   : $(git rev-parse --short HEAD)  $SUBJECT"
echo "→ tag    : $TAG"
echo

git push -q origin "$BRANCH"
echo "✓ branch pushed"

if [ -n "$NOTE" ]; then
  git tag -a "$TAG" -m "$NOTE"
else
  git tag -a "$TAG" -m "$SUBJECT"
fi
git push -q origin "$TAG"
echo "✓ tag pushed — Codemagic starts the build now"
echo
echo "  Watch it: https://codemagic.io/apps"
echo "  It lands in TestFlight when it is green, usually 15 to 40 minutes."
