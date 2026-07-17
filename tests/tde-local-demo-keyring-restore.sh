#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tde-local-demo-lib.sh
source "${ROOT}/scripts/tde-local-demo-lib.sh"

target="$(tde_local_demo_standby_node)"
[[ "$target" == pg1 ]]
keyring_volume="$(tde_local_demo_keyring_volume "$target")"

docker run --rm \
  -v "${TDE_LOCAL_KEYRING_BACKUP_VOLUME}:/backup:ro" \
  --entrypoint bash \
  "$PERCONA_POSTGRES_IMAGE" \
  -ceu "cd /backup; sha256sum -c ${TDE_LOCAL_KEYRING_FILE}.sha256"

_tde_local_demo_compose stop "$target" >/dev/null
_tde_local_demo_compose rm -f "$target" >/dev/null
docker volume rm -f "$keyring_volume" >/dev/null

_tde_local_demo_compose create "$target" >/dev/null
_tde_local_demo_compose start "$target" >/dev/null
sleep 8

if tde_local_demo_ready "$target"; then
  echo "${target} started without its local keyring" >&2
  exit 1
fi

startup_logs="$(_tde_local_demo_compose logs "$target" 2>&1)"
if ! grep -Eqi 'key|provider|principal' <<<"$startup_logs"; then
  echo "${target} did not report a key provider startup error" >&2
  exit 1
fi

_tde_local_demo_compose stop "$target" >/dev/null 2>&1 || true
_tde_local_demo_compose rm -f "$target" >/dev/null 2>&1 || true

tde_local_demo_restore_keyring_from_backup "$target"
_tde_local_demo_compose up -d --no-deps "$target"

tde_local_demo_wait_for "${target} after keyring restore" 120 \
  tde_local_demo_role_is "$target" standby

tde_local_demo_psql "$target" "$POSTGRES_DB" \
  'SELECT pg_tde_verify_default_key()' >/dev/null
tde_local_demo_psql "$target" "$POSTGRES_DB" \
  'SELECT pg_tde_verify_server_key()' >/dev/null
tde_local_demo_keyrings_match

echo '[PASS] offline keyring backup restore passed'
