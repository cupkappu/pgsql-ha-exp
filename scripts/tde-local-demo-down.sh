#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/tde-local-demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tde-local-demo-lib.sh"

_tde_local_demo_compose --profile tools down --remove-orphans
