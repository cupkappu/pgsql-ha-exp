#!/usr/bin/env bash
set -euo pipefail

cat >&2 <<'EOF'
This test belonged to the original two-member etcd topology.
The Patroni design now has an external third etcd member and supports full database-host failover.
Run tests/host-failover.sh or `make patroni-host-failover` instead.
EOF
exit 2
