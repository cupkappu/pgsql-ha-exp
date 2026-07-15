#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib.sh

cluster_has_primary_and_replica
old_primary="$(leader_host)"
new_primary="$(other_host "$old_primary")"
old_outer="$(outer_name "$old_primary")"

printf '[failover] current primary: %s; candidate: %s\n' "$old_primary" "$new_primary"

before="before-$(date +%s)-$RANDOM"
psql_write app appdb \
  'CREATE TABLE IF NOT EXISTS ha_probe (id bigserial PRIMARY KEY, marker text UNIQUE NOT NULL, created_at timestamptz NOT NULL DEFAULT now())' \
  apppass >/dev/null
psql_write app appdb "INSERT INTO ha_probe(marker) VALUES ('$before')" apppass >/dev/null

printf '[failover] stopping Patroni/PostgreSQL container inside %s\n' "$old_primary"
docker exec "$old_outer" bash /lab/scripts/host-stack.sh "$old_primary" stop-patroni

wait_for "${new_primary} promotion" 90 role_is "$new_primary" primary
printf '[failover] promoted primary: %s\n' "$new_primary"

post="after-$(date +%s)-$RANDOM"
wait_for 'HAProxy write recovery' 60 \
  psql_write app appdb "INSERT INTO ha_probe(marker) VALUES ('$post')" apppass

for port in 15000 25000; do
  wait_for "write endpoint ${port} after failover" 30 \
    psql_port "$port" app appdb "SELECT marker FROM ha_probe WHERE marker='$post'" apppass
  result="$(psql_port "$port" app appdb "SELECT marker FROM ha_probe WHERE marker='$post'" apppass)"
  [[ "$result" == "$post" ]]
done

printf '[failover] restarting former primary %s\n' "$old_primary"
docker exec "$old_outer" bash /lab/scripts/host-stack.sh "$old_primary" start-patroni
wait_for "${old_primary} rejoining as replica" 180 role_is "$old_primary" replica
wait_for 'cluster convergence' 60 cluster_has_primary_and_replica

result="$(psql_write app appdb "SELECT marker FROM ha_probe WHERE marker='$before'" apppass)"
[[ "$result" == "$before" ]]
result="$(psql_write app appdb "SELECT marker FROM ha_probe WHERE marker='$post'" apppass)"
[[ "$result" == "$post" ]]

print_roles
printf '%s\n' '[PASS] PostgreSQL process failover passed'
