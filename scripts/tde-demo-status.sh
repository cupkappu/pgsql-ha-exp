#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/tde-demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tde-demo-lib.sh"

tde_demo_print_roles

for node in pg1 pg2; do
  if tde_demo_ready "$node"; then
    printf '\n[%s]\n' "$node"
    tde_demo_psql "$node" "$POSTGRES_DB" \
      "SELECT 'role=' || CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;
       SHOW pg_tde.wal_encrypt;
       SELECT extname || '=' || extversion FROM pg_extension WHERE extname IN ('pg_tde', 'vector') ORDER BY extname;
       SELECT 'embeddings_encrypted=' || pg_tde_is_encrypted('embeddings');
       SELECT 'rows=' || count(*) FROM embeddings;"
  fi
done
