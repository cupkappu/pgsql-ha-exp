#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-lib.sh"

from="${1:?usage: manual-switch.sh FROM TO}"
to="${2:?usage: manual-switch.sh FROM TO}"

[[ "$(manual_other_node "$from")" == "$to" ]] || {
  echo 'FROM and TO must be db1/db2' >&2
  exit 1
}
[[ "$(manual_role "$from")" == primary ]] || {
  echo "${from} is not primary" >&2
  exit 1
}
[[ "$(manual_role "$to")" == standby ]] || {
  echo "${to} is not standby" >&2
  exit 1
}

manual_node_psql "$from" postgres postgres "$MANUAL_SUPERUSER_PASSWORD" 'CHECKPOINT' >/dev/null
manual_inner_docker "$from" stop "$MANUAL_CONTAINER" >/dev/null
bash "$SOURCE_DIR/scripts/manual-promote.sh" "$to"
