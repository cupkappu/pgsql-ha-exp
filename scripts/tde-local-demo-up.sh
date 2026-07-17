#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/tde-local-demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tde-local-demo-lib.sh"

_tde_local_demo_compose --profile tools create pg1 pg2 keyring-backup >/dev/null
tde_local_demo_prepare_all_keyring_volumes
_tde_local_demo_compose up -d --no-deps pg1

tde_local_demo_wait_for "pg1 primary" 120 \
  tde_local_demo_role_is pg1 primary

if ! tde_local_demo_data_initialized pg2; then
  tde_local_demo_ensure_slot pg1 pg2
  tde_local_demo_clone pg2 pg1
else
  tde_local_demo_sync_keyring pg1 pg2
fi

_tde_local_demo_compose up -d --no-deps pg2

tde_local_demo_wait_for "pg2 standby" 120 \
  tde_local_demo_role_is pg2 standby

tde_local_demo_wait_for "streaming replication" 60 \
  tde_local_demo_sql_equals \
    pg1 \
    postgres \
    "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'" \
    1

tde_local_demo_keyrings_match || {
  echo "keyring copies do not match" >&2
  exit 1
}

tde_local_demo_print_roles
