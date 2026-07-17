#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/tde-local-demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tde-local-demo-lib.sh"

target="${1:-}"
if [[ "$target" != pg1 && "$target" != pg2 ]]; then
  echo "usage: $0 pg1|pg2" >&2
  exit 1
fi

source_node="$(tde_local_demo_primary_node)"
if [[ "$source_node" == "$target" ]]; then
  echo "${target} is the current primary" >&2
  exit 1
fi

slot="$(tde_local_demo_slot_name "$target")"
data_volume="$(tde_local_demo_data_volume "$target")"
keyring_volume="$(tde_local_demo_keyring_volume "$target")"

_tde_local_demo_compose stop "$target" >/dev/null 2>&1 || true
_tde_local_demo_compose rm -f "$target" >/dev/null 2>&1 || true

tde_local_demo_psql "$source_node" postgres \
  "SELECT pg_drop_replication_slot('${slot}') FROM pg_replication_slots WHERE slot_name = '${slot}' AND NOT active;" >/dev/null

tde_local_demo_ensure_slot "$source_node" "$target"

docker volume rm -f "$data_volume" >/dev/null
docker volume rm -f "$keyring_volume" >/dev/null

_tde_local_demo_compose create "$target" >/dev/null
tde_local_demo_prepare_keyring_volume "$keyring_volume"
tde_local_demo_clone "$target" "$source_node"
_tde_local_demo_compose up -d --no-deps "$target"

tde_local_demo_wait_for "${target} standby" 120 \
  tde_local_demo_role_is "$target" standby

tde_local_demo_keyrings_match || {
  echo "keyring copies do not match after rejoin" >&2
  exit 1
}

tde_local_demo_print_roles
