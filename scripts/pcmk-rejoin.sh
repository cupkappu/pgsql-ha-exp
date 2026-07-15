#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/pcmk-lib.sh

node="${1:?usage: pcmk-rejoin.sh <db1|db2>}"
container="$(pcmk_container "$node")"
peer="$(pcmk_other_node "$node")"

if [[ "$(pcmk_primary_node 2>/dev/null || true)" != "$peer" ]]; then
  echo "${peer} is not the active PostgreSQL primary" >&2
  exit 1
fi

printf '[rejoin] starting fenced node in re-seed mode: %s\n' "$node"
docker start "$container" >/dev/null
pcmk_wait_for "${node} re-seed shell" 30 docker exec "$container" test -e /var/lib/postgresql/rejoin-required

printf '[rejoin] cloning current primary %s into %s\n' "$peer" "$node"
pcmk_exec "$node" bash /lab/scripts/pcmk-node-db.sh "$node" clone-standby
pcmk_exec "$node" rm -f /var/lib/postgresql/rejoin-required

printf '[rejoin] restarting %s into Corosync and Pacemaker\n' "$node"
docker restart "$container" >/dev/null
pcmk_wait_for "${node} Corosync rejoin" 90 pcmk_node_ready "$node"
pcmk_wait_for 'PostgreSQL primary and standby recovery' 240 pcmk_has_primary_and_standby
pcmk_wait_for 'VIP remains writable' 90 pcmk_vip_writable

pcmk_status_text
printf '[PASS] %s re-seeded and rejoined as standby\n' "$node"
