#!/usr/bin/env bash
set -euo pipefail

MANUAL_LAB_NAME="pgsql-manual"
MANUAL_RUNTIME_ROOT="/var/lib/pgsql-ha-manual/lab"
MANUAL_TOPOLOGY="${MANUAL_RUNTIME_ROOT}/topology-manual.clab.yml"
MANUAL_DB1="clab-${MANUAL_LAB_NAME}-db1"
MANUAL_DB2="clab-${MANUAL_LAB_NAME}-db2"
MANUAL_POSTGRES_IMAGE="postgres:16-bookworm"
MANUAL_CONTAINER="postgres"
MANUAL_SUPERUSER_PASSWORD="postgres"
MANUAL_REPLICATION_PASSWORD="replicator"
MANUAL_APP_PASSWORD="apppass"

manual_outer_name() {
  case "$1" in
    db1) printf '%s\n' "$MANUAL_DB1" ;;
    db2) printf '%s\n' "$MANUAL_DB2" ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

manual_other_node() {
  case "$1" in
    db1) printf '%s\n' db2 ;;
    db2) printf '%s\n' db1 ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

manual_node_ip() {
  case "$1" in
    db1) printf '%s\n' 172.31.120.11 ;;
    db2) printf '%s\n' 172.31.120.12 ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

manual_node_port() {
  case "$1" in
    db1) printf '%s\n' 35432 ;;
    db2) printf '%s\n' 45432 ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

manual_inner_docker() {
  local node="$1"
  shift
  docker exec "$(manual_outer_name "$node")" docker "$@"
}

manual_wait_for() {
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

manual_outer_ready() {
  manual_inner_docker "$1" info >/dev/null 2>&1
}

manual_postgres_running() {
  [[ "$(manual_inner_docker "$1" inspect -f '{{.State.Running}}' "$MANUAL_CONTAINER" 2>/dev/null || true)" == "true" ]]
}

manual_data_initialized() {
  docker exec "$(manual_outer_name "$1")" test -f /var/lib/pgsql/PG_VERSION
}

manual_start_postgres() {
  local node="$1"

  manual_inner_docker "$node" rm -f "$MANUAL_CONTAINER" >/dev/null 2>&1 || true
  manual_inner_docker "$node" run -d \
    --name "$MANUAL_CONTAINER" \
    --restart no \
    --network host \
    -e "POSTGRES_PASSWORD=${MANUAL_SUPERUSER_PASSWORD}" \
    -e POSTGRES_DB=appdb \
    -v /var/lib/pgsql:/var/lib/postgresql/data \
    "$MANUAL_POSTGRES_IMAGE" \
    postgres \
      -c 'listen_addresses=*' \
      -c wal_level=replica \
      -c max_wal_senders=10 \
      -c max_replication_slots=10 \
      -c wal_log_hints=on \
      -c hot_standby=on \
      -c wal_keep_size=256MB >/dev/null
}

manual_postgres_ready() {
  manual_inner_docker "$1" exec "$MANUAL_CONTAINER" \
    pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1
}

manual_node_psql() {
  local node="$1"
  local user="$2"
  local database="$3"
  local password="$4"
  local sql="$5"

  manual_inner_docker "$node" exec \
    -e "PGPASSWORD=${password}" \
    "$MANUAL_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -At \
      -h 127.0.0.1 -U "$user" -d "$database" -c "$sql"
}

manual_role() {
  local recovery
  recovery="$(manual_node_psql "$1" postgres postgres "$MANUAL_SUPERUSER_PASSWORD" \
    'SELECT pg_is_in_recovery()' 2>/dev/null || true)"
  case "$recovery" in
    f) printf '%s\n' primary ;;
    t) printf '%s\n' standby ;;
    *) printf '%s\n' stopped ;;
  esac
}

manual_role_is() {
  [[ "$(manual_role "$1")" == "$2" ]]
}

manual_primary_node() {
  local node
  for node in db1 db2; do
    if [[ "$(manual_role "$node")" == primary ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

manual_standby_node() {
  local node
  for node in db1 db2; do
    if [[ "$(manual_role "$node")" == standby ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

manual_cluster_ready() {
  local primary_count=0
  local standby_count=0
  local node role

  for node in db1 db2; do
    role="$(manual_role "$node")"
    [[ "$role" == primary ]] && primary_count=$((primary_count + 1))
    [[ "$role" == standby ]] && standby_count=$((standby_count + 1))
  done

  [[ "$primary_count" -eq 1 && "$standby_count" -eq 1 ]]
}

manual_client_psql() {
  local node="$1"
  local user="$2"
  local database="$3"
  local password="$4"
  local sql="$5"

  docker run --rm --network host \
    -e "PGPASSWORD=${password}" \
    -e PGCONNECT_TIMEOUT=3 \
    "$MANUAL_POSTGRES_IMAGE" \
    psql -v ON_ERROR_STOP=1 -At \
      -h 127.0.0.1 -p "$(manual_node_port "$node")" \
      -U "$user" -d "$database" -c "$sql"
}

manual_clone_from() {
  local target="$1"
  local source="$2"
  local source_ip
  source_ip="$(manual_node_ip "$source")"

  manual_inner_docker "$target" rm -f "$MANUAL_CONTAINER" >/dev/null 2>&1 || true
  manual_inner_docker "$target" run --rm \
    --network host \
    -v /var/lib/pgsql:/var/lib/postgresql/data \
    "$MANUAL_POSTGRES_IMAGE" \
    bash -ceu "
      find /var/lib/postgresql/data -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      chown postgres:postgres /var/lib/postgresql/data
      chmod 0700 /var/lib/postgresql/data
      exec gosu postgres pg_basebackup \\
        -d 'host=${source_ip} port=5432 user=replicator password=${MANUAL_REPLICATION_PASSWORD} application_name=${target}' \\
        -D /var/lib/postgresql/data \\
        -Fp -Xs -P -R
    "
}

manual_print_roles() {
  printf '%-4s %-8s %-15s %s\n' NODE ROLE REPLICATION_IP CLIENT_PORT
  printf '%-4s %-8s %-15s %s\n' db1 "$(manual_role db1)" "$(manual_node_ip db1)" "$(manual_node_port db1)"
  printf '%-4s %-8s %-15s %s\n' db2 "$(manual_role db2)" "$(manual_node_ip db2)" "$(manual_node_port db2)"
}
