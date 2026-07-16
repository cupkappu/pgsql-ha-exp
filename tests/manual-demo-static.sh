#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SOURCE_DIR"

required=(
  manual-demo/compose.yml
  manual-demo/.env.example
  manual-demo/clone.sh
  manual-demo/README.md
  scripts/manual-demo-lib.sh
  scripts/manual-demo-up.sh
  scripts/manual-demo-status.sh
  scripts/manual-demo-switch.sh
  scripts/manual-demo-promote.sh
  scripts/manual-demo-rejoin.sh
  scripts/manual-demo-down.sh
  scripts/manual-demo-clean.sh
  tests/manual-demo-smoke.sh
  tests/manual-demo-failover.sh
)

for path in "${required[@]}"; do
  [[ -f "$path" ]] || {
    echo "missing: $path" >&2
    exit 1
  }
done

docker compose \
  --env-file manual-demo/.env.example \
  -f manual-demo/compose.yml \
  config --quiet

bash -n \
  manual-demo/clone.sh \
  scripts/manual-demo-*.sh \
  tests/manual-demo-smoke.sh \
  tests/manual-demo-failover.sh

for target in \
  manual-demo-up manual-demo-status manual-demo-smoke manual-demo-switch \
  manual-demo-promote manual-demo-rejoin manual-demo-failover \
  manual-demo-test manual-demo-down manual-demo-clean; do
  grep -q "^${target}:" Makefile || {
    echo "missing Make target: ${target}" >&2
    exit 1
  }
done

required_readme_patterns=(
  '^### 將現有 Docker Compose 單節點擴展為雙機手動主備$'
  'pg_basebackup'
  'host2_slot'
  'pg_promote'
  'pg_last_wal_replay_lsn'
  'restart: unless-stopped'
  'tablespace-mapping'
)

for pattern in "${required_readme_patterns[@]}"; do
  grep -q -- "$pattern" README.md || {
    echo "README missing manual migration guidance: ${pattern}" >&2
    exit 1
  }
done

printf '%s\n' '[PASS] manual Compose static validation'
