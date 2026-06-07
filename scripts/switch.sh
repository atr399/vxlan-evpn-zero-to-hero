#!/bin/bash
# Usage: ./scripts/switch.sh <session-folder>

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
# NODES list - dynamically discover from CFG_DIR
NODES=()
for cfg in "$CFG_DIR"/*.cfg; do
  [ -f "$cfg" ] || continue
  name=$(basename "$cfg" .cfg)
  NODES+=("$name")
done
echo "Pushing to: ${NODES[*]}"

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
  01-underlay)       MARKER="router ospf UNDERLAY";              NODE="spine1" ;;
  02-overlay)        MARKER="address-family l2vpn evpn";         NODE="spine1" ;;
  03-l2vni)          MARKER="vn-segment 10010";                  NODE="leaf1"  ;;
  04-anycast-gw)     MARKER="fabric forwarding anycast-gateway-mac"; NODE="leaf1" ;;
  05a-tenant-b)      MARKER="vrf context Tenant-B";              NODE="leaf1"  ;;
  05b-route-leak)    MARKER="route-target import 65000:50002";   NODE="leaf1"  ;;
  06a-vpc-base)      MARKER="vpc domain 10";                     NODE="leaf1"  ;;
  06b-vpc-host-bond) MARKER="vpc 10";                            NODE="leaf1"  ;;
  06c-vpc-vxlan)     MARKER="10.0.1.100 secondary";              NODE="leaf1"  ;;
  08-l2out)          MARKER="vn-segment 10050";                  NODE="leaf1"  ;;
  09-l3out)          MARKER="neighbor 192.0.2.0";                NODE="leaf1"  ;;
  10-multipod)       MARKER="neighbor 10.0.0.13";                NODE="spine1" ;;
  *)                 MARKER="";                                  NODE="leaf1"  ;;
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
    echo "Host setup:"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr flush dev eth1; ip addr add 10.100.10.10/24 dev eth1; ip link set eth1 up\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr flush dev eth1; ip addr add 10.100.10.11/24 dev eth1; ip link set eth1 up\""
    echo ""
    echo "Test:  docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.11"
    ;;
  04-anycast-gw)
    echo ""
    echo "Host setup:"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr flush dev eth1; ip addr add 10.100.10.10/24 dev eth1; ip link set eth1 up; ip route replace default via 10.100.10.1\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr flush dev eth1; ip addr add 10.100.20.10/24 dev eth1; ip link set eth1 up; ip route replace default via 10.100.20.1\""
    echo ""
    echo "Test:  docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.10"
    ;;
  05a-tenant-b)
    echo ""
    echo "Host setup (host2 moves from Tenant-A to Tenant-B):"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr flush dev eth1; ip addr add 10.100.10.10/24 dev eth1; ip link set eth1 up; ip route replace default via 10.100.10.1\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr flush dev eth1; ip addr add 10.200.10.10/24 dev eth1; ip link set eth1 up; ip route replace default via 10.200.10.1\""
    echo ""
    echo "Test isolation (should FAIL):"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10"
    ;;
  05b-route-leak)
    echo ""
    echo "No host setup needed."
    echo "Test (should SUCCEED with TTL=62):"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10"
    ;;
  06a-vpc-base)
    echo ""
    echo "No host setup needed for 6a."
    echo ""
    echo "Verify vPC:"
    echo "  ssh admin@clab-vxlan-evpn-leaf1"
    echo "  show vpc       # expect 'peer adjacency formed ok'"
    ;;
  06b-vpc-host-bond)
    echo ""
    echo "Host setup for 6b — host1 forms LACP bond via sysfs (more reliable than ip link options):"
    cat << 'BONDSETUP'

  docker exec clab-vxlan-evpn-host1 sh -c '
    # Tear down any old bond
    ip link set bond0 down 2>/dev/null
    ip link delete bond0 2>/dev/null

    # Recreate bond0 and set mode via sysfs (Alpine's ip cmd does not reliably set mode)
    ip link add bond0 type bond
    echo 802.3ad > /sys/class/net/bond0/bonding/mode
    echo fast > /sys/class/net/bond0/bonding/lacp_rate
    echo 100 > /sys/class/net/bond0/bonding/miimon

    # Bring slaves down and clear addresses
    ip link set eth1 down
    ip link set eth2 down
    ip addr flush dev eth1
    ip addr flush dev eth2

    # Enslave
    ip link set eth1 master bond0
    ip link set eth2 master bond0

    # Bring up
    ip link set eth1 up
    ip link set eth2 up
    ip link set bond0 up

    # IP on bond0
    ip addr add 10.100.10.10/24 dev bond0
    ip route replace default via 10.100.10.1
  '

BONDSETUP
    echo "Wait ~30 sec for LACP convergence, then verify:"
    echo "  docker exec clab-vxlan-evpn-host1 cat /proc/net/bonding/bond0 | head -3"
    echo "  (expect: Bonding Mode: IEEE 802.3ad Dynamic link aggregation)"
    echo ""
    echo "EXPECTED: vPC 10 status DOWN due to consistency failure."
    echo "  ssh admin@clab-vxlan-evpn-leaf1; show vpc"
    echo "  (Configuration consistency status: failed - this is intentional)"
    echo ""
    echo "Session 6c fixes this with the shared VTEP IP."
    ;;
  06c-vpc-vxlan)
    echo ""
    echo "No host setup needed for 6c (host1 bond already in place from 6b)."
    echo ""
    echo "Verify the keystone fix:"
    echo "  ssh admin@clab-vxlan-evpn-leaf1"
    echo "  show vpc        # expect Configuration consistency status: success"
    echo "  show nve interface nve1 detail   # expect VPC-VIP-Only [notified]"
    echo ""
    echo "Then test connectivity:"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10"
    ;;
  08-l2out)
    echo ""
    echo "Setup for 8 — external switch (Linux bridge) + host3:"
    cat << 'L2OUT'

  # Configure external as VLAN-aware Linux bridge
  docker exec clab-vxlan-evpn-external sh -c '
    ip link add br0 type bridge vlan_filtering 1 2>/dev/null || true
    ip link set eth1 master br0
    ip link set eth2 master br0
    bridge vlan add vid 50 dev eth1 tagged
    bridge vlan add vid 50 dev br0 self tagged
    bridge vlan add vid 50 dev eth2 pvid untagged
    bridge vlan del vid 1 dev eth2 2>/dev/null
    ip link set eth1 up
    ip link set eth2 up
    ip link set br0 up
  '

  # Configure host3 with VLAN 50 subnet IP
  docker exec clab-vxlan-evpn-host3 sh -c '
    ip addr flush dev eth1
    ip addr add 10.100.50.10/24 dev eth1
    ip link set eth1 up
    ip route replace default via 10.100.50.1
  '

L2OUT
    echo "Then test L2Out:"
    echo "  docker exec clab-vxlan-evpn-host3 ping -c 3 10.100.50.1       # external to gateway"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.50.10      # fabric to external"
    echo "  docker exec clab-vxlan-evpn-host2 ping -c 3 10.100.50.10      # cross-tenant via leak"
    ;;

  09-l3out)
    echo ""
    echo "Setup for 9 - configure host_internet:"
    cat << 'L3OUT'

  # extrouter (cEOS) loaded its startup-config at deploy time. No setup needed.
  # Just configure host_internet IP and default route.
  docker exec clab-vxlan-evpn-host_internet sh -c '
    ip addr flush dev eth1
    ip addr add 203.0.113.10/24 dev eth1
    ip link set eth1 up
    ip route replace default via 203.0.113.1
  '

L3OUT
    echo "Verify BGP up (wait ~30 sec for both eBGP sessions):"
    echo "  docker exec clab-vxlan-evpn-extrouter Cli -c 'show ip bgp summary'"
    echo "  ssh admin@clab-vxlan-evpn-leaf1"
    echo "  show bgp vrf Tenant-A ipv4 unicast summary"
    echo ""
    echo "End-to-end tests:"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 203.0.113.10"
    echo "  docker exec clab-vxlan-evpn-host2 ping -c 3 203.0.113.10"
    echo "  docker exec clab-vxlan-evpn-host_internet ping -c 3 10.100.10.10"
    echo "  docker exec clab-vxlan-evpn-host_internet ping -c 3 10.200.10.10  # via route leak"
    ;;

  10-multipod)
    echo ""
    echo "Setup for 10 - Pod2 host (host4 in Tenant-A VLAN 20):"
    cat << 'POD2'

  # host4 is in Pod2, attached to leaf3 access port (VLAN 20, subnet 10.100.20.0/24)
  docker exec clab-vxlan-evpn-host4 sh -c '
    ip addr flush dev eth1
    ip addr add 10.100.20.20/24 dev eth1
    ip link set eth1 up
    ip route replace default via 10.100.20.1
  '

POD2
    echo "Verify inter-pod EVPN sessions established (wait ~30 sec):"
    echo "  ssh admin@clab-vxlan-evpn-spine1"
    echo "  show bgp l2vpn evpn summary    # expect 4 peers: leaf1, leaf2, spine3, spine4"
    echo ""
    echo "Multi-Pod tests (cross-pod ping):"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.20   # Pod1 to Pod2 (same VRF)"
    echo "  docker exec clab-vxlan-evpn-host4 ping -c 3 10.100.10.10   # Pod2 to Pod1"
    echo "  docker exec clab-vxlan-evpn-host4 ping -c 3 203.0.113.10   # Pod2 to L3Out (via Pod1)"
    ;;
esac
