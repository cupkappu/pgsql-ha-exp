#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-demo-lib.sh"

manual_demo_compose down -v --remove-orphans
printf '%s\n' 'manual Compose demo containers, network, and database volumes removed'
