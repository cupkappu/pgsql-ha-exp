#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/tde-demo/.env.example"
COMPOSE_FILE="${ROOT}/tde-demo/compose.yml"

for script in \
  "${ROOT}/tde-demo/init-primary.sh" \
  "${ROOT}/scripts/tde-demo-lib.sh" \
  "${ROOT}/scripts/tde-demo-up.sh" \
  "${ROOT}/scripts/tde-demo-status.sh" \
  "${ROOT}/scripts/tde-demo-promote.sh" \
  "${ROOT}/scripts/tde-demo-rejoin.sh" \
  "${ROOT}/scripts/tde-demo-down.sh" \
  "${ROOT}/scripts/tde-demo-clean.sh" \
  "${ROOT}/tests/tde-demo-smoke.sh" \
  "${ROOT}/tests/tde-demo-failover.sh"; do
  bash -n "$script"
done

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config >/dev/null

grep -Fq 'percona/percona-distribution-postgresql:17.10-2-ubi8' "$ENV_FILE"
grep -Fq 'openbao/openbao:2.5.4' "$ENV_FILE"
grep -Fq 'shared_preload_libraries=pg_tde' "$COMPOSE_FILE"
grep -Fq 'bao policy write pg-tde' "$COMPOSE_FILE"
grep -Fq 'path "tde/data/*"' "${ROOT}/tde-demo/openbao-pg-tde-policy.hcl"
grep -Fq 'pg_tde_basebackup' "${ROOT}/scripts/tde-demo-lib.sh"
grep -Fq 'CREATE EXTENSION vector' "${ROOT}/tde-demo/init-primary.sh"
grep -Fq 'USING tde_heap' "${ROOT}/tde-demo/init-primary.sh"

echo '[PASS] TDE demo static validation passed'
