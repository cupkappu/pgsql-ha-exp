#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SOURCE_DIR/scripts/manual-demo-lib.sh"

printf '%s\n' '[1/5] validating Compose configuration'
manual_demo_compose config --quiet

printf '%s\n' '[2/5] pulling PostgreSQL image'
manual_demo_compose pull db1 db2 >/dev/null

if ! manual_demo_data_initialized db1 && ! manual_demo_data_initialized db2; then
  printf '%s\n' '[3/5] initializing db1 as primary'
  manual_demo_compose up -d db1
  manual_demo_wait_for 'db1 PostgreSQL' 90 manual_demo_ready db1
  manual_demo_configure_primary db1

  printf '%s\n' '[4/5] cloning db2 from db1'
  manual_demo_clone db2 db1
  manual_demo_compose up -d db2
elif manual_demo_data_initialized db1 && ! manual_demo_data_initialized db2; then
  printf '%s\n' '[3/5] starting existing db1 data'
  manual_demo_compose up -d db1
  manual_demo_wait_for 'db1 PostgreSQL' 90 manual_demo_ready db1
  [[ "$(manual_demo_role db1)" == primary ]] || {
    echo 'db1 data is not primary data' >&2
    exit 1
  }
  manual_demo_configure_primary db1

  printf '%s\n' '[4/5] cloning db2 from db1'
  manual_demo_clone db2 db1
  manual_demo_compose up -d db2
elif ! manual_demo_data_initialized db1 && manual_demo_data_initialized db2; then
  printf '%s\n' '[3/5] starting existing db2 data'
  manual_demo_compose up -d db2
  manual_demo_wait_for 'db2 PostgreSQL' 90 manual_demo_ready db2
  [[ "$(manual_demo_role db2)" == primary ]] || {
    echo 'db2 data is not primary data' >&2
    exit 1
  }
  manual_demo_configure_primary db2

  printf '%s\n' '[4/5] cloning db1 from db2'
  manual_demo_clone db1 db2
  manual_demo_compose up -d db1
else
  printf '%s\n' '[3/5] starting db1 and db2 from existing data'
  manual_demo_compose up -d db1 db2
  printf '%s\n' '[4/5] retaining existing roles'
fi

printf '%s\n' '[5/5] waiting for one primary and one standby'
manual_demo_wait_for 'manual Compose primary and standby' 180 manual_demo_cluster_ready
manual_demo_print_roles
