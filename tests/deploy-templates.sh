#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

required=(
  deploy/lan/haproxy.cfg
  deploy/lan/db1/compose.yml
  deploy/lan/db1/patroni.yml
  deploy/lan/db1/.env.example
  deploy/lan/db2/compose.yml
  deploy/lan/db2/patroni.yml
  deploy/lan/db2/.env.example
  deploy/lan/witness/compose.yml
  deploy/lan/witness/.env.example
  deploy/lan/colocated-witness/compose.yml
  deploy/lan/colocated-witness/.env.example
  deploy/lan/external-etcd/db1.compose.yml
  deploy/lan/external-etcd/db1.patroni.yml
  deploy/lan/external-etcd/db2.compose.yml
  deploy/lan/external-etcd/db2.patroni.yml
  deploy/lan/external-etcd/.env.db1.example
  deploy/lan/external-etcd/.env.db2.example
)

for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "missing: $path" >&2; exit 1; }
done

compose_cases=(
  'deploy/lan/db1/compose.yml|deploy/lan/db1/.env.example'
  'deploy/lan/db2/compose.yml|deploy/lan/db2/.env.example'
  'deploy/lan/witness/compose.yml|deploy/lan/witness/.env.example'
  'deploy/lan/colocated-witness/compose.yml|deploy/lan/colocated-witness/.env.example'
  'deploy/lan/external-etcd/db1.compose.yml|deploy/lan/external-etcd/.env.db1.example'
  'deploy/lan/external-etcd/db2.compose.yml|deploy/lan/external-etcd/.env.db2.example'
)

for item in "${compose_cases[@]}"; do
  compose="${item%%|*}"
  env_file="${item##*|}"
  docker compose --env-file "$env_file" -f "$compose" config --quiet
  echo "valid compose: $compose"
done

python3 - <<'PY'
from pathlib import Path
import yaml

for path in Path('deploy/lan').rglob('*.yml'):
    with path.open(encoding='utf-8') as stream:
        document = yaml.safe_load(stream)
    print(f'valid yaml: {path}')
    if path.name == 'patroni.yml' or path.name.endswith('.patroni.yml'):
        dcs = document['bootstrap']['dcs']
        ttl = dcs['ttl']
        loop_wait = dcs['loop_wait']
        retry_timeout = dcs['retry_timeout']
        assert ttl >= 20, f'{path}: Patroni ttl must be at least 20 seconds'
        assert loop_wait + 2 * retry_timeout <= ttl, (
            f'{path}: loop_wait + 2 * retry_timeout must not exceed ttl'
        )
PY

if grep -RInE '(postgres / postgres|app / apppass|replicator / replicator)' deploy/lan; then
  echo 'deploy templates contain laboratory credentials' >&2
  exit 1
fi

echo '[PASS] deployment templates passed static validation'
