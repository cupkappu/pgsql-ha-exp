#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="/var/lib/pgsql-ha-exp-pcmk/lab"
install -d -m 0755 "$RUNTIME_DIR"
if [[ "$SOURCE_DIR" != "$RUNTIME_DIR" ]]; then
  rm -rf "$RUNTIME_DIR"/*
  cp -a "$SOURCE_DIR"/. "$RUNTIME_DIR"/
fi
cd "$RUNTIME_DIR"
source scripts/pcmk-lib.sh

printf '%s\n' '[1/8] building Pacemaker database-node image'
docker build --network host -t pgsql-ha-pacemaker:local images/pacemaker

docker pull "$PCMK_CLIENT_IMAGE" >/dev/null

install -d -m 0755 \
  /var/lib/pgsql-ha-exp-pcmk/db1-postgresql \
  /var/lib/pgsql-ha-exp-pcmk/db1-pacemaker \
  /var/lib/pgsql-ha-exp-pcmk/db1-corosync \
  /var/lib/pgsql-ha-exp-pcmk/db2-postgresql \
  /var/lib/pgsql-ha-exp-pcmk/db2-pacemaker \
  /var/lib/pgsql-ha-exp-pcmk/db2-corosync

if ! docker container inspect "$PCMK_DB1" "$PCMK_DB2" >/dev/null 2>&1; then
  printf '%s\n' '[2/8] deploying two Pacemaker database servers'
  containerlab destroy -t "$PCMK_TOPOLOGY" --cleanup >/dev/null 2>&1 || true
  containerlab deploy -t "$PCMK_TOPOLOGY"
else
  printf '%s\n' '[2/8] Pacemaker nodes already exist; reusing them'
fi

pcmk_wait_for 'db1 Corosync' 90 pcmk_node_ready db1
pcmk_wait_for 'db2 Corosync' 90 pcmk_node_ready db2
pcmk_wait_for 'two-node Corosync membership' 90 pcmk_cluster_ready

printf '%s\n' '[3/8] validating peer fencing control'
for node in db1 db2; do
  pcmk_exec "$node" fence_peer_docker -o monitor
  pcmk_exec "$node" fence_peer_docker -o status -n "$(pcmk_container "$(pcmk_other_node "$node")")"
done

if ! pcmk_exec db1 test -f /var/lib/postgresql/16/main/PG_VERSION; then
  printf '%s\n' '[4/8] initializing db1 and application roles'
  pcmk_exec db1 bash /lab/scripts/pcmk-node-db.sh db1 init-primary

  pcmk_wait_for 'db1 bootstrap PostgreSQL' 60 \
    pcmk_exec db1 runuser -u postgres -- pg_isready -q -h 172.31.110.11 -p 5432

  printf '%s\n' '[5/8] cloning db2 through PostgreSQL streaming replication'
  pcmk_exec db2 bash /lab/scripts/pcmk-node-db.sh db2 clone-standby
  pcmk_exec db1 bash /lab/scripts/pcmk-node-db.sh db1 stop
else
  printf '%s\n' '[4/8] PostgreSQL data already initialized'
  printf '%s\n' '[5/8] existing replica data retained'
fi

printf '%s\n' '[6/8] configuring Pacemaker, STONITH and PostgreSQL resources'
if ! pcmk_exec db1 pcs resource config pgsql >/dev/null 2>&1; then
  pcmk_exec db1 pcs property set maintenance-mode=true
  pcmk_exec db1 pcs property set stonith-enabled=true
  pcmk_exec db1 pcs property set stonith-action=off
  pcmk_exec db1 pcs property set startup-fencing=true
  pcmk_exec db1 pcs property set no-quorum-policy=stop
  pcmk_exec db1 pcs property set cluster-recheck-interval=5s
  pcmk_exec db1 pcs resource defaults update resource-stickiness=100

  pcmk_exec db1 pcs stonith create fence-docker fence_peer_docker \
    "pcmk_host_map=db1:${PCMK_DB1};db2:${PCMK_DB2}" \
    'pcmk_host_list=db1 db2' \
    pcmk_reboot_action=off \
    op monitor interval=20s timeout=20s

  pcmk_exec db1 pcs resource create pgsql ocf:heartbeat:pgsqlms \
    pgdata=/var/lib/postgresql/16/main \
    bindir=/usr/lib/postgresql/16/bin \
    pghost=/var/run/postgresql \
    pgport=5432 \
    maxlag=0 \
    op start timeout=120s \
    op stop timeout=120s \
    op promote timeout=60s \
    op demote timeout=180s \
    op monitor interval=5s role=Promoted timeout=15s \
    op monitor interval=7s role=Unpromoted timeout=15s

  pcmk_exec db1 pcs resource promotable pgsql pgsql-ha meta \
    promoted-max=1 promoted-node-max=1 \
    clone-max=2 clone-node-max=1 notify=true

  pcmk_exec db1 pcs resource create vip ocf:heartbeat:IPaddr2 \
    ip="$PCMK_VIP" cidr_netmask=24 nic=eth0 \
    op monitor interval=5s timeout=10s

  pcmk_exec db1 pcs constraint colocation add vip with Promoted pgsql-ha INFINITY
  pcmk_exec db1 pcs constraint order promote pgsql-ha then start vip
  pcmk_exec db1 pcs constraint location pgsql-ha prefers db1=100
fi
pcmk_exec db1 pcs property set maintenance-mode=false

printf '%s\n' '[7/8] waiting for promoted PostgreSQL, standby and VIP'
pcmk_wait_for 'one primary and one standby' 240 pcmk_has_primary_and_standby
pcmk_wait_for 'writable PostgreSQL VIP' 90 pcmk_vip_writable
pcmk_exec db1 pcs resource cleanup pgsql >/dev/null
pcmk_wait_for 'stable PostgreSQL roles after cleanup' 90 pcmk_has_primary_and_standby

printf '%s\n' '[8/8] Pacemaker cluster ready'
pcmk_status_text
printf 'PostgreSQL VIP: %s:5432\n' "$PCMK_VIP"
