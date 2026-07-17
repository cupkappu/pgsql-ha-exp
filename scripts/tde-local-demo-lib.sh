#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TDE_LOCAL_DEMO_DIR="${SOURCE_DIR}/tde-local-demo"
TDE_LOCAL_DEMO_ENV="${TDE_LOCAL_DEMO_ENV:-${TDE_LOCAL_DEMO_DIR}/.env}"

if [[ ! -f "$TDE_LOCAL_DEMO_ENV" ]]; then
  TDE_LOCAL_DEMO_ENV="${TDE_LOCAL_DEMO_DIR}/.env.example"
fi

set -a
# shellcheck disable=SC1090
source "$TDE_LOCAL_DEMO_ENV"
set +a

PERCONA_POSTGRES_IMAGE="${PERCONA_POSTGRES_IMAGE:-percona/percona-distribution-postgresql:17.10-2-ubi8}"
POSTGRES_DB="${POSTGRES_DB:-appdb}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-local-demo-postgres}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-local-demo-replicator}"

TDE_LOCAL_PG1_DATA_VOLUME=pgsql-tde-local-demo-pg1-data
TDE_LOCAL_PG2_DATA_VOLUME=pgsql-tde-local-demo-pg2-data
TDE_LOCAL_PG1_KEYRING_VOLUME=pgsql-tde-local-demo-pg1-keyring
TDE_LOCAL_PG2_KEYRING_VOLUME=pgsql-tde-local-demo-pg2-keyring
TDE_LOCAL_KEYRING_BACKUP_VOLUME=pgsql-tde-local-demo-keyring-backup
TDE_LOCAL_KEYRING_FILE=principal.keyring

_tde_local_demo_compose() {
  docker compose \
    --env-file "$TDE_LOCAL_DEMO_ENV" \
    -f "$TDE_LOCAL_DEMO_DIR/compose.yml" \
    "$@"
}

tde_local_demo_wait_for() {
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

tde_local_demo_running() {
  local id
  id="$(_tde_local_demo_compose ps -q "$1" 2>/dev/null || true)"
  [[ -n "$id" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)" == true ]]
}

tde_local_demo_ready() {
  _tde_local_demo_compose exec -T "$1" \
    pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1
}

tde_local_demo_psql() {
  local node="$1"
  local database="$2"
  local sql="$3"

  _tde_local_demo_compose exec -T \
    -e "PGPASSWORD=${POSTGRES_PASSWORD}" \
    "$node" \
    psql -v ON_ERROR_STOP=1 -At \
      -U "$POSTGRES_USER" -d "$database" -c "$sql"
}

tde_local_demo_role() {
  local recovery
  if ! tde_local_demo_running "$1"; then
    printf '%s\n' stopped
    return 0
  fi

  recovery="$(tde_local_demo_psql "$1" "$POSTGRES_DB" 'SELECT pg_is_in_recovery()' 2>/dev/null || true)"
  case "$recovery" in
    f) printf '%s\n' primary ;;
    t) printf '%s\n' standby ;;
    *) printf '%s\n' starting ;;
  esac
}

tde_local_demo_role_is() {
  [[ "$(tde_local_demo_role "$1")" == "$2" ]]
}

tde_local_demo_sql_equals() {
  local node="$1"
  local database="$2"
  local sql="$3"
  local expected="$4"

  [[ "$(tde_local_demo_psql "$node" "$database" "$sql")" == "$expected" ]]
}

tde_local_demo_primary_node() {
  local node
  for node in pg1 pg2; do
    if [[ "$(tde_local_demo_role "$node")" == primary ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

tde_local_demo_standby_node() {
  local node
  for node in pg1 pg2; do
    if [[ "$(tde_local_demo_role "$node")" == standby ]]; then
      printf '%s\n' "$node"
      return 0
    fi
  done
  return 1
}

tde_local_demo_data_volume() {
  case "$1" in
    pg1) printf '%s\n' "$TDE_LOCAL_PG1_DATA_VOLUME" ;;
    pg2) printf '%s\n' "$TDE_LOCAL_PG2_DATA_VOLUME" ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

tde_local_demo_keyring_volume() {
  case "$1" in
    pg1) printf '%s\n' "$TDE_LOCAL_PG1_KEYRING_VOLUME" ;;
    pg2) printf '%s\n' "$TDE_LOCAL_PG2_KEYRING_VOLUME" ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

tde_local_demo_slot_name() {
  case "$1" in
    pg1) printf '%s\n' pg1_slot ;;
    pg2) printf '%s\n' pg2_slot ;;
    *) echo "unknown node: $1" >&2; return 1 ;;
  esac
}

tde_local_demo_data_initialized() {
  local volume
  volume="$(tde_local_demo_data_volume "$1")"
  docker volume inspect "$volume" >/dev/null 2>&1 || return 1
  docker run --rm \
    -v "${volume}:/check:ro" \
    --entrypoint test \
    "$PERCONA_POSTGRES_IMAGE" \
    -f /check/PG_VERSION >/dev/null 2>&1
}

tde_local_demo_prepare_keyring_volume() {
  local volume="$1"
  docker volume create "$volume" >/dev/null
  docker run --rm --user root \
    -v "${volume}:/keyring" \
    --entrypoint bash \
    "$PERCONA_POSTGRES_IMAGE" \
    -ceu 'chown 26:26 /keyring; chmod 0700 /keyring'
}

tde_local_demo_prepare_all_keyring_volumes() {
  tde_local_demo_prepare_keyring_volume "$TDE_LOCAL_PG1_KEYRING_VOLUME"
  tde_local_demo_prepare_keyring_volume "$TDE_LOCAL_PG2_KEYRING_VOLUME"
  tde_local_demo_prepare_keyring_volume "$TDE_LOCAL_KEYRING_BACKUP_VOLUME"
}

tde_local_demo_keyring_present_in_volume() {
  local volume="$1"
  docker volume inspect "$volume" >/dev/null 2>&1 || return 1
  docker run --rm \
    -v "${volume}:/keyring:ro" \
    --entrypoint test \
    "$PERCONA_POSTGRES_IMAGE" \
    -s "/keyring/${TDE_LOCAL_KEYRING_FILE}" >/dev/null 2>&1
}

tde_local_demo_keyring_checksum() {
  local volume="$1"
  docker run --rm \
    -v "${volume}:/keyring:ro" \
    --entrypoint sha256sum \
    "$PERCONA_POSTGRES_IMAGE" \
    "/keyring/${TDE_LOCAL_KEYRING_FILE}" |
    awk '{print $1}'
}

tde_local_demo_copy_keyring_volume() {
  local source_volume="$1"
  local target_volume="$2"

  tde_local_demo_keyring_present_in_volume "$source_volume" || {
    echo "keyring file is missing from volume: ${source_volume}" >&2
    return 1
  }
  tde_local_demo_prepare_keyring_volume "$target_volume"

  docker run --rm --user root \
    -v "${source_volume}:/source:ro" \
    -v "${target_volume}:/target" \
    --entrypoint bash \
    "$PERCONA_POSTGRES_IMAGE" \
    -ceu "install -m 0600 -o 26 -g 26 /source/${TDE_LOCAL_KEYRING_FILE} /target/${TDE_LOCAL_KEYRING_FILE}"
}

tde_local_demo_backup_keyring() {
  local source_node="$1"
  local source_volume
  source_volume="$(tde_local_demo_keyring_volume "$source_node")"

  tde_local_demo_copy_keyring_volume \
    "$source_volume" \
    "$TDE_LOCAL_KEYRING_BACKUP_VOLUME"

  docker run --rm --user root \
    -v "${TDE_LOCAL_KEYRING_BACKUP_VOLUME}:/backup" \
    --entrypoint bash \
    "$PERCONA_POSTGRES_IMAGE" \
    -ceu "cd /backup; sha256sum ${TDE_LOCAL_KEYRING_FILE} > ${TDE_LOCAL_KEYRING_FILE}.sha256; chown 26:26 ${TDE_LOCAL_KEYRING_FILE}.sha256; chmod 0600 ${TDE_LOCAL_KEYRING_FILE}.sha256"
}

tde_local_demo_sync_keyring() {
  local source_node="$1"
  local target_node="$2"
  local source_volume target_volume
  source_volume="$(tde_local_demo_keyring_volume "$source_node")"
  target_volume="$(tde_local_demo_keyring_volume "$target_node")"

  tde_local_demo_copy_keyring_volume "$source_volume" "$target_volume"
  tde_local_demo_backup_keyring "$source_node"
}

tde_local_demo_restore_keyring_from_backup() {
  local target_node="$1"
  local target_volume
  target_volume="$(tde_local_demo_keyring_volume "$target_node")"

  tde_local_demo_copy_keyring_volume \
    "$TDE_LOCAL_KEYRING_BACKUP_VOLUME" \
    "$target_volume"
}

tde_local_demo_keyrings_match() {
  local pg1_checksum pg2_checksum backup_checksum
  pg1_checksum="$(tde_local_demo_keyring_checksum "$TDE_LOCAL_PG1_KEYRING_VOLUME")"
  pg2_checksum="$(tde_local_demo_keyring_checksum "$TDE_LOCAL_PG2_KEYRING_VOLUME")"
  backup_checksum="$(tde_local_demo_keyring_checksum "$TDE_LOCAL_KEYRING_BACKUP_VOLUME")"
  [[ "$pg1_checksum" == "$pg2_checksum" && "$pg1_checksum" == "$backup_checksum" ]]
}

tde_local_demo_ensure_slot() {
  local primary="$1"
  local target="$2"
  local slot
  slot="$(tde_local_demo_slot_name "$target")"

  tde_local_demo_psql "$primary" postgres \
    "SELECT pg_create_physical_replication_slot('${slot}') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '${slot}');" >/dev/null
}

tde_local_demo_clone() {
  local target="$1"
  local source="$2"
  local slot data_volume keyring_volume
  slot="$(tde_local_demo_slot_name "$target")"
  data_volume="$(tde_local_demo_data_volume "$target")"
  keyring_volume="$(tde_local_demo_keyring_volume "$target")"

  if ! docker volume inspect "$data_volume" >/dev/null 2>&1; then
    _tde_local_demo_compose create "$target" >/dev/null
  fi

  _tde_local_demo_compose stop "$target" >/dev/null 2>&1 || true
  _tde_local_demo_compose rm -f "$target" >/dev/null 2>&1 || true

  tde_local_demo_prepare_keyring_volume "$keyring_volume"
  tde_local_demo_sync_keyring "$source" "$target"

  _tde_local_demo_compose exec -T "$source" \
    tar -C /data/db -cf - pg_tde |
    docker run --rm -i --user root \
      -v "${data_volume}:/target" \
      --entrypoint bash \
      "$PERCONA_POSTGRES_IMAGE" \
      -lc 'tar -C /target -xf - && chown -R 26:26 /target'

  _tde_local_demo_compose run --rm --no-deps \
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

tde_local_demo_print_roles() {
  printf '%-4s %-9s %-10s\n' NODE ROLE CONTAINER
  local node
  for node in pg1 pg2; do
    printf '%-4s %-9s %-10s\n' \
      "$node" \
      "$(tde_local_demo_role "$node")" \
      "$(tde_local_demo_running "$node" && printf running || printf stopped)"
  done
}
