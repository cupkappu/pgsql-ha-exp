#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib.sh

containerlab destroy -t "$TOPOLOGY" --cleanup >/dev/null 2>&1 || true
rm -rf /var/lib/pgsql-ha-exp
printf '%s\n' 'Patroni lab runtime, both inner Docker data directories and witness data removed'
