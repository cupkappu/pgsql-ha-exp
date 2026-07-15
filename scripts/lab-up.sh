#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="/var/lib/pgsql-ha-exp/lab"
install -d -m 0755 "$RUNTIME_DIR"
if [[ "$SOURCE_DIR" != "$RUNTIME_DIR" ]]; then
  cp -a "$SOURCE_DIR"/. "$RUNTIME_DIR"/
fi
cd "$RUNTIME_DIR"
source scripts/lib.sh

printf '%s\n' '[1/7] building outer Docker-host image'
docker build --network host -t pgsql-ha-dind:local images/dind

printf '%s\n' '[2/7] building Patroni/PostgreSQL image'
docker build --network host -t "$PATRONI_IMAGE" images/patroni

printf '%s\n' '[3/7] pulling runtime images'
docker pull "$ETCD_IMAGE" >/dev/null
docker pull "$HAPROXY_IMAGE" >/dev/null
docker pull "$CLIENT_IMAGE" >/dev/null

install -d -m 0755 \
  /var/lib/pgsql-ha-exp/host1-docker \
  /var/lib/pgsql-ha-exp/host2-docker \
  /var/lib/pgsql-ha-exp/witness-etcd

if ! docker container inspect "$HOST1" "$HOST2" "$WITNESS" >/dev/null 2>&1; then
  printf '%s\n' '[4/7] deploying two independent Docker hosts and the etcd witness'
  containerlab destroy -t "$TOPOLOGY" --cleanup >/dev/null 2>&1 || true
  containerlab deploy -t "$TOPOLOGY"
else
  printf '%s\n' '[4/7] containerlab hosts already exist; reusing them'
fi

for host in host1 host2; do
  wait_for "inner dockerd on ${host}" 90 outer_docker_ready "$host"
done

printf '%s\n' '[5/7] loading service images into both independent Docker daemons'
for host in host1 host2; do
  outer="$(outer_name "$host")"
  docker save "$PATRONI_IMAGE" "$ETCD_IMAGE" "$HAPROXY_IMAGE" | \
    docker exec -i "$outer" docker load >/dev/null
  docker exec "$outer" bash /lab/scripts/host-stack.sh "$host" etcd
done

wait_for 'three-member etcd cluster' 90 etcd_cluster_healthy

printf '%s\n' '[6/7] starting Patroni/PostgreSQL and HAProxy on both hosts'
for host in host1 host2; do
  outer="$(outer_name "$host")"
  docker exec "$outer" bash /lab/scripts/host-stack.sh "$host" patroni
done

wait_for 'one primary and one replica' 180 cluster_has_primary_and_replica

for host in host1 host2; do
  outer="$(outer_name "$host")"
  docker exec "$outer" bash /lab/scripts/host-stack.sh "$host" haproxy
done

wait_for 'HAProxy PostgreSQL write endpoint' 90 \
  psql_write postgres postgres 'SELECT 1' postgres

printf '%s\n' '[7/7] creating experiment application role and database'
if [[ "$(psql_write postgres postgres "SELECT 1 FROM pg_roles WHERE rolname='app'" postgres)" != '1' ]]; then
  psql_write postgres postgres "CREATE ROLE app LOGIN PASSWORD 'apppass'" postgres >/dev/null
fi

if [[ "$(psql_write postgres postgres "SELECT 1 FROM pg_database WHERE datname='appdb'" postgres)" != '1' ]]; then
  psql_write postgres postgres 'CREATE DATABASE appdb OWNER app' postgres >/dev/null
fi

printf '%s\n' 'cluster ready'
print_roles
printf '%s\n' 'write endpoints: 127.0.0.1:15000 and 127.0.0.1:25000'
printf '%s\n' 'read endpoints:  127.0.0.1:15001 and 127.0.0.1:25001'
