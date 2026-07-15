#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOPOLOGY="/var/lib/pgsql-ha-exp-pcmk/lab/topology-pacemaker.clab.yml"
if [[ -f "$TOPOLOGY" ]]; then
  containerlab destroy -t "$TOPOLOGY" --cleanup >/dev/null 2>&1 || true
else
  cd "$SOURCE_DIR"
  containerlab destroy -t topology-pacemaker.clab.yml --cleanup >/dev/null 2>&1 || true
fi
rm -rf /var/lib/pgsql-ha-exp-pcmk
printf '%s\n' 'Pacemaker lab runtime, PostgreSQL data and cluster state removed'
