#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib.sh

printf '%s\n' '== containerlab hosts =='
docker ps --filter "name=clab-${LAB_NAME}-" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

for host in host1 host2; do
  printf '\n== %s inner Docker ==\n' "$host"
  if docker container inspect "$(outer_name "$host")" >/dev/null 2>&1; then
    docker exec "$(outer_name "$host")" bash /lab/scripts/host-stack.sh "$host" status || true
  else
    echo 'outer host absent'
  fi
done

printf '%s\n' '' '== etcd =='
if etcd_cluster_healthy; then
  etcd_endpoint_status
else
  echo 'etcd cluster unhealthy or unavailable'
fi

printf '%s\n' '' '== Patroni roles =='
print_roles
