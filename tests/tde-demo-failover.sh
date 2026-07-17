#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tde-demo-lib.sh
source "${ROOT}/scripts/tde-demo-lib.sh"

[[ "$(tde_demo_role pg1)" == primary ]]
[[ "$(tde_demo_role pg2)" == standby ]]

_tde_demo_compose stop pg1
bash "${ROOT}/scripts/tde-demo-promote.sh" pg2

[[ "$(tde_demo_role pg1)" == stopped ]]
[[ "$(tde_demo_role pg2)" == primary ]]

marker="failover-$(date +%s)"
tde_demo_psql pg2 "$POSTGRES_DB" \
  "INSERT INTO embeddings(content, embedding) VALUES ('${marker}', '[0.2,0.8,0]')" >/dev/null

bash "${ROOT}/scripts/tde-demo-rejoin.sh" pg1

[[ "$(tde_demo_role pg1)" == standby ]]
[[ "$(tde_demo_role pg2)" == primary ]]
[[ "$(tde_demo_psql pg1 "$POSTGRES_DB" "SELECT count(*) FROM embeddings WHERE content = '${marker}'")" == 1 ]]
[[ "$(tde_demo_psql pg1 "$POSTGRES_DB" "SELECT pg_tde_is_encrypted('embeddings')")" == t ]]
[[ "$(tde_demo_psql pg1 "$POSTGRES_DB" 'SHOW pg_tde.wal_encrypt')" == on ]]
[[ "$(tde_demo_psql pg2 postgres "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'")" == 1 ]]
[[ "$(tde_demo_psql pg1 "$POSTGRES_DB" "SELECT content FROM embeddings ORDER BY embedding <=> '[0.1,0.9,0]' LIMIT 1")" == beta ]]

echo '[PASS] TDE failover, encrypted write and pg_tde_basebackup rejoin passed'
