#!/usr/bin/env bash
set -euo pipefail

node="${1:?usage: pcmk-node-db.sh <db1|db2> <init-primary|clone-standby|configure|stop>}"
action="${2:?usage: pcmk-node-db.sh <db1|db2> <init-primary|clone-standby|configure|stop>}"
PGDATA="/var/lib/postgresql/16/main"
PGBIN="/usr/lib/postgresql/16/bin"

case "$node" in
  db1)
    peer_ip="172.31.110.12"
    ;;
  db2)
    peer_ip="172.31.110.11"
    ;;
  *)
    echo "unknown node: $node" >&2
    exit 1
    ;;
esac

as_postgres() {
  runuser -u postgres -- "$@"
}

configure_node() {
  install -d -o postgres -g postgres -m 0700 "$PGDATA"
  cat >"$PGDATA/cluster.conf" <<EOF
listen_addresses = '*'
port = 5432
unix_socket_directories = '/var/run/postgresql'
wal_level = replica
hot_standby = on
hot_standby_feedback = on
wal_log_hints = on
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = '256MB'
password_encryption = 'scram-sha-256'
recovery_target_timeline = 'latest'
primary_conninfo = 'host=${peer_ip} port=5432 user=replicator password=replicator application_name=${node} connect_timeout=3'
cluster_name = 'pgsql-pcmk-${node}'
EOF
  chown postgres:postgres "$PGDATA/cluster.conf"
  chmod 0600 "$PGDATA/cluster.conf"

  if ! grep -q "include_if_exists = 'cluster.conf'" "$PGDATA/postgresql.conf"; then
    printf "\ninclude_if_exists = 'cluster.conf'\n" >>"$PGDATA/postgresql.conf"
  fi

  cat >"$PGDATA/pg_hba.conf" <<'EOF'
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             172.31.110.0/24         scram-sha-256
host    replication     replicator      172.31.110.0/24         scram-sha-256
EOF
  chown postgres:postgres "$PGDATA/postgresql.conf" "$PGDATA/pg_hba.conf"
  chmod 0600 "$PGDATA/postgresql.conf" "$PGDATA/pg_hba.conf"
}

stop_postgres() {
  if as_postgres "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
    as_postgres "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w stop
  fi
}

case "$action" in
  init-primary)
    stop_postgres || true
    rm -rf "$PGDATA"
    install -d -o postgres -g postgres -m 0700 "$PGDATA" /var/run/postgresql
    as_postgres "$PGBIN/initdb" -D "$PGDATA" --data-checksums --auth-local=trust --auth-host=scram-sha-256
    configure_node
    rm -f "$PGDATA/standby.signal"
    as_postgres "$PGBIN/pg_ctl" -D "$PGDATA" -w start
    as_postgres psql -v ON_ERROR_STOP=1 -d postgres <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD 'replicator';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app') THEN
    CREATE ROLE app WITH LOGIN PASSWORD 'apppass';
  END IF;
END
$$;
SQL
    if ! as_postgres psql -At -d postgres -c "SELECT 1 FROM pg_database WHERE datname='appdb'" | grep -q '^1$'; then
      as_postgres createdb -O app appdb
    fi
    ;;
  clone-standby)
    stop_postgres || true
    rm -rf "$PGDATA"
    install -d -o postgres -g postgres -m 0700 "$PGDATA" /var/run/postgresql
    as_postgres env PGPASSWORD=replicator "$PGBIN/pg_basebackup" \
      -h "$peer_ip" -p 5432 -U replicator \
      -D "$PGDATA" -X stream -c fast --checkpoint=fast
    configure_node
    touch "$PGDATA/standby.signal"
    chown postgres:postgres "$PGDATA/standby.signal"
    ;;
  configure)
    configure_node
    ;;
  stop)
    stop_postgres
    ;;
  *)
    echo "unknown action: $action" >&2
    exit 1
    ;;
esac
