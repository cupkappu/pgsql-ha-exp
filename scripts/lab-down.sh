#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib.sh

containerlab destroy -t "$TOPOLOGY" --cleanup
printf '%s\n' 'lab destroyed; inner Docker volumes were preserved'
