#!/bin/bash
# Usage: ./scripts/bootstrap.sh
#
# One-time setup. Boots the lab from cold with NO session config, waits for
# all NX-OS nodes to be healthy, then snapshots them as warm baseline images.
#
# After this completes (one-time, ~20 min), every session deploys in ~90 sec
# via ./scripts/lab.sh <session-name>.
#
# Disk cost: ~22 GB one-time, never grows.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WARM_TOPO="${REPO_ROOT}/scripts/_warm-baseline.clab.yml"
NODES=("spine1" "spine2" "leaf1" "leaf2")
WARM_PREFIX="vxlan-warm"

# Sanity check: does the cisco_n9kv base image exist?
if ! docker image inspect vrnetlab/cisco_n9kv:9300-10.5.5 >/dev/null 2>&1; then
  echo "ERROR: Base image vrnetlab/cisco_n9kv:9300-10.5.5 not found."
  echo "Run the vrnetlab build first — see docs/00-prerequisites.md."
  exit 1
fi

# Check if warm images already exist; if so, ask before overwriting
if docker image inspect "${WARM_PREFIX}:spine1" >/dev/null 2>&1; then
  echo "Warm baseline images already exist:"
  docker images "${WARM_PREFIX}*" --format "  {{.Repository}}:{{.Tag}}  {{.Size}}"
  echo ""
  read -p "Overwrite? [y/N] " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted. Existing warm baseline kept."
    exit 0
  fi
fi

# Write a minimal topology file with NO startup-config
# Each node will boot vrnetlab's default config only (hostname, admin user, ssh)
echo "==> Writing temporary baseline topology..."
cat > "$WARM_TOPO" << 'EOF'
name: vxlan-warm

topology:
  kinds:
    cisco_n9kv:
      image: vrnetlab/cisco_n9kv:9300-10.5.5

  nodes:
    spine1:
      kind: cisco_n9kv
    spine2:
      kind: cisco_n9kv
    leaf1:
      kind: cisco_n9kv
    leaf2:
      kind: cisco_n9kv

  links:
    - endpoints: ["spine1:eth1", "leaf1:eth1"]
    - endpoints: ["spine1:eth2", "leaf2:eth1"]
    - endpoints: ["spine2:eth1", "leaf1:eth2"]
    - endpoints: ["spine2:eth2", "leaf2:eth2"]
EOF

echo "==> Cleaning up any existing labs..."
containerlab destroy -t "$WARM_TOPO" --cleanup 2>/dev/null || true
# Also clean any previously running session lab
for topo in "${REPO_ROOT}"/labs/*/topology.clab.yml; do
  [ -f "$topo" ] && containerlab destroy -t "$topo" --cleanup 2>/dev/null || true
done

echo ""
echo "==> Booting baseline NX-OS lab (no session config)..."
echo "    This takes ~15-20 minutes. Go get coffee."
echo ""

containerlab deploy -t "$WARM_TOPO"

echo ""
echo "==> Waiting for all 4 NX-OS nodes to be healthy..."
ready=0
for i in $(seq 1 60); do
  ready=0
  for node in "${NODES[@]}"; do
    container="clab-vxlan-warm-${node}"
    status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
    [ "$status" = "healthy" ] && ready=$((ready+1))
  done
  if [ "$ready" -eq 4 ]; then
    echo "  All 4 nodes healthy."
    break
  fi
  echo "  [$i/60] $ready/4 nodes healthy..."
  sleep 30
done

if [ "$ready" -lt 4 ]; then
  echo "ERROR: not all nodes became healthy in 30 minutes."
  echo "Check: docker ps -a"
  exit 1
fi

# Give NX-OS another minute to fully settle after healthy
echo ""
echo "==> Letting NX-OS settle for 60 seconds..."
sleep 60

echo ""
echo "==> Committing containers to warm baseline images..."
for node in "${NODES[@]}"; do
  container="clab-vxlan-warm-${node}"
  image_tag="${WARM_PREFIX}:${node}"
  echo "  $container -> $image_tag"
  docker commit "$container" "$image_tag" > /dev/null
done

echo ""
echo "==> Destroying baseline lab (we have the snapshots now)..."
containerlab destroy -t "$WARM_TOPO" --cleanup

# Remove the temp topology
rm -f "$WARM_TOPO"

echo ""
echo "============================================================"
echo "Bootstrap complete!"
echo "============================================================"
echo ""
echo "Warm baseline images:"
docker images "${WARM_PREFIX}*" --format "  {{.Repository}}:{{.Tag}}  {{.Size}}"
echo ""
echo "From now on, every session deploys in ~90 seconds:"
echo ""
echo "  ./scripts/lab.sh 01-underlay"
echo "  ./scripts/lab.sh 02-overlay"
echo "  ./scripts/lab.sh 03-l2vni"
echo "  ./scripts/lab.sh 04-anycast-gw"
echo ""
echo "To check disk used by warm baseline:"
echo "  docker images vxlan-warm*"
