#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/pcmk-lib.sh

printf '%s\n' '[pcmk-smoke] checking Corosync and Pacemaker membership'
pcmk_cluster_ready
pcmk_has_primary_and_standby
pcmk_vip_writable

printf '%s\n' '[pcmk-smoke] checking peer fencing agent from both nodes'
for node in db1 db2; do
  pcmk_exec "$node" fence_peer_docker -o monitor
  pcmk_exec "$node" fence_peer_docker -o status -n "$(pcmk_container "$(pcmk_other_node "$node")")"
done

primary="$(pcmk_primary_node)"
standby="$(pcmk_other_node "$primary")"
marker="pcmk-smoke-$(date +%s)-$RANDOM"

printf '[pcmk-smoke] current primary: %s; standby: %s\n' "$primary" "$standby"
pcmk_vip_query \
  'CREATE TABLE IF NOT EXISTS ha_probe (id bigserial PRIMARY KEY, marker text UNIQUE NOT NULL, created_at timestamptz NOT NULL DEFAULT now())' \
  >/dev/null
pcmk_vip_query "INSERT INTO ha_probe(marker) VALUES ('$marker')" >/dev/null

pcmk_wait_for 'standby receives probe row' 30 \
  pcmk_exec "$standby" runuser -u postgres -- \
    psql -At -d appdb -c "SELECT marker FROM ha_probe WHERE marker='$marker'"
result="$(pcmk_exec "$standby" runuser -u postgres -- psql -At -d appdb -c "SELECT marker FROM ha_probe WHERE marker='$marker'")"
[[ "$result" == "$marker" ]]

pcmk_exec "$primary" ip -4 addr show dev eth0 | grep -q "$PCMK_VIP/24"
printf '%s\n' '[PASS] Pacemaker two-database smoke test passed'
