#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-demo-lib.sh"

manual_demo_cluster_ready || {
  echo 'manual Compose demo does not have one primary and one standby' >&2
  exit 1
}

from="$(manual_demo_primary_node)"
to="$(manual_demo_standby_node)"
before="manual-demo-before-$(date +%s)"
after="manual-demo-after-$(date +%s)"

manual_demo_psql "$from" app "$POSTGRES_DB" "$APP_PASSWORD" \
  'CREATE TABLE IF NOT EXISTS ha_test (
     id bigserial PRIMARY KEY,
     phase text NOT NULL,
     payload text NOT NULL UNIQUE,
     created_at timestamptz NOT NULL DEFAULT now()
   )' >/dev/null
manual_demo_psql "$from" app "$POSTGRES_DB" "$APP_PASSWORD" \
  "INSERT INTO ha_test (phase, payload) VALUES ('before-failover', '${before}')" >/dev/null

before_replicated() {
  [[ "$(manual_demo_psql "$to" app "$POSTGRES_DB" "$APP_PASSWORD" \
    "SELECT count(*) FROM ha_test WHERE payload = '${before}'" 2>/dev/null || true)" == 1 ]]
}
manual_demo_wait_for "${before} replication" 60 before_replicated

manual_demo_compose stop "$from" >/dev/null
bash "$SOURCE_DIR/scripts/manual-demo-promote.sh" "$to" >/dev/null
manual_demo_psql "$to" app "$POSTGRES_DB" "$APP_PASSWORD" \
  "INSERT INTO ha_test (phase, payload) VALUES ('after-failover', '${after}')" >/dev/null

bash "$SOURCE_DIR/scripts/manual-demo-rejoin.sh" "$from" >/dev/null

rejoined_data_visible() {
  [[ "$(manual_demo_psql "$from" app "$POSTGRES_DB" "$APP_PASSWORD" \
    "SELECT count(*) FROM ha_test WHERE payload IN ('${before}', '${after}')" \
    2>/dev/null || true)" == 2 ]]
}
manual_demo_wait_for 'rejoined standby data' 60 rejoined_data_visible
manual_demo_cluster_ready

printf '[PASS] manual Compose failover: old-primary=%s new-primary=%s\n' "$from" "$to"
