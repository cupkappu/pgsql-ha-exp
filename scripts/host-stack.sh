#!/usr/bin/env bash
set -euo pipefail

host="${1:?usage: host-stack.sh <host1|host2> <action>}"
action="${2:?usage: host-stack.sh <host1|host2> <action>}"

case "$host" in
  host1)
    node_name="pg1"
    node_ip="10.10.0.1"
    etcd_ip="172.31.100.11"
    etcd_name="etcd1"
    patroni_config="/lab/config/patroni/pg1.yml"
    ;;
  host2)
    node_name="pg2"
    node_ip="10.10.0.2"
    etcd_ip="172.31.100.12"
    etcd_name="etcd2"
    patroni_config="/lab/config/patroni/pg2.yml"
    ;;
  *)
    echo "unknown host: $host" >&2
    exit 1
    ;;
esac

ETCD_IMAGE="gcr.io/etcd-development/etcd:v3.5.21"
HAPROXY_IMAGE="haproxy:3.0-alpine"
PATRONI_IMAGE="pgsql-ha-patroni:local"

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

start_etcd() {
  docker volume create etcd-data >/dev/null
  if container_exists etcd; then
    docker start etcd >/dev/null 2>&1 || true
    return
  fi

  docker run -d \
    --name etcd \
    --restart unless-stopped \
    --network host \
    -v etcd-data:/etcd-data \
    "$ETCD_IMAGE" \
    /usr/local/bin/etcd \
      --name "$etcd_name" \
      --data-dir /etcd-data \
      --listen-client-urls http://0.0.0.0:2379 \
      --advertise-client-urls "http://${etcd_ip}:2379" \
      --listen-peer-urls http://0.0.0.0:2380 \
      --initial-advertise-peer-urls "http://${etcd_ip}:2380" \
      --initial-cluster "etcd1=http://172.31.100.11:2380,etcd2=http://172.31.100.12:2380,etcd3=http://172.31.100.13:2380" \
      --initial-cluster-state new \
      --initial-cluster-token pgsql-ha-etcd \
      --auto-compaction-retention 1 \
      --auto-compaction-mode periodic >/dev/null
}

start_patroni() {
  docker volume create pgdata >/dev/null
  if container_exists patroni; then
    docker start patroni >/dev/null 2>&1 || true
    return
  fi

  docker run -d \
    --name patroni \
    --restart unless-stopped \
    --network host \
    -e MALLOC_ARENA_MAX=1 \
    -e PG_MALLOC_ARENA_MAX= \
    -v pgdata:/var/lib/postgresql/data \
    -v "${patroni_config}:/etc/patroni.yml:ro" \
    "$PATRONI_IMAGE" \
    /etc/patroni.yml >/dev/null
}

start_haproxy() {
  docker rm -f haproxy >/dev/null 2>&1 || true
  docker run -d \
    --name haproxy \
    --restart unless-stopped \
    --network host \
    -v /lab/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
    "$HAPROXY_IMAGE" >/dev/null
}

case "$action" in
  etcd)
    start_etcd
    ;;
  patroni)
    start_patroni
    ;;
  haproxy)
    start_haproxy
    ;;
  all)
    start_etcd
    start_patroni
    start_haproxy
    ;;
  stop-patroni)
    docker stop patroni >/dev/null
    ;;
  start-patroni)
    start_patroni
    ;;
  restart-patroni)
    docker restart patroni >/dev/null
    ;;
  status)
    printf 'host=%s node=%s ip=%s\n' "$host" "$node_name" "$node_ip"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    ;;
  remove-services)
    docker rm -f haproxy patroni etcd >/dev/null 2>&1 || true
    ;;
  *)
    echo "unknown action: $action" >&2
    exit 1
    ;;
esac
