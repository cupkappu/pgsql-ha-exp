#!/usr/bin/env bash
set -euo pipefail

PCMK_LAB_NAME="pgsql-pcmk"
PCMK_RUNTIME_ROOT="/var/lib/pgsql-ha-exp-pcmk/lab"
PCMK_TOPOLOGY="${PCMK_RUNTIME_ROOT}/topology-pacemaker.clab.yml"
PCMK_DB1="clab-${PCMK_LAB_NAME}-db1"
PCMK_DB2="clab-${PCMK_LAB_NAME}-db2"
PCMK_NETWORK="pgsql-pcmk-mgmt"
PCMK_VIP="172.31.110.100"
PCMK_CLIENT_IMAGE="postgres:16-bookworm"

pcmk_container() {
  case "$1" in
    db1) printf '%s\n' "$PCMK_DB1" ;;
    db2) printf '%s\n' "$PCMK_DB2" ;;
    *) echo "unknown Pacemaker node: $1" >&2; return 1 ;;
  esac
}

pcmk_other_node() {
  case "$1" in
    db1) printf '%s\n' db2 ;;
    db2) printf '%s\n' db1 ;;
    *) echo "unknown Pacemaker node: $1" >&2; return 1 ;;
  esac
}

pcmk_exec() {
  local node="$1"
  shift
  docker exec "$(pcmk_container "$node")" "$@"
}

pcmk_wait_for() {
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

pcmk_node_ready() {
  local node="$1"
  pcmk_exec "$node" corosync-quorumtool -s >/dev/null 2>&1
}

pcmk_cluster_ready() {
  pcmk_exec db1 corosync-quorumtool -s 2>/dev/null | grep -q 'Nodes:[[:space:]]*2' \
    && pcmk_exec db1 corosync-quorumtool -s 2>/dev/null | grep -q 'Quorate:[[:space:]]*Yes'
}

pcmk_status_text() {
  pcmk_exec db1 crm_mon -1 -r -f
}

pcmk_primary_node() {
  local node recovery
  for node in db1 db2; do
    recovery="$(pcmk_exec "$node" runuser -u postgres -- psql -At -d postgres -c 'SELECT pg_is_in_recovery()' 2>/dev/null || true)"
    if [[ "$recovery" == 'f' ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

pcmk_has_primary_and_standby() {
  local r1 r2
  r1="$(pcmk_exec db1 runuser -u postgres -- psql -At -d postgres -c 'SELECT pg_is_in_recovery()' 2>/dev/null || true)"
  r2="$(pcmk_exec db2 runuser -u postgres -- psql -At -d postgres -c 'SELECT pg_is_in_recovery()' 2>/dev/null || true)"
  [[ "$r1 $r2" == 'f t' || "$r1 $r2" == 't f' ]]
}

pcmk_vip_query() {
  local sql="$1"
  local user="${2:-app}"
  local database="${3:-appdb}"
  local password="${4:-apppass}"
  docker run --rm --network "$PCMK_NETWORK" \
    -e "PGPASSWORD=$password" -e PGCONNECT_TIMEOUT=3 \
    "$PCMK_CLIENT_IMAGE" \
    psql -v ON_ERROR_STOP=1 -At -h "$PCMK_VIP" -p 5432 -U "$user" -d "$database" -c "$sql"
}

pcmk_vip_writable() {
  [[ "$(pcmk_vip_query 'SELECT NOT pg_is_in_recovery()' 2>/dev/null || true)" == 't' ]]
}
