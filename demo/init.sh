#!/usr/bin/env bash
set -euo pipefail

for _ in $(seq 1 120); do
  if pg_isready -q -h haproxy -p 5000 -U postgres -d postgres; then
    break
  fi
  sleep 1
done

pg_isready -h haproxy -p 5000 -U postgres -d postgres

if [[ "$(psql -At -h haproxy -p 5000 -U postgres -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname='app'")" != "1" ]]; then
  psql -v ON_ERROR_STOP=1 -h haproxy -p 5000 -U postgres -d postgres \
    -c "CREATE ROLE app LOGIN PASSWORD 'apppass'"
fi

if [[ "$(psql -At -h haproxy -p 5000 -U postgres -d postgres -c "SELECT 1 FROM pg_database WHERE datname='appdb'")" != "1" ]]; then
  createdb -h haproxy -p 5000 -U postgres -O app appdb
fi

PGPASSWORD=apppass psql -v ON_ERROR_STOP=1 \
  -h haproxy -p 5000 -U app -d appdb -f /demo/init.sql
