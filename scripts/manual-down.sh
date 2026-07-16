#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-lib.sh"

if [[ -f "$MANUAL_TOPOLOGY" ]]; then
  containerlab destroy -t "$MANUAL_TOPOLOGY" --cleanup >/dev/null 2>&1 || true
fi

printf '%s\n' 'manual PostgreSQL hosts stopped; data retained'
