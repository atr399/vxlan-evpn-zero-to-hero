#!/bin/bash
# Usage: ./scripts/restore.sh <session-folder>
# Example: ./scripts/restore.sh 04-anycast-gw
#
# Destroys any running lab, deploys from a snapshot, and verifies the
# session's expected config is intact. If config is missing (vrnetlab
# resume sometimes wipes it), re-pushes via SSH.

set -euo pipefail

SESSION="${1:-}"

if [ -z "$SESSION" ]; then
  echo "Usage: $0 <session-folder>"
  echo ""
  echo "Available snapshots:"
  ./scripts/snapshot-list.sh 2>/dev/null || true
  exit 1
fi

LAB_DIR="labs/${SESSION}"
SNAPSHOT_TOPO="${LAB_DIR}/topology-snapshot.clab.yml"
CLEAN_TOPO="${LAB_DIR}/topology.clab.yml"

if [ ! -f "$SNAPSHOT_TOPO" ]; then
  echo "ERROR: No snapshot found for session $SESSION"
  echo ""
  echo "To create a snapshot first:"
  echo "  ./scripts/deploy.sh $SESSION    # boot fresh + configure"
  echo "  # verify everything works..."
  echo "  ./scripts/snapshot.sh $SESSION  # save current state"
  exit 1
fi

# Check snapshot images actually exist
TAG_PREFIX="vxlan-snapshot-${SESSION}"
for node in spine1 spine2 leaf1 leaf2; do
  if ! docker image inspect "${TAG_PREFIX}:${node}" >/dev/null 2>&1; then
    echo "ERROR: Snapshot image missing: ${TAG_PREFIX}:${node}"
    echo "The snapshot topology file exists but the images do not."
    echo "Re-create the snapshot with: ./scripts/snapshot.sh $SESSION"
    exit 1
  fi
done

# Destroy any currently running lab
echo "==> Destroying any currently running lab..."
for topo in "$SNAPSHOT_TOPO" "$CLEAN_TOPO"; do
  containerlab destroy -t "$topo" --cleanup 2>/dev/null || true
done

# Deploy from snapshot
echo ""
echo "==> Deploying from snapshot (much faster than clean deploy)..."
cd "$LAB_DIR"
containerlab deploy -t "$(basename "$SNAPSHOT_TOPO")"
cd - > /dev/null

# Brief wait for vrnetlab to settle (it still needs ~30 sec even from snapshot)
echo ""
echo "==> Waiting for NX-OS to be responsive (typically 30-60 sec)..."
for i in $(seq 1 24); do
  ready=0
  for node in spine1 spine2 leaf1 leaf2; do
    container="clab-vxlan-evpn-${node}"
    status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
    [ "$status" = "healthy" ] && ready=$((ready+1))
  done
  if [ "$ready" -eq 4 ]; then
    echo "  All 4 NX-OS nodes are healthy."
    break
  fi
  echo "  $i/24: $ready/4 nodes healthy..."
  sleep 5
done

if [ "$ready" -lt 4 ]; then
  echo "WARNING: not all nodes became healthy in 2 minutes."
  echo "Lab may still work; check manually with: docker ps"
fi

# Sanity check: verify session config is actually intact on one node
echo ""
echo "==> Verifying session config survived the snapshot/restore..."

# Pick a session-specific marker from the cfg file to check for
case "$SESSION" in
  01-underlay)
    MARKER="router ospf UNDERLAY"
    NODE="spine1"
    ;;
  02-overlay)
    MARKER="address-family l2vpn evpn"
    NODE="spine1"
    ;;
  03-l2vni)
    MARKER="vn-segment 10010"
    NODE="leaf1"
    ;;
  04-anycast-gw)
    MARKER="fabric forwarding anycast-gateway-mac"
    NODE="leaf1"
    ;;
  *)
    MARKER=""
    NODE="leaf1"
    ;;
esac

if [ -n "$MARKER" ]; then
  container="clab-vxlan-evpn-${NODE}"
  if sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o LogLevel=ERROR \
       "admin@${container}" "show running-config | include \"$MARKER\"" 2>/dev/null | grep -q "$MARKER"; then
    echo "  Config check passed on $NODE (found: $MARKER)"
  else
    echo "  WARNING: Session marker '$MARKER' NOT found on $NODE."
    echo "  vrnetlab may have wiped the config on resume. Re-pushing from cfg files..."
    "$(dirname "$0")/_repush.sh" "$SESSION"
  fi
fi

echo ""
echo "==> Restore complete. Reminder for some sessions: re-run host IP setup."
case "$SESSION" in
  03-l2vni)
    echo ""
    echo "Hosts in this session need:"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr add 10.100.10.10/24 dev eth1 && ip link set eth1 up\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr add 10.100.10.11/24 dev eth1 && ip link set eth1 up\""
    ;;
  04-anycast-gw)
    echo ""
    echo "Hosts in this session need:"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr add 10.100.10.10/24 dev eth1 && ip link set eth1 up && ip route replace default via 10.100.10.1\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr add 10.100.20.10/24 dev eth1 && ip link set eth1 up && ip route replace default via 10.100.20.1\""
    ;;
esac
