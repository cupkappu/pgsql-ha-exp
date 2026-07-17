#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/tde-local-demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tde-local-demo-lib.sh"

node="${1:-}"
if [[ "$node" != pg1 && "$node" != pg2 ]]; then
  echo "usage: $0 pg1|pg2" >&2
  exit 1
fi

if [[ "$(tde_local_demo_role "$node")" != standby ]]; then
  echo "${node} is not a standby" >&2
  exit 1
fi

_tde_local_demo_compose exec -T --user postgres "$node" \
  pg_ctl -D /data/db promote -w

tde_local_demo_wait_for "${node} primary" 60 \
  tde_local_demo_role_is "$node" primary

tde_local_demo_print_roles
