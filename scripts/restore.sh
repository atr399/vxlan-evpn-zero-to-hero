#!/bin/bash
# Usage: ./scripts/restore.sh <session-folder>
# Example: ./scripts/restore.sh 04-anycast-gw

set -euo pipefail

SESSION="${1:-}"

if [ -z "$SESSION" ]; then
  echo "Usage: $0 <session-folder>"
  echo ""
  ./scripts/snapshot-list.sh 2>/dev/null || true
  exit 1
fi

LAB_DIR="labs/${SESSION}"
SNAPSHOT_TOPO="${LAB_DIR}/topology-snapshot.clab.yml"
CLEAN_TOPO="${LAB_DIR}/topology.clab.yml"

if [ ! -f "$SNAPSHOT_TOPO" ]; then
  echo "ERROR: No snapshot found for session $SESSION"
  echo ""
  echo "To create:"
  echo "  ./scripts/deploy.sh $SESSION    # boot fresh + configure"
  echo "  # verify it works"
  echo "  ./scripts/snapshot.sh $SESSION"
  exit 1
fi

TAG_PREFIX="vxlan-snapshot-${SESSION}"
for node in spine1 spine2 leaf1 leaf2; do
  if ! docker image inspect "${TAG_PREFIX}:${node}" >/dev/null 2>&1; then
    echo "ERROR: Snapshot image missing: ${TAG_PREFIX}:${node}"
    echo "Re-create with: ./scripts/snapshot.sh $SESSION"
    exit 1
  fi
done

echo "==> Destroying any currently running lab..."
# Try both topology files explicitly to be safe
containerlab destroy -t "$SNAPSHOT_TOPO" --cleanup 2>/dev/null || true
containerlab destroy -t "$CLEAN_TOPO" --cleanup 2>/dev/null || true

echo ""
echo "==> Deploying from snapshot..."
# Use absolute path so cwd doesn't matter
containerlab deploy -t "$(realpath "$SNAPSHOT_TOPO")"

echo ""
echo "==> Waiting for NX-OS to be responsive..."
ready=0
for i in $(seq 1 24); do
  ready=0
  for node in spine1 spine2 leaf1 leaf2; do
    container="clab-vxlan-evpn-${node}"
    status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
    [ "$status" = "healthy" ] && ready=$((ready+1))
  done
  if [ "$ready" -eq 4 ]; then
    echo "  All 4 NX-OS nodes healthy."
    break
  fi
  echo "  $i/24: $ready/4 nodes healthy..."
  sleep 5
done

if [ "$ready" -lt 4 ]; then
  echo "WARNING: not all nodes healthy in 2 minutes."
  echo "Check: docker ps"
fi

echo ""
echo "==> Verifying session config..."

case "$SESSION" in
  01-underlay)    MARKER="router ospf UNDERLAY";              NODE="spine1" ;;
  02-overlay)     MARKER="address-family l2vpn evpn";         NODE="spine1" ;;
  03-l2vni)       MARKER="vn-segment 10010";                  NODE="leaf1"  ;;
  04-anycast-gw)  MARKER="fabric forwarding anycast-gateway-mac"; NODE="leaf1" ;;
  *)              MARKER="";                                  NODE="leaf1"  ;;
esac

if [ -n "$MARKER" ]; then
  container="clab-vxlan-evpn-${NODE}"
  if sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o LogLevel=ERROR \
       "admin@${container}" "show running-config | include \"$MARKER\"" 2>/dev/null | grep -q "$MARKER"; then
    echo "  Config OK on $NODE (found: $MARKER)"
  else
    echo "  WARNING: marker '$MARKER' missing on $NODE. Re-pushing configs..."
    "$(dirname "$0")/_repush.sh" "$SESSION"
  fi
fi

echo ""
echo "==> Restore complete."
case "$SESSION" in
  03-l2vni)
    echo ""
    echo "Re-run host IP setup:"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr add 10.100.10.10/24 dev eth1 && ip link set eth1 up\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr add 10.100.10.11/24 dev eth1 && ip link set eth1 up\""
    ;;
  04-anycast-gw)
    echo ""
    echo "Re-run host IP setup:"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr add 10.100.10.10/24 dev eth1 && ip link set eth1 up && ip route replace default via 10.100.10.1\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr add 10.100.20.10/24 dev eth1 && ip link set eth1 up && ip route replace default via 10.100.20.1\""
    ;;
esac
