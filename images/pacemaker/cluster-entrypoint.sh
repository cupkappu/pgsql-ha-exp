#!/usr/bin/env bash
set -euo pipefail

if [[ -e /var/lib/postgresql/rejoin-required ]]; then
  echo 'node fenced; waiting for PostgreSQL re-seed before rejoining Pacemaker'
  exec sleep infinity
fi

install -d -m 0755 /run/corosync /run/pacemaker /var/log/corosync
install -d -o hacluster -g haclient -m 0750 \
  /var/lib/pacemaker \
  /var/lib/pacemaker/cores \
  /var/lib/pacemaker/cib
rm -f /run/corosync/corosync.pid /run/pacemaker/pacemakerd.pid

corosync -f &
corosync_pid=$!

cleanup() {
  kill "$corosync_pid" >/dev/null 2>&1 || true
  wait "$corosync_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
  if corosync-cfgtool -s >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$corosync_pid" >/dev/null 2>&1; then
    echo 'corosync exited before becoming ready' >&2
    wait "$corosync_pid"
    exit 1
  fi
  sleep 1
done

if ! corosync-cfgtool -s >/dev/null 2>&1; then
  echo 'corosync did not become ready' >&2
  exit 1
fi

pacemakerd -f &
pacemaker_pid=$!
wait "$pacemaker_pid"
