#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/pcmk-lib.sh

containerlab destroy -t "$PCMK_TOPOLOGY" --cleanup
printf '%s\n' 'Pacemaker lab destroyed; PostgreSQL and cluster state preserved'
