#!/usr/bin/env bash
# Start an iOS build from this machine.
#
# There is no Mac here, so every compile is a 15 to 40 minute round trip through GitHub Actions, and
# until now starting one meant opening the browser. This does it from the terminal: pushes whatever
# is committed, then dispatches the TestFlight lane on the current branch.
#
#   ./tools/build-ios.sh          "iOS Build" — compiles only. THIS IS THE DEFAULT AND THE FIRST STEP.
#   ./tools/build-ios.sh ship     TestFlight — signed and uploaded, only once the check above is green.
#
# ⛔ THAT ORDER IS HIS, AND IT IS NOT A SUGGESTION (2026-08-25: "why did you skip iOS Build and go
# straight to TestFlight"). A batch of unbuilt changes fails on a typo as easily as anything else,
# and the check lane says so in about eight minutes without spending signing, upload or a TestFlight
# processing wait. TestFlight is for a state already known to compile.
#
# ⚠️ THE LANES ARE MANUAL ON PURPOSE. `on: workflow_dispatch` in both workflow files, and the comment
# there says why: macOS minutes are spent only when we mean to. A session pushes half a dozen
# commits and only the last state is worth building. Do not "helpfully" add a push trigger.
#
# It refuses to run with uncommitted changes, because the build would silently not contain them.
set -euo pipefail

cd "$(dirname "$0")/.."

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
LANE="iOS Build"
[ "${1:-}" = "ship" ] && LANE="TestFlight"

if [ -n "$(git status --porcelain)" ]; then
  echo "✗ Uncommitted changes. The build would not include them:"
  git status --short
  echo
  echo "  Commit them first, then run this again."
  exit 1
fi

echo "→ branch : $BRANCH"
echo "→ head   : $(git rev-parse --short HEAD)  $(git log -1 --pretty=%s)"
echo "→ lane   : $LANE"
echo

git push -q origin "$BRANCH"
echo "✓ branch pushed"

gh workflow run "$LANE" --ref "$BRANCH"
echo "✓ dispatched"
echo
sleep 5
gh run list --workflow="$LANE" --branch "$BRANCH" --limit 1
echo
echo "  Follow it:  gh run watch \$(gh run list --workflow=\"$LANE\" --branch $BRANCH --limit 1 --json databaseId -q '.[0].databaseId')"
