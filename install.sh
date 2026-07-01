#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="${HOME}/.cursor"

mkdir -p "$DEST"
install -m 755 "$ROOT/bin/statusline.sh" "$DEST/statusline.sh"
install -m 755 "$ROOT/bin/statusline-power.sh" "$DEST/statusline-power.sh"
install -m 755 "$ROOT/bin/statusline-cloud.sh" "$DEST/statusline-cloud.sh"
install -m 644 "$ROOT/conf/statusline-power.conf" "$DEST/statusline-power.conf"
install -m 644 "$ROOT/conf/statusline-cloud.conf" "$DEST/statusline-cloud.conf"

echo "Installed scripts and configs to ${DEST}/"
echo "Merge statusLine from ${ROOT}/cli-config.statusline.json into ${DEST}/cli-config.json"
