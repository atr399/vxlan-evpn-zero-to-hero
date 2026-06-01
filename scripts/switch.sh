#!/bin/bash
# Usage: ./scripts/switch.sh <session-folder>
# Example: ./scripts/switch.sh 05a-tenant-b

set -euo pipefail

SESSION="${1:-}"

if [ -z "$SESSION" ]; then
  echo "Usage: $0 <session-folder>"
  echo ""
  echo "Available sessions:"
  ls labs/ 2>/dev/null | grep -v '^pcaps$' | sed 's/^/  /'
  echo ""
  echo "NOTE: switch.sh assumes a lab is already running."
  echo "For first-time deploy, use ./scripts/deploy.sh <session>"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAB_DIR="${REPO_ROOT}/labs/${SESSION}"
CFG_DIR="${LAB_DIR}/configs"
NODES=("spine1" "spine2" "leaf1" "leaf2")

if [ ! -d "$CFG_DIR" ]; then
  echo "ERROR: No configs found at $CFG_DIR"
  exit 1
fi

if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass not installed. Run: sudo apt install -y sshpass"
  exit 1
fi

echo "==> Checking that lab is running..."
missing=0
for node in "${NODES[@]}"; do
  container="clab-vxlan-evpn-${node}"
  if ! docker inspect "$container" >/dev/null 2>&1; then
    echo "  $container: NOT FOUND"
    missing=$((missing+1))
  else
    state=$(docker inspect --format '{{.State.Status}}' "$container")
    echo "  $container: $state"
    [ "$state" != "running" ] && missing=$((missing+1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo ""
  echo "ERROR: $missing/4 NX-OS containers not running."
  echo "Run ./scripts/deploy.sh <session> first to bring up a fresh lab."
  exit 1
fi

echo ""
echo "==> Verifying SSH is responsive on all nodes..."
for node in "${NODES[@]}"; do
  container="clab-vxlan-evpn-${node}"
  echo -n "  $node: "
  ok=0
  for attempt in $(seq 1 30); do
    if sshpass -p admin ssh \
         -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -o LogLevel=ERROR \
         -o ConnectTimeout=3 \
         -o PreferredAuthentications=password \
         "admin@${container}" "show clock" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 2
  done
  if [ "$ok" -eq 1 ]; then
    echo "ready"
  else
    echo "FAILED — SSH did not respond after 60 sec"
    echo "Try manually: ssh admin@${container}  (password: admin)"
    exit 1
  fi
done

echo ""
echo "==> Pushing $SESSION cfg files in parallel..."
START_TIME=$(date +%s)

PUSH_LOG="${REPO_ROOT}/scripts/_push.log"
> "$PUSH_LOG"

push_cfg() {
  local node="$1"
  local cfg_file="${CFG_DIR}/${node}.cfg"
  local container="clab-vxlan-evpn-${node}"

  if [ ! -f "$cfg_file" ]; then
    echo "[$node] no cfg file, skipping" >> "$PUSH_LOG"
    return
  fi

  local lines
  lines=$(grep -v '^!' "$cfg_file" | grep -v '^[[:space:]]*$' | wc -l)
  echo "[$node] BEGIN push ($lines effective config lines)" >> "$PUSH_LOG"

  {
    echo "terminal length 0"
    echo "terminal dont-ask"
    echo "configure terminal"
    grep -v '^!' "$cfg_file" | grep -v '^[[:space:]]*$'
    echo "end"
    echo "copy running-config startup-config"
    echo "exit"
  } | sshpass -p admin ssh -tt \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=10 \
      "admin@${container}" >> "$PUSH_LOG" 2>&1

  local rc=$?
  echo "[$node] END push (exit code $rc)" >> "$PUSH_LOG"
}

for node in "${NODES[@]}"; do
  push_cfg "$node" &
done
wait

echo ""
grep -E '^\[' "$PUSH_LOG" || true

echo ""
echo "==> Verifying session config landed..."
case "$SESSION" in
  01-underlay)      MARKER="router ospf UNDERLAY";              NODE="spine1" ;;
  02-overlay)       MARKER="address-family l2vpn evpn";         NODE="spine1" ;;
  03-l2vni)         MARKER="vn-segment 10010";                  NODE="leaf1"  ;;
  04-anycast-gw)    MARKER="fabric forwarding anycast-gateway-mac"; NODE="leaf1" ;;
  05a-tenant-b)     MARKER="vrf context Tenant-B";              NODE="leaf1"  ;;
  05b-route-leak)   MARKER="route-target import 65000:50002";   NODE="leaf1"  ;;
  *)                MARKER="";                                  NODE="leaf1"  ;;
esac

if [ -n "$MARKER" ]; then
  container="clab-vxlan-evpn-${NODE}"
  if sshpass -p admin ssh \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o LogLevel=ERROR \
       "admin@${container}" "show running-config | include \"$MARKER\"" 2>/dev/null | grep -q "$MARKER"; then
    echo "  Config OK on $NODE (found: $MARKER)"
  else
    echo "  WARNING: marker '$MARKER' missing on $NODE."
    echo "  Inspect: cat $PUSH_LOG"
  fi
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "============================================================"
echo "Switched to session $SESSION in ${ELAPSED}s"
echo "============================================================"

case "$SESSION" in
  03-l2vni)
    echo ""
    echo "Host setup for this session (re-run after switch):"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr flush dev eth1; ip addr add 10.100.10.10/24 dev eth1; ip link set eth1 up\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr flush dev eth1; ip addr add 10.100.10.11/24 dev eth1; ip link set eth1 up\""
    echo ""
    echo "Test:  docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.11"
    ;;
  04-anycast-gw)
    echo ""
    echo "Host setup for this session (re-run after switch):"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr flush dev eth1; ip addr add 10.100.10.10/24 dev eth1; ip link set eth1 up; ip route replace default via 10.100.10.1\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr flush dev eth1; ip addr add 10.100.20.10/24 dev eth1; ip link set eth1 up; ip route replace default via 10.100.20.1\""
    echo ""
    echo "Test:  docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.10"
    ;;
  05a-tenant-b)
    echo ""
    echo "Host setup for this session (host2 moves from Tenant-A to Tenant-B):"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr flush dev eth1; ip addr add 10.100.10.10/24 dev eth1; ip link set eth1 up; ip route replace default via 10.100.10.1\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr flush dev eth1; ip addr add 10.200.10.10/24 dev eth1; ip link set eth1 up; ip route replace default via 10.200.10.1\""
    echo ""
    echo "Test 1 (gateway pings - should both work):"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.1"
    echo "  docker exec clab-vxlan-evpn-host2 ping -c 3 10.200.10.1"
    echo ""
    echo "Test 2 (cross-tenant - should FAIL, proving isolation):"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10"
    ;;
  05b-route-leak)
    echo ""
    echo "No host setup needed (hosts unchanged from 5a)."
    echo ""
    echo "Test (cross-tenant ping - should now SUCCEED with TTL=62):"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10"
    ;;
esac
