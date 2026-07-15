#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib.sh

printf '%s\n' '[smoke] checking independent Docker daemons'
id1="$(inner_docker host1 info --format '{{.ID}}')"
id2="$(inner_docker host2 info --format '{{.ID}}')"
[[ -n "$id1" && -n "$id2" && "$id1" != "$id2" ]]
printf 'host1 daemon: %s\nhost2 daemon: %s\n' "$id1" "$id2"

printf '%s\n' '[smoke] checking etcd quorum'
etcd_cluster_healthy

printf '%s\n' '[smoke] checking Patroni roles'
cluster_has_primary_and_replica
print_roles

printf '%s\n' '[smoke] checking both HAProxy write endpoints'
for port in 15000 25000; do
  result="$(psql_port "$port" app appdb 'SELECT NOT pg_is_in_recovery()' apppass)"
  [[ "$result" == 't' ]]
done

printf '%s\n' '[smoke] writing replicated probe row'
probe="smoke-$(date +%s)-$RANDOM"
psql_write app appdb \
  'CREATE TABLE IF NOT EXISTS ha_probe (id bigserial PRIMARY KEY, marker text UNIQUE NOT NULL, created_at timestamptz NOT NULL DEFAULT now())' \
  apppass >/dev/null
psql_write app appdb "INSERT INTO ha_probe(marker) VALUES ('$probe')" apppass >/dev/null

printf '%s\n' '[smoke] checking replica read endpoints'
for port in 15001 25001; do
  wait_for "replica endpoint ${port}" 30 \
    psql_port "$port" app appdb "SELECT marker FROM ha_probe WHERE marker='$probe'" apppass
  result="$(psql_port "$port" app appdb "SELECT marker FROM ha_probe WHERE marker='$probe'" apppass)"
  [[ "$result" == "$probe" ]]
  recovery="$(psql_port "$port" app appdb 'SELECT pg_is_in_recovery()' apppass)"
  [[ "$recovery" == 't' ]]
done

printf '%s\n' '[PASS] smoke test passed'
