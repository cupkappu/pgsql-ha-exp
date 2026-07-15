#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
compose=(docker compose -f demo/compose.yml)

primary=""
for node in pg1 pg2; do
  if "${compose[@]}" exec -T "$node" curl -fsS http://127.0.0.1:8008/primary >/dev/null 2>&1; then
    primary="$node"
    break
  fi
done

[[ -n "$primary" ]] || { echo 'primary not found' >&2; exit 1; }
[[ "$primary" == pg1 ]] && candidate=pg2 || candidate=pg1

printf 'stopping primary: %s\n' "$primary"
"${compose[@]}" stop "$primary"

for _ in $(seq 1 60); do
  if "${compose[@]}" exec -T "$candidate" curl -fsS http://127.0.0.1:8008/primary >/dev/null 2>&1; then
    printf 'new primary: %s\n' "$candidate"
    exit 0
  fi
  sleep 1
done

echo "${candidate} promotion timeout" >&2
exit 1
