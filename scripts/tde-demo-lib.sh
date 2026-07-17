#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDE_DEMO_DIR="${SOURCE_DIR}/tde-demo"
TDE_DEMO_ENV="${TDE_DEMO_ENV:-${TDE_DEMO_DIR}/.env}"

if [[ ! -f "$TDE_DEMO_ENV" ]]; then
  TDE_DEMO_ENV="${TDE_DEMO_DIR}/.env.example"
fi

set -a
# shellcheck disable=SC1090
source "$TDE_DEMO_ENV"
set +a

PERCONA_POSTGRES_IMAGE="${PERCONA_POSTGRES_IMAGE:-percona/percona-distribution-postgresql:17.10-2-ubi8}"
POSTGRES_DB="${POSTGRES_DB:-appdb}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-replicator}"

TDE_PG1_VOLUME=pgsql-tde-demo-pg1-data
TDE_PG2_VOLUME=pgsql-tde-demo-pg2-data

_tde_demo_compose() {
  docker compose \
    --env-file "$TDE_DEMO_ENV" \
    -f "$TDE_DEMO_DIR/compose.yml" \
    "$@"
}

tde_demo_wait_for() {
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

tde_demo_running() {
  local id
  id="$(_tde_demo_compose ps -q "$1" 2>/dev/null || true)"
  [[ -n "$id" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)" == true ]]
}

tde_demo_ready() {
  _tde_demo_compose exec -T "$1" \
    pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1
}

tde_demo_psql() {
  local node="$1"
  local database="$2"
  local sql="$3"

  _tde_demo_compose exec -T \
    -e "PGPASSWORD=${POSTGRES_PASSWORD}" \
    "$node" \
    psql -v ON_ERROR_STOP=1 -At \
      -U "$POSTGRES_USER" -d "$database" -c "$sql"
}

tde_demo_role() {
  local recovery
  if ! tde_demo_running "$1"; then
    printf '%s\n' stopped
    return 0
  fi

  recovery="$(tde_demo_psql "$1" "$POSTGRES_DB" 'SELECT pg_is_in_recovery()' 2>/dev/null || true)"
  case "$recovery" in
    f) printf '%s\n' primary ;;
    t) printf '%s\n' standby ;;
    *) printf '%s\n' starting ;;
  esac
}

tde_demo_role_is() {
  [[ "$(tde_demo_role "$1")" == "$2" ]]
}

tde_demo_sql_equals() {
  local node="$1"
  local database="$2"
  local sql="$3"
  local expected="$4"

  [[ "$(tde_demo_psql "$node" "$database" "$sql")" == "$expected" ]]
}

tde_demo_primary_node() {
  local node
  for node in pg1 pg2; do
    if [[ "$(tde_demo_role "$node")" == primary ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

tde_demo_standby_node() {
  local node
  for node in pg1 pg2; do
    if [[ "$(tde_demo_role "$node")" == standby ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

tde_demo_volume() {
  case "$1" in
    pg1) printf '%s\n' "$TDE_PG1_VOLUME" ;;
    pg2) printf '%s\n' "$TDE_PG2_VOLUME" ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

tde_demo_data_initialized() {
  local volume
  volume="$(tde_demo_volume "$1")"
  docker volume inspect "$volume" >/dev/null 2>&1 || return 1
  docker run --rm \
    -v "${volume}:/check:ro" \
    --entrypoint test \
    "$PERCONA_POSTGRES_IMAGE" \
    -f /check/PG_VERSION >/dev/null 2>&1
}

tde_demo_slot_name() {
  case "$1" in
    pg1) printf '%s\n' pg1_slot ;;
    pg2) printf '%s\n' pg2_slot ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

tde_demo_ensure_slot() {
  local primary="$1"
  local target="$2"
  local slot
  slot="$(tde_demo_slot_name "$target")"

  tde_demo_psql "$primary" postgres \
    "SELECT pg_create_physical_replication_slot('${slot}') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${slot}');" >/dev/null
}

tde_demo_clone() {
  local target="$1"
  local source="$2"
  local slot volume
  slot="$(tde_demo_slot_name "$target")"
  volume="$(tde_demo_volume "$target")"

  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    _tde_demo_compose create "$target" >/dev/null
  fi

  _tde_demo_compose stop "$target" >/dev/null 2>&1 || true
  _tde_demo_compose rm -f "$target" >/dev/null 2>&1 || true

  _tde_demo_compose exec -T "$source" \
    tar -C /data/db -cf - pg_tde |
    docker run --rm -i --user root \
      -v "${volume}:/target" \
      --entrypoint bash \
      "$PERCONA_POSTGRES_IMAGE" \
      -lc 'tar -C /target -xf - && chown -R 26:26 /target'

  _tde_demo_compose run --rm --no-deps \
    --entrypoint pg_tde_basebackup \
    -e "PGPASSWORD=${REPLICATION_PASSWORD}" \
    "$target" \
      -h "$source" \
      -U replicator \
      -D /data/db \
      -F p \
      -X stream \
      --encrypt-wal=aes_256 \
      -R \
      -S "$slot" \
      -P
}

tde_demo_print_roles() {
  printf '%-4s %-9s %-10s\n' NODE ROLE CONTAINER
  local node
  for node in pg1 pg2; do
    printf '%-4s %-9s %-10s\n' \
      "$node" \
      "$(tde_demo_role "$node")" \
      "$(tde_demo_running "$node" && printf running || printf stopped)"
  done
}
