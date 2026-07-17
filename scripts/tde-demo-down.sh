#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/tde-demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tde-demo-lib.sh"

_tde_demo_compose down --remove-orphans

echo "OpenBao dev mode stores keys in memory. Run make tde-demo-clean before the next fresh start."
