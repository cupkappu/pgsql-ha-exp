#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib.sh

cluster_has_primary_and_replica
etcd_cluster_healthy
witness_running

cleanup() {
  docker start "$WITNESS" >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf '%s\n' '[witness-failure] stopping external etcd witness'
docker stop "$WITNESS" >/dev/null
sleep 8

printf '%s\n' '[witness-failure] checking quorum through the two database-host members'
inner_docker host1 exec etcd etcdctl \
  --dial-timeout=2s \
  --command-timeout=4s \
  --endpoints=http://172.31.100.11:2379,http://172.31.100.12:2379 \
  endpoint health >/dev/null

cluster_has_primary_and_replica
marker="witness-down-$(date +%s)-$RANDOM"
psql_write app appdb \
  'CREATE TABLE IF NOT EXISTS ha_probe (id bigserial PRIMARY KEY, marker text UNIQUE NOT NULL, created_at timestamptz NOT NULL DEFAULT now())' \
  apppass >/dev/null
psql_write app appdb "INSERT INTO ha_probe(marker) VALUES ('$marker')" apppass >/dev/null

printf '%s\n' '[witness-failure] restarting witness'
docker start "$WITNESS" >/dev/null
trap - EXIT

wait_for 'witness rejoin' 90 etcd_cluster_healthy
cluster_has_primary_and_replica
printf '%s\n' '[PASS] witness failure tolerated and recovered'
