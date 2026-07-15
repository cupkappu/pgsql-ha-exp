#!/usr/bin/env bash
set -euo pipefail

LAB_NAME="pgsql-ha"
LAB_RUNTIME_ROOT="/var/lib/pgsql-ha-exp/lab"
TOPOLOGY="${LAB_RUNTIME_ROOT}/topology.clab.yml"
HOST1="clab-${LAB_NAME}-host1"
HOST2="clab-${LAB_NAME}-host2"
WITNESS="clab-${LAB_NAME}-witness"
ETCD_ENDPOINTS="http://172.31.100.11:2379,http://172.31.100.12:2379,http://172.31.100.13:2379"
ETCD_IMAGE="gcr.io/etcd-development/etcd:v3.5.21"
HAPROXY_IMAGE="haproxy:3.0-alpine"
PATRONI_IMAGE="pgsql-ha-patroni:local"
CLIENT_IMAGE="postgres:16-bookworm"

outer_name() {
  case "$1" in
    host1) printf '%s\n' "$HOST1" ;;
    host2) printf '%s\n' "$HOST2" ;;
    *) echo "unknown host: $1" >&2; return 1 ;;
  esac
}

other_host() {
  case "$1" in
    host1) printf '%s\n' host2 ;;
    host2) printf '%s\n' host1 ;;
    *) echo "unknown host: $1" >&2; return 1 ;;
  esac
}

host_ip() {
  case "$1" in
    host1) printf '%s\n' 10.10.0.1 ;;
    host2) printf '%s\n' 10.10.0.2 ;;
    *) echo "unknown host: $1" >&2; return 1 ;;
  esac
}

host_write_port() {
  case "$1" in
    host1) printf '%s\n' 15000 ;;
    host2) printf '%s\n' 25000 ;;
    *) echo "unknown host: $1" >&2; return 1 ;;
  esac
}

host_read_port() {
  case "$1" in
    host1) printf '%s\n' 15001 ;;
    host2) printf '%s\n' 25001 ;;
    *) echo "unknown host: $1" >&2; return 1 ;;
  esac
}

inner_docker() {
  local host="$1"
  shift
  docker exec "$(outer_name "$host")" docker "$@"
}

wait_for() {
  local description="$1"
  local timeout_seconds="$2"
  shift 2

  local deadline=$((SECONDS + timeout_seconds))
  while (( SECONDS < deadline )); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "timeout waiting for: ${description}" >&2
  return 1
}

outer_docker_ready() {
  local host="$1"
  inner_docker "$host" info >/dev/null 2>&1
}

patroni_json() {
  local host="$1"
  docker exec "$(outer_name "$host")" curl --max-time 2 -fsS http://127.0.0.1:8008/patroni
}

patroni_role() {
  local host="$1"
  patroni_json "$host" | jq -r '.role'
}

patroni_endpoint_ok() {
  local host="$1"
  local endpoint="$2"
  docker exec "$(outer_name "$host")" \
    curl --max-time 2 -fsS "http://127.0.0.1:8008/${endpoint}" >/dev/null 2>&1
}

role_is() {
  local host="$1"
  local expected="$2"
  case "$expected" in
    primary|replica) patroni_endpoint_ok "$host" "$expected" ;;
    *) [[ "$(patroni_role "$host" 2>/dev/null || true)" == "$expected" ]] ;;
  esac
}

leader_host() {
  local host
  for host in host1 host2; do
    if role_is "$host" primary; then
      printf '%s\n' "$host"
      return 0
    fi
  done
  return 1
}

cluster_has_primary_and_replica() {
  if patroni_endpoint_ok host1 primary && patroni_endpoint_ok host2 replica; then
    return 0
  fi
  patroni_endpoint_ok host1 replica && patroni_endpoint_ok host2 primary
}

etcd_cluster_healthy() {
  inner_docker host1 exec etcd etcdctl \
    --endpoints="$ETCD_ENDPOINTS" \
    endpoint health >/dev/null 2>&1
}

etcd_endpoint_status() {
  inner_docker host1 exec etcd etcdctl \
    --endpoints="$ETCD_ENDPOINTS" \
    endpoint status --cluster -w table
}

witness_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$WITNESS" 2>/dev/null || true)" == "true" ]]
}

psql_port() {
  local port="$1"
  local user="$2"
  local database="$3"
  local sql="$4"
  local password="$5"

  docker run --rm --network host \
    -e "PGPASSWORD=${password}" \
    -e PGCONNECT_TIMEOUT=3 \
    "$CLIENT_IMAGE" \
    psql -v ON_ERROR_STOP=1 -At \
      -h 127.0.0.1 -p "$port" -U "$user" -d "$database" \
      -c "$sql"
}

psql_write() {
  local user="$1"
  local database="$2"
  local sql="$3"
  local password="$4"
  local port

  for port in 15000 25000; do
    if psql_port "$port" "$user" "$database" "$sql" "$password"; then
      return 0
    fi
  done
  return 1
}

print_roles() {
  local host role
  for host in host1 host2; do
    role="$(patroni_role "$host" 2>/dev/null || true)"
    printf '%-6s %s\n' "$host" "${role:-unreachable}"
  done
}
