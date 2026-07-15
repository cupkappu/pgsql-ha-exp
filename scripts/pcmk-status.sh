#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/pcmk-lib.sh

printf '%s\n' '== Pacemaker containerlab nodes =='
docker ps -a --filter "name=clab-${PCMK_LAB_NAME}-" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

printf '%s\n' '' '== Corosync quorum =='
pcmk_exec db1 corosync-quorumtool -s || true

printf '%s\n' '' '== Pacemaker resources =='
pcmk_status_text || true

printf '%s\n' '' '== PostgreSQL roles =='
for node in db1 db2; do
  role='unreachable'
  recovery="$(pcmk_exec "$node" runuser -u postgres -- psql -At -d postgres -c 'SELECT pg_is_in_recovery()' 2>/dev/null || true)"
  [[ "$recovery" == 'f' ]] && role='primary'
  [[ "$recovery" == 't' ]] && role='standby'
  printf '%-4s %s\n' "$node" "$role"
done
