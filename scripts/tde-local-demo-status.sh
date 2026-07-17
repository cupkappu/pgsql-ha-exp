#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/tde-local-demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tde-local-demo-lib.sh"

tde_local_demo_print_roles

for node in pg1 pg2; do
  printf '\n[%s]\n' "$node"
  if ! tde_local_demo_running "$node"; then
    printf 'stopped\n'
    continue
  fi

  tde_local_demo_psql "$node" "$POSTGRES_DB" \
    "SELECT 'role=' || CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END;
     SHOW pg_tde.wal_encrypt;
     SELECT 'pg_tde=' || extversion FROM pg_extension WHERE extname = 'pg_tde';
     SELECT 'vector=' || extversion FROM pg_extension WHERE extname = 'vector';
     SELECT 'provider=' || type FROM pg_tde_list_all_global_key_providers() WHERE name = 'local-keyring';
     SELECT 'embeddings_encrypted=' || pg_tde_is_encrypted('embeddings');
     SELECT 'rows=' || count(*) FROM embeddings;"
done

printf '\n[keyring checksums]\n'
printf 'pg1=%s\n' "$(tde_local_demo_keyring_checksum "$TDE_LOCAL_PG1_KEYRING_VOLUME")"
printf 'pg2=%s\n' "$(tde_local_demo_keyring_checksum "$TDE_LOCAL_PG2_KEYRING_VOLUME")"
printf 'backup=%s\n' "$(tde_local_demo_keyring_checksum "$TDE_LOCAL_KEYRING_BACKUP_VOLUME")"
