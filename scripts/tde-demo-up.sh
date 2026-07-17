#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/tde-demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tde-demo-lib.sh"

_tde_demo_compose up -d openbao

tde_demo_wait_for "OpenBao" 60 \
  _tde_demo_compose exec -T openbao \
  bao status -address=http://127.0.0.1:8200

_tde_demo_compose run --rm --no-deps openbao-init
_tde_demo_compose up -d pg1

tde_demo_wait_for "pg1 primary" 120 \
  tde_demo_role_is pg1 primary

if ! tde_demo_data_initialized pg2; then
  tde_demo_ensure_slot pg1 pg2
  tde_demo_clone pg2 pg1
fi

_tde_demo_compose up -d pg2

tde_demo_wait_for "pg2 standby" 120 \
  tde_demo_role_is pg2 standby

tde_demo_wait_for "streaming replication" 60 \
  tde_demo_sql_equals \
    pg1 \
    postgres \
    "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'" \
    1

tde_demo_print_roles
