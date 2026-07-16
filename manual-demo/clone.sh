#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_HOST:?SOURCE_HOST is required}"
: "${TARGET_NAME:?TARGET_NAME is required}"
: "${REPLICATION_PASSWORD:?REPLICATION_PASSWORD is required}"

source_dsn="host=${SOURCE_HOST} port=5432 user=replicator password=${REPLICATION_PASSWORD} application_name=${TARGET_NAME}"
target_dir=/var/lib/postgresql/data/pgdata

install -d -o postgres -g postgres -m 0700 "$target_dir"
find "$target_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
chown postgres:postgres "$target_dir"
chmod 0700 "$target_dir"

exec gosu postgres pg_basebackup \
  -d "$source_dsn" \
  -D "$target_dir" \
  -Fp -Xs -P -R
