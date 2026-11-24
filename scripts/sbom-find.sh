#!/usr/bin/env bash
# Usage: scripts/sbom-find.sh <library-name> <sbom files...>
set -euo pipefail
lib="$1"; shift
for f in "$@"; do
  jq -r --arg lib "$lib" --arg f "$f" \
    '.components[] | select(.name == $lib) | "\($f): \(.name) \(.version)"' "$f"
done
