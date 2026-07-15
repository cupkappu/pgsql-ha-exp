#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/pcmk-lib.sh

pcmk_cluster_ready
pcmk_has_primary_and_standby
pcmk_vip_writable

failed="$(pcmk_primary_node)"
survivor="$(pcmk_other_node "$failed")"
failed_container="$(pcmk_container "$failed")"
before="pcmk-before-$(date +%s)-$RANDOM"
after="pcmk-after-$(date +%s)-$RANDOM"

pcmk_vip_query \
  'CREATE TABLE IF NOT EXISTS ha_probe (id bigserial PRIMARY KEY, marker text UNIQUE NOT NULL, created_at timestamptz NOT NULL DEFAULT now())' \
  >/dev/null
pcmk_vip_query "INSERT INTO ha_probe(marker) VALUES ('$before')" >/dev/null

printf '[pcmk-failover] fencing current primary %s from %s\n' "$failed" "$survivor"
pcmk_exec "$survivor" pcs stonith fence "$failed"

pcmk_wait_for "${failed} container power-off" 60 \
  bash -lc "[[ \"\$(docker inspect -f '{{.State.Running}}' '$failed_container' 2>/dev/null || true)\" == false ]]"
pcmk_wait_for "${survivor} promotion and VIP move" 180 pcmk_vip_writable
[[ "$(pcmk_primary_node)" == "$survivor" ]]

pcmk_vip_query "INSERT INTO ha_probe(marker) VALUES ('$after')" >/dev/null
before_count="$(pcmk_vip_query "SELECT count(*) FROM ha_probe WHERE marker='$before'")"
after_count="$(pcmk_vip_query "SELECT count(*) FROM ha_probe WHERE marker='$after'")"
[[ "$before_count" == '1' && "$after_count" == '1' ]]

printf '[pcmk-failover] re-seeding fenced node %s\n' "$failed"
bash scripts/pcmk-rejoin.sh "$failed"

pcmk_has_primary_and_standby
[[ "$(pcmk_primary_node)" == "$survivor" ]]
rejoined_before="$(pcmk_exec "$failed" runuser -u postgres -- psql -At -d appdb -c "SELECT count(*) FROM ha_probe WHERE marker='$before'")"
rejoined_after="$(pcmk_exec "$failed" runuser -u postgres -- psql -At -d appdb -c "SELECT count(*) FROM ha_probe WHERE marker='$after'")"
[[ "$rejoined_before" == '1' && "$rejoined_after" == '1' ]]

printf '%s\n' '[PASS] Pacemaker fencing, failover, VIP migration and rejoin passed'
