#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANUAL_DEMO_DIR="${SOURCE_DIR}/manual-demo"
MANUAL_DEMO_ENV="${MANUAL_DEMO_ENV:-${MANUAL_DEMO_DIR}/.env}"

if [[ ! -f "$MANUAL_DEMO_ENV" ]]; then
  MANUAL_DEMO_ENV="${MANUAL_DEMO_DIR}/.env.example"
fi

set -a
# shellcheck disable=SC1090
source "$MANUAL_DEMO_ENV"
set +a

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-bookworm}"
POSTGRES_DB="${POSTGRES_DB:-appdb}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
APP_PASSWORD="${APP_PASSWORD:-apppass}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-replicator}"
DB1_PORT="${DB1_PORT:-35432}"
DB2_PORT="${DB2_PORT:-45432}"

manual_demo_compose() {
  docker compose \
    --env-file "$MANUAL_DEMO_ENV" \
    -f "$MANUAL_DEMO_DIR/compose.yml" \
    "$@"
}

manual_demo_other_node() {
  case "$1" in
    db1) printf '%s\n' db2 ;;
    db2) printf '%s\n' db1 ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

manual_demo_port() {
  case "$1" in
    db1) printf '%s\n' "$DB1_PORT" ;;
    db2) printf '%s\n' "$DB2_PORT" ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

manual_demo_volume() {
  case "$1" in
    db1) printf '%s\n' pgsql-manual-demo-db1-data ;;
    db2) printf '%s\n' pgsql-manual-demo-db2-data ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

manual_demo_wait_for() {
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

manual_demo_running() {
  [[ "$(manual_demo_compose ps -q "$1" 2>/dev/null)" != "" ]] &&
    [[ "$(docker inspect -f '{{.State.Running}}' "$(manual_demo_compose ps -q "$1")" 2>/dev/null || true)" == "true" ]]
}

manual_demo_ready() {
  manual_demo_compose exec -T "$1" \
    pg_isready -h 127.0.0.1 -U postgres -d postgres >/dev/null 2>&1
}

manual_demo_data_initialized() {
  local volume
  volume="$(manual_demo_volume "$1")"
  docker volume inspect "$volume" >/dev/null 2>&1 || return 1
  docker run --rm -v "${volume}:/data:ro" \
    --entrypoint test "$POSTGRES_IMAGE" \
    -f /data/pgdata/PG_VERSION >/dev/null 2>&1
}

manual_demo_psql() {
  local node="$1"
  local user="$2"
  local database="$3"
  local password="$4"
  local sql="$5"

  manual_demo_compose exec -T \
    -e "PGPASSWORD=${password}" \
    "$node" \
    psql -v ON_ERROR_STOP=1 -At \
      -h 127.0.0.1 -U "$user" -d "$database" -c "$sql"
}

manual_demo_role() {
  local recovery
  if ! manual_demo_running "$1"; then
    printf '%s\n' stopped
    return 0
  fi

  recovery="$(manual_demo_psql "$1" postgres postgres "$POSTGRES_PASSWORD" \
    'SELECT pg_is_in_recovery()' 2>/dev/null || true)"
  case "$recovery" in
    f) printf '%s\n' primary ;;
    t) printf '%s\n' standby ;;
    *) printf '%s\n' starting ;;
  esac
}

manual_demo_role_is() {
  [[ "$(manual_demo_role "$1")" == "$2" ]]
}

manual_demo_primary_node() {
  local node
  for node in db1 db2; do
    if [[ "$(manual_demo_role "$node")" == primary ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

manual_demo_standby_node() {
  local node
  for node in db1 db2; do
    if [[ "$(manual_demo_role "$node")" == standby ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

manual_demo_cluster_ready() {
  local primary_count=0
  local standby_count=0
  local node role

  for node in db1 db2; do
    role="$(manual_demo_role "$node")"
    [[ "$role" == primary ]] && primary_count=$((primary_count + 1))
    [[ "$role" == standby ]] && standby_count=$((standby_count + 1))
  done

  [[ "$primary_count" -eq 1 && "$standby_count" -eq 1 ]]
}

manual_demo_configure_primary() {
  local node="$1"

  # The quoted script expands inside the PostgreSQL container.
  # shellcheck disable=SC2016
  manual_demo_compose exec -T "$node" bash -ceu '
    hba=/var/lib/postgresql/data/pgdata/pg_hba.conf
    if ! grep -q "pgsql-manual-demo replication" "$hba"; then
      cat >> "$hba" <<"HBA"
# pgsql-manual-demo replication
host replication replicator 172.31.121.0/24 scram-sha-256
host all all 172.31.121.0/24 scram-sha-256
HBA
    fi
  '

  manual_demo_psql "$node" postgres postgres "$POSTGRES_PASSWORD" \
    'SELECT pg_reload_conf()' >/dev/null

  manual_demo_psql "$node" postgres postgres "$POSTGRES_PASSWORD" \
    "DO \$\$
     BEGIN
       IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
         CREATE ROLE replicator LOGIN REPLICATION PASSWORD '${REPLICATION_PASSWORD}';
       END IF;
       IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app') THEN
         CREATE ROLE app LOGIN PASSWORD '${APP_PASSWORD}';
       END IF;
     END
     \$\$;" >/dev/null

  manual_demo_psql "$node" postgres postgres "$POSTGRES_PASSWORD" \
    "ALTER DATABASE ${POSTGRES_DB} OWNER TO app" >/dev/null
}

manual_demo_clone() {
  local target="$1"
  local source="$2"
  local clone_service="clone-${target}-from-${source}"

  manual_demo_compose stop "$target" >/dev/null 2>&1 || true
  manual_demo_compose rm -f "$target" >/dev/null 2>&1 || true
  manual_demo_compose --profile tools run --rm --no-deps "$clone_service"
}

manual_demo_print_roles() {
  printf '%-4s %-9s %-12s %s\n' NODE ROLE CONTAINER CLIENT_PORT
  printf '%-4s %-9s %-12s %s\n' db1 "$(manual_demo_role db1)" \
    "$(manual_demo_running db1 && printf running || printf stopped)" "$DB1_PORT"
  printf '%-4s %-9s %-12s %s\n' db2 "$(manual_demo_role db2)" \
    "$(manual_demo_running db2 && printf running || printf stopped)" "$DB2_PORT"
}
