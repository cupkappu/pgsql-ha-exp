#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-demo-lib.sh"

target="${1:?usage: manual-demo-rejoin.sh NODE}"
source_node="$(manual_demo_other_node "$target")"

[[ "$(manual_demo_role "$source_node")" == primary ]] || {
  echo "${source_node} is not the running primary" >&2
  exit 1
}

printf 'stopping %s and replacing its data from %s\n' "$target" "$source_node"
manual_demo_clone "$target" "$source_node"
manual_demo_compose up -d "$target"
manual_demo_wait_for "${target} PostgreSQL" 90 manual_demo_ready "$target"
manual_demo_wait_for "${target} standby role" 90 manual_demo_role_is "$target" standby
manual_demo_wait_for 'manual Compose primary and standby' 90 manual_demo_cluster_ready
manual_demo_print_roles
