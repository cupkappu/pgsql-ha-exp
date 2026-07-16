#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-demo-lib.sh"

manual_demo_cluster_ready || {
  echo 'manual Compose demo does not have one primary and one standby' >&2
  exit 1
}

primary="$(manual_demo_primary_node)"
standby="$(manual_demo_standby_node)"
marker="manual-demo-smoke-$(date +%s)"

manual_demo_psql "$primary" app "$POSTGRES_DB" "$APP_PASSWORD" \
  'CREATE TABLE IF NOT EXISTS ha_test (
     id bigserial PRIMARY KEY,
     phase text NOT NULL,
     payload text NOT NULL UNIQUE,
     created_at timestamptz NOT NULL DEFAULT now()
   )' >/dev/null
manual_demo_psql "$primary" app "$POSTGRES_DB" "$APP_PASSWORD" \
  "INSERT INTO ha_test (phase, payload) VALUES ('smoke', '${marker}')" >/dev/null

replicated() {
  [[ "$(manual_demo_psql "$standby" app "$POSTGRES_DB" "$APP_PASSWORD" \
    "SELECT count(*) FROM ha_test WHERE payload = '${marker}'" 2>/dev/null || true)" == 1 ]]
}

manual_demo_wait_for "${marker} replication" 60 replicated

streaming="$(manual_demo_psql "$primary" postgres postgres "$POSTGRES_PASSWORD" \
  "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'")"
[[ "$streaming" -eq 1 ]] || {
  echo "expected one streaming standby, found ${streaming}" >&2
  exit 1
}

printf '[PASS] manual Compose smoke: primary=%s standby=%s marker=%s\n' \
  "$primary" "$standby" "$marker"
