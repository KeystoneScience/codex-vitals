#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Usage: prepare-sparkle-update.sh version [archive]}"
ARCHIVE="${2:-${ROOT}/dist/Headroom-${VERSION}.zip}"
GENERATOR="${ROOT}/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
STAGING="${ROOT}/dist/sparkle-appcast"
REPOSITORY="https://github.com/TheMakerOfWorlds/codex-vitals"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]] || { echo 'Invalid release version' >&2; exit 1; }
[[ -f "$ARCHIVE" && -x "$GENERATOR" ]] || { echo 'Build the app and update archive first.' >&2; exit 1; }
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$ARCHIVE" "$STAGING/"
ARGS=(--download-url-prefix "${REPOSITORY}/releases/download/v${VERSION}/"
    --link "$REPOSITORY" --full-release-notes-url "${REPOSITORY}/releases/tag/v${VERSION}"
    --maximum-versions 1 --maximum-deltas 0 "$STAGING")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    # Pass the secret only on stdin, never as a command argument or log.
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATOR" --ed-key-file - "${ARGS[@]}"
else
    "$GENERATOR" --account codex-vitals.themakerofworlds "${ARGS[@]}"
fi
xmllint --noout "$STAGING/appcast.xml"
swift "$ROOT/scripts/verify-update.swift" "$STAGING/appcast.xml" "$ARCHIVE" "$ROOT/Support/Info.plist"
echo "Verified feed: $STAGING/appcast.xml"
