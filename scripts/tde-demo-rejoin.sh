#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/tde-demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tde-demo-lib.sh"

target="${1:-}"
if [[ "$target" != pg1 && "$target" != pg2 ]]; then
  echo "usage: $0 pg1|pg2" >&2
  exit 1
fi

source_node="$(tde_demo_primary_node)"
if [[ "$source_node" == "$target" ]]; then
  echo "${target} is the current primary" >&2
  exit 1
fi

slot="$(tde_demo_slot_name "$target")"
volume="$(tde_demo_volume "$target")"

_tde_demo_compose stop "$target" >/dev/null 2>&1 || true
_tde_demo_compose rm -f "$target" >/dev/null 2>&1 || true

tde_demo_psql "$source_node" postgres \
  "SELECT pg_drop_replication_slot('${slot}') FROM pg_replication_slots WHERE slot_name = '${slot}' AND NOT active;" >/dev/null

tde_demo_ensure_slot "$source_node" "$target"

docker volume rm -f "$volume" >/dev/null

tde_demo_clone "$target" "$source_node"
_tde_demo_compose up -d "$target"

tde_demo_wait_for "${target} standby" 120 \
  tde_demo_role_is "$target" standby

tde_demo_print_roles
