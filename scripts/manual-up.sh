#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="/var/lib/pgsql-ha-manual/lab"
install -d -m 0755 "$RUNTIME_DIR"
install -m 0644 \
  "$SOURCE_DIR/topology-manual.clab.yml" \
  "$RUNTIME_DIR/topology-manual.clab.yml"
source "$SOURCE_DIR/scripts/manual-lib.sh"

configure_primary() {
  local node="$1"

  manual_inner_docker "$node" exec "$MANUAL_CONTAINER" bash -ceu '
    if ! grep -q "pgsql-manual replication" /var/lib/postgresql/data/pg_hba.conf; then
      cat >> /var/lib/postgresql/data/pg_hba.conf <<"HBA"
# pgsql-manual replication
host replication replicator 172.31.120.0/24 scram-sha-256
host all all 172.31.120.0/24 scram-sha-256
HBA
    fi
  '

  manual_node_psql "$node" postgres postgres "$MANUAL_SUPERUSER_PASSWORD" \
    'SELECT pg_reload_conf()' >/dev/null

  manual_node_psql "$node" postgres postgres "$MANUAL_SUPERUSER_PASSWORD" \
    "DO \$\$
     BEGIN
       IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
         CREATE ROLE replicator LOGIN REPLICATION PASSWORD '${MANUAL_REPLICATION_PASSWORD}';
       END IF;
       IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app') THEN
         CREATE ROLE app LOGIN PASSWORD '${MANUAL_APP_PASSWORD}';
       END IF;
     END
     \$\$;" >/dev/null

  manual_node_psql "$node" postgres postgres "$MANUAL_SUPERUSER_PASSWORD" \
    'ALTER DATABASE appdb OWNER TO app' >/dev/null
}

if docker image inspect pgsql-ha-dind:local >/dev/null 2>&1; then
  printf '%s\n' '[1/6] using the existing Docker-host image'
else
  printf '%s\n' '[1/6] building the two Docker-host image'
  docker build --network host -t pgsql-ha-dind:local "$SOURCE_DIR/images/dind"
fi

if docker image inspect "$MANUAL_POSTGRES_IMAGE" >/dev/null 2>&1; then
  printf '%s\n' '[2/6] using the existing PostgreSQL 16 image'
else
  printf '%s\n' '[2/6] pulling PostgreSQL 16'
  docker pull "$MANUAL_POSTGRES_IMAGE" >/dev/null
fi

install -d -m 0755 \
  /var/lib/pgsql-ha-manual/db1-docker \
  /var/lib/pgsql-ha-manual/db2-docker \
  /var/lib/pgsql-ha-manual/db1-postgresql \
  /var/lib/pgsql-ha-manual/db2-postgresql

if ! docker container inspect "$MANUAL_DB1" "$MANUAL_DB2" >/dev/null 2>&1; then
  printf '%s\n' '[3/6] deploying two independent Docker hosts'
  containerlab destroy -t "$MANUAL_TOPOLOGY" --cleanup >/dev/null 2>&1 || true
  containerlab deploy -t "$MANUAL_TOPOLOGY"
else
  printf '%s\n' '[3/6] reusing the two Docker hosts'
fi

for node in db1 db2; do
  manual_wait_for "inner dockerd on ${node}" 90 manual_outer_ready "$node"
done

printf '%s\n' '[4/6] checking PostgreSQL in both Docker daemons'
for node in db1 db2; do
  if ! manual_inner_docker "$node" image inspect "$MANUAL_POSTGRES_IMAGE" >/dev/null 2>&1; then
    docker save "$MANUAL_POSTGRES_IMAGE" | \
      docker exec -i "$(manual_outer_name "$node")" docker load >/dev/null
  fi
done

if ! manual_data_initialized db1 && ! manual_data_initialized db2; then
  printf '%s\n' '[5/6] initializing db1 as primary'
  manual_start_postgres db1
  manual_wait_for 'db1 PostgreSQL' 90 manual_postgres_ready db1
  configure_primary db1

  printf '%s\n' '[6/6] cloning db2 as standby'
  manual_clone_from db2 db1
  manual_start_postgres db2
elif manual_data_initialized db1 && ! manual_data_initialized db2; then
  printf '%s\n' '[5/6] starting db1'
  manual_start_postgres db1
  manual_wait_for 'db1 PostgreSQL' 90 manual_postgres_ready db1
  [[ "$(manual_role db1)" == primary ]] || {
    echo 'db1 data is not primary data' >&2
    exit 1
  }
  configure_primary db1

  printf '%s\n' '[6/6] cloning db2 as standby'
  manual_clone_from db2 db1
  manual_start_postgres db2
elif ! manual_data_initialized db1 && manual_data_initialized db2; then
  printf '%s\n' '[5/6] starting db2'
  manual_start_postgres db2
  manual_wait_for 'db2 PostgreSQL' 90 manual_postgres_ready db2
  [[ "$(manual_role db2)" == primary ]] || {
    echo 'db2 data is not primary data' >&2
    exit 1
  }
  configure_primary db2

  printf '%s\n' '[6/6] cloning db1 as standby'
  manual_clone_from db1 db2
  manual_start_postgres db1
else
  printf '%s\n' '[5/6] starting db1 and db2 from existing data'
  manual_start_postgres db1
  manual_start_postgres db2
  printf '%s\n' '[6/6] retaining the existing primary/standby roles'
fi

manual_wait_for 'manual primary and standby' 180 manual_cluster_ready
manual_print_roles
