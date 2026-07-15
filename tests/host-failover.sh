#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib.sh

cluster_has_primary_and_replica
etcd_cluster_healthy
witness_running

failed_host="$(leader_host)"
survivor="$(other_host "$failed_host")"
failed_outer="$(outer_name "$failed_host")"
survivor_port="$(host_write_port "$survivor")"
probe_before="host-failover-before-$(date +%s)-$RANDOM"
probe_after="host-failover-after-$(date +%s)-$RANDOM"

cleanup() {
  docker unpause "$failed_outer" >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql_write app appdb \
  'CREATE TABLE IF NOT EXISTS ha_probe (id bigserial PRIMARY KEY, marker text UNIQUE NOT NULL, created_at timestamptz NOT NULL DEFAULT now())' \
  apppass >/dev/null
psql_write app appdb "INSERT INTO ha_probe(marker) VALUES ('$probe_before')" apppass >/dev/null

printf '[host-failover] pausing entire primary host: %s\n' "$failed_host"
docker pause "$failed_outer" >/dev/null

wait_for "${survivor} promotion with witness quorum" 90 role_is "$survivor" primary
wait_for "${survivor} HAProxy write backend" 30 \
  psql_port "$survivor_port" app appdb 'SELECT 1' apppass
printf '[host-failover] promoted primary: %s\n' "$survivor"

psql_port "$survivor_port" app appdb \
  "INSERT INTO ha_probe(marker) VALUES ('$probe_after')" apppass >/dev/null

before_count="$(psql_port "$survivor_port" app appdb "SELECT count(*) FROM ha_probe WHERE marker='$probe_before'" apppass)"
after_count="$(psql_port "$survivor_port" app appdb "SELECT count(*) FROM ha_probe WHERE marker='$probe_after'" apppass)"
[[ "$before_count" == '1' && "$after_count" == '1' ]]

printf '[host-failover] restoring former primary: %s\n' "$failed_host"
docker unpause "$failed_outer" >/dev/null
trap - EXIT

wait_for 'three-member etcd recovery' 90 etcd_cluster_healthy
wait_for 'former primary rejoins as replica' 180 cluster_has_primary_and_replica
role_is "$failed_host" replica
print_roles
printf '%s\n' '[PASS] full database-host failover passed with external etcd witness'
