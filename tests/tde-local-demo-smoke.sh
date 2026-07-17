#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tde-local-demo-lib.sh
source "${ROOT}/scripts/tde-local-demo-lib.sh"

primary="$(tde_local_demo_primary_node)"
standby="$(tde_local_demo_standby_node)"

[[ "$primary" == pg1 ]]
[[ "$standby" == pg2 ]]

for node in "$primary" "$standby"; do
  [[ "$(tde_local_demo_psql "$node" "$POSTGRES_DB" 'SHOW pg_tde.wal_encrypt')" == on ]]
  [[ "$(tde_local_demo_psql "$node" "$POSTGRES_DB" "SELECT pg_tde_is_encrypted('embeddings')")" == t ]]
  [[ "$(tde_local_demo_psql "$node" "$POSTGRES_DB" "SELECT count(*) FROM pg_extension WHERE extname IN ('pg_tde', 'vector')")" == 2 ]]
  [[ "$(tde_local_demo_psql "$node" "$POSTGRES_DB" "SELECT type FROM pg_tde_list_all_global_key_providers() WHERE name = 'local-keyring'")" == file ]]
  [[ "$(tde_local_demo_psql "$node" "$POSTGRES_DB" "SELECT options::text LIKE '%/run/pg-tde-keyring/principal.keyring%' FROM pg_tde_list_all_global_key_providers() WHERE name = 'local-keyring'")" == t ]]
  tde_local_demo_psql "$node" "$POSTGRES_DB" 'SELECT pg_tde_verify_default_key()' >/dev/null
  tde_local_demo_psql "$node" "$POSTGRES_DB" 'SELECT pg_tde_verify_server_key()' >/dev/null
done

[[ "$(tde_local_demo_psql "$primary" postgres "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'")" == 1 ]]
[[ "$(tde_local_demo_psql "$primary" "$POSTGRES_DB" "SELECT content FROM embeddings ORDER BY embedding <=> '[0.9,0.1,0]' LIMIT 1")" == alpha ]]
tde_local_demo_keyrings_match

marker="local-smoke-$(date +%s)"
tde_local_demo_psql "$primary" "$POSTGRES_DB" \
  "INSERT INTO embeddings(content, embedding) VALUES ('${marker}', '[0.8,0.2,0]')" >/dev/null

tde_local_demo_wait_for "encrypted row replication" 60 \
  tde_local_demo_sql_equals \
    "$standby" \
    "$POSTGRES_DB" \
    "SELECT count(*) FROM embeddings WHERE content = '${marker}'" \
    1

echo '[PASS] local keyring TDE, pgvector and streaming replication passed'
