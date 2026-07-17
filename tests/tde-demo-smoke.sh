#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tde-demo-lib.sh
source "${ROOT}/scripts/tde-demo-lib.sh"

primary="$(tde_demo_primary_node)"
standby="$(tde_demo_standby_node)"

[[ "$primary" == pg1 ]]
[[ "$standby" == pg2 ]]

for node in "$primary" "$standby"; do
  [[ "$(tde_demo_psql "$node" "$POSTGRES_DB" 'SHOW pg_tde.wal_encrypt')" == on ]]
  [[ "$(tde_demo_psql "$node" "$POSTGRES_DB" "SELECT pg_tde_is_encrypted('embeddings')")" == t ]]
  [[ "$(tde_demo_psql "$node" "$POSTGRES_DB" "SELECT count(*) FROM pg_extension WHERE extname IN ('pg_tde', 'vector')")" == 2 ]]
  tde_demo_psql "$node" "$POSTGRES_DB" 'SELECT pg_tde_verify_default_key()' >/dev/null
  tde_demo_psql "$node" "$POSTGRES_DB" 'SELECT pg_tde_verify_server_key()' >/dev/null
done

[[ "$(tde_demo_psql "$primary" postgres "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'")" == 1 ]]
[[ "$(tde_demo_psql "$primary" "$POSTGRES_DB" "SELECT content FROM embeddings ORDER BY embedding <=> '[0.9,0.1,0]' LIMIT 1")" == alpha ]]

marker="smoke-$(date +%s)"
tde_demo_psql "$primary" "$POSTGRES_DB" \
  "INSERT INTO embeddings(content, embedding) VALUES ('${marker}', '[0.8,0.2,0]')" >/dev/null

tde_demo_wait_for "encrypted row replication" 60 \
  tde_demo_sql_equals \
    "$standby" \
    "$POSTGRES_DB" \
    "SELECT count(*) FROM embeddings WHERE content = '${marker}'" \
    1

echo '[PASS] TDE, WAL encryption, pgvector and streaming replication passed'
