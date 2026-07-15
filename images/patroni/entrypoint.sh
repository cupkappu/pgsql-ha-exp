#!/usr/bin/env bash
set -euo pipefail

install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/data/pgdata
install -d -o postgres -g postgres /var/run/postgresql
chown -R postgres:postgres /var/lib/postgresql/data /var/run/postgresql
chmod 0700 /var/lib/postgresql/data/pgdata
umask 077

exec gosu postgres patroni "$@"
