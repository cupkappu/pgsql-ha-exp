#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-lib.sh"

from="$(manual_primary_node)"
to="$(manual_standby_node)"
before="manual-before-$(date +%s)"
after="manual-after-$(date +%s)"

manual_client_psql "$from" app appdb "$MANUAL_APP_PASSWORD" \
  "CREATE TABLE IF NOT EXISTS manual_probe (
     id bigserial PRIMARY KEY,
     marker text UNIQUE NOT NULL,
     created_at timestamptz NOT NULL DEFAULT now()
   );
   INSERT INTO manual_probe(marker) VALUES ('${before}');" >/dev/null

docker stop "$(manual_outer_name "$from")" >/dev/null
bash "$SOURCE_DIR/scripts/manual-promote.sh" "$to"

manual_client_psql "$to" app appdb "$MANUAL_APP_PASSWORD" \
  "INSERT INTO manual_probe(marker) VALUES ('${after}');" >/dev/null

docker start "$(manual_outer_name "$from")" >/dev/null
manual_wait_for "inner dockerd on ${from}" 90 manual_outer_ready "$from"
bash "$SOURCE_DIR/scripts/manual-rejoin.sh" "$from"

old_node_has_rows() {
  [[ "$(manual_client_psql "$from" app appdb "$MANUAL_APP_PASSWORD" \
    "SELECT count(*) FROM manual_probe WHERE marker IN ('${before}','${after}')" \
    2>/dev/null || true)" == 2 ]]
}

manual_wait_for 'both rows on rejoined standby' 60 old_node_has_rows

printf '[PASS] manual switch and rejoin passed: %s -> %s -> %s standby\n' \
  "$from" "$to" "$from"
