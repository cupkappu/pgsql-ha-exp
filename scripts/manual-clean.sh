#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-lib.sh"

bash "$SOURCE_DIR/scripts/manual-down.sh"
rm -rf /var/lib/pgsql-ha-manual
printf '%s\n' 'manual PostgreSQL runtime and data removed'
