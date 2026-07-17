#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="${ROOT}/tde-local-demo"
ENV_FILE="${DEMO_DIR}/.env.example"
COMPOSE_FILE="${DEMO_DIR}/compose.yml"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config >/dev/null

grep -q 'shared_preload_libraries=pg_tde' "$COMPOSE_FILE" || fail 'pg_tde preload missing'
grep -q 'pg1-keyring:/run/pg-tde-keyring' "$COMPOSE_FILE" || fail 'pg1 keyring volume missing'
grep -q 'pg2-keyring:/run/pg-tde-keyring' "$COMPOSE_FILE" || fail 'pg2 keyring volume missing'
grep -q 'keyring-backup:' "$COMPOSE_FILE" || fail 'backup keyring volume missing'
grep -q 'pg_tde_add_global_key_provider_file' "${DEMO_DIR}/init-primary.sh" || fail 'file provider initialization missing'
grep -q '/run/pg-tde-keyring/principal.keyring' "${DEMO_DIR}/init-primary.sh" || fail 'keyring path missing'
grep -q 'CREATE EXTENSION vector' "${DEMO_DIR}/init-primary.sh" || fail 'pgvector initialization missing'
grep -q 'USING tde_heap' "${DEMO_DIR}/init-primary.sh" || fail 'encrypted table missing'
grep -q 'pg_tde_basebackup' "${ROOT}/scripts/tde-local-demo-lib.sh" || fail 'pg_tde_basebackup missing'
grep -q -- '--encrypt-wal=aes_256' "${ROOT}/scripts/tde-local-demo-lib.sh" || fail 'WAL encryption backup option missing'

if grep -Rqi 'openbao' \
  "$COMPOSE_FILE" \
  "${DEMO_DIR}/init-primary.sh" \
  "${ROOT}/scripts/tde-local-demo-"*.sh; then
  fail 'local keyring runtime references OpenBao'
fi

echo '[PASS] local keyring TDE demo static validation passed'
