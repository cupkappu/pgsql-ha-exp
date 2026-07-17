#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tde-local-demo-lib.sh
source "${ROOT}/scripts/tde-local-demo-lib.sh"

[[ "$(tde_local_demo_role pg1)" == primary ]]
[[ "$(tde_local_demo_role pg2)" == standby ]]

_tde_local_demo_compose stop pg1
bash "${ROOT}/scripts/tde-local-demo-promote.sh" pg2

marker="local-failover-$(date +%s)"
tde_local_demo_psql pg2 "$POSTGRES_DB" \
  "INSERT INTO embeddings(content, embedding) VALUES ('${marker}', '[0.7,0.3,0]')" >/dev/null

[[ "$(tde_local_demo_psql pg2 "$POSTGRES_DB" "SELECT count(*) FROM embeddings WHERE content = '${marker}'")" == 1 ]]
[[ "$(tde_local_demo_psql pg2 "$POSTGRES_DB" "SELECT pg_tde_is_encrypted('embeddings')")" == t ]]

bash "${ROOT}/scripts/tde-local-demo-rejoin.sh" pg1

tde_local_demo_wait_for "failover row on rejoined pg1" 60 \
  tde_local_demo_sql_equals \
    pg1 \
    "$POSTGRES_DB" \
    "SELECT count(*) FROM embeddings WHERE content = '${marker}'" \
    1

[[ "$(tde_local_demo_role pg1)" == standby ]]
[[ "$(tde_local_demo_role pg2)" == primary ]]
tde_local_demo_keyrings_match

echo '[PASS] local keyring TDE failover and rejoin passed'
