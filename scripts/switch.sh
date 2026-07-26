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
# Dynamic NODES discovery - includes ALL .cfg files in the session directory
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
  echo "ERROR: $missing/${#NODES[@]} NX-OS containers not running."
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
  07-ebgp-underlay)  MARKER="rewrite-evpn-rt-asn";               NODE="spine1" ;;
  08-l2out)          MARKER="vn-segment 10050";                  NODE="leaf1"  ;;
  09-l3out)          MARKER="neighbor 192.0.2.0";                NODE="leaf1"  ;;
  10-multipod)       MARKER="neighbor 10.0.0.13";                NODE="spine1" ;;
  11-multisite)      MARKER="multisite border-gateway";          NODE="spine1" ;;
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
    echo "6c assumes host1's bond from 6b is still up - VERIFY, don't assume:"
    echo "  ssh admin@clab-vxlan-evpn-leaf1 'show vpc | include Po10'"
    echo "  # want: Po10 ... up   (if 'down*', rebuild the bond below, then wait 30s)"
    echo ""
    echo "  If Po10 is down (or host1 can't ping its gateway), rebuild host1's bond:"
    cat << 'BOND6C'
 
  docker exec clab-vxlan-evpn-host1 sh -c '
    ip link set bond0 down 2>/dev/null
    ip link delete bond0 2>/dev/null
    ip link add bond0 type bond
    echo 802.3ad > /sys/class/net/bond0/bonding/mode
    echo fast > /sys/class/net/bond0/bonding/lacp_rate
    echo 100 > /sys/class/net/bond0/bonding/miimon
    ip link set eth1 down
    ip link set eth2 down
    ip addr flush dev eth1
    ip addr flush dev eth2
    ip link set eth1 master bond0
    ip link set eth2 master bond0
    ip link set eth1 up
    ip link set eth2 up
    ip link set bond0 up
    ip addr add 10.100.10.10/24 dev bond0
    ip route replace default via 10.100.10.1
  '
 
BOND6C
    echo "  Then wait ~30s for LACP and re-check: show vpc | include Po10  (want up)."
    echo ""
    echo "Verify the keystone fix:"
    echo "  ssh admin@clab-vxlan-evpn-leaf1"
    echo "  show vpc                          # expect Configuration consistency status: success"
    echo "  show nve interface nve1 detail    # expect VPC-VIP-Only [notified], secondary 10.0.1.100"
    echo ""
    echo "Then test connectivity - NOTE host2 is Tenant-B (10.200.10.10) since 5a, so this is"
    echo "a CROSS-TENANT test via the 5b leak (NOT 10.100.20.10 - nothing lives there in this chain):"
    echo "  docker exec clab-vxlan-evpn-host2 ip addr show eth1     # confirm 10.200.10.10 first"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.200.10.10   # expect TTL 63"
    ;;
  08-l2out)
    echo ""
    echo "Setup for 8 — external switch (Linux bridge) + host3:"
    cat << 'L2OUT'

  # external switch: VLAN sub-interface bridged to host port.
  # (Alpine has NO 'bridge' command, so vlan-filtering does not work.)
  docker exec clab-vxlan-evpn-external sh -c '
    ip link set br0 down 2>/dev/null
    ip link delete br0 2>/dev/null
    ip link delete eth1.50 2>/dev/null
    ip link add link eth1 name eth1.50 type vlan id 50
    ip link add br0 type bridge
    ip link set eth1.50 master br0
    ip link set eth2 master br0
    ip link set eth1 up
    ip link set eth1.50 up
    ip link set eth2 up
    ip link set br0 up
  '

  # host3: plain access host in VLAN 50
  docker exec clab-vxlan-evpn-host3 sh -c '
    ip addr flush dev eth1
    ip addr add 10.100.50.10/24 dev eth1
    ip link set eth1 up
    ip route replace default via 10.100.50.1
  '

  # host1: MUST be an LACP bond - it inherits the vPC from Session 6.
  # A plain IP leaves leaf1 Eth1/3 suspended(no LACP PDUs) and host1 unreachable.
  docker exec clab-vxlan-evpn-host1 sh -c '
    ip link set bond0 down 2>/dev/null
    ip link delete bond0 2>/dev/null
    ip link add bond0 type bond
    echo 802.3ad > /sys/class/net/bond0/bonding/mode
    echo fast > /sys/class/net/bond0/bonding/lacp_rate
    echo 100 > /sys/class/net/bond0/bonding/miimon
    ip link set eth1 down
    ip link set eth2 down
    ip addr flush dev eth1
    ip addr flush dev eth2
    ip link set eth1 master bond0
    ip link set eth2 master bond0
    ip link set eth1 up
    ip link set eth2 up
    ip link set bond0 up
    ip addr add 10.100.10.10/24 dev bond0
    ip route replace default via 10.100.10.1
  '

  # host2: Tenant-B (for the cross-tenant test)
  docker exec clab-vxlan-evpn-host2 sh -c '
    ip addr flush dev eth1
    ip addr add 10.200.10.10/24 dev eth1
    ip link set eth1 up
    ip route replace default via 10.200.10.1
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

  # host1: LACP bond (inherits vPC from Session 6 - required or unreachable)
  docker exec clab-vxlan-evpn-host1 sh -c '
    ip link set bond0 down 2>/dev/null
    ip link delete bond0 2>/dev/null
    ip link add bond0 type bond
    echo 802.3ad > /sys/class/net/bond0/bonding/mode
    echo fast > /sys/class/net/bond0/bonding/lacp_rate
    echo 100 > /sys/class/net/bond0/bonding/miimon
    ip link set eth1 down
    ip link set eth2 down
    ip addr flush dev eth1
    ip addr flush dev eth2
    ip link set eth1 master bond0
    ip link set eth2 master bond0
    ip link set eth1 up
    ip link set eth2 up
    ip link set bond0 up
    ip addr add 10.100.10.10/24 dev bond0
    ip route replace default via 10.100.10.1
  '

  # host2: Tenant-B
  docker exec clab-vxlan-evpn-host2 sh -c '
    ip addr flush dev eth1
    ip addr add 10.200.10.10/24 dev eth1
    ip link set eth1 up
    ip route replace default via 10.200.10.1
  '

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

  11-multisite)
    echo ""
    echo "Setup for 11 - Site2 host (host5 in Tenant-A VLAN 60, subnet 10.100.30.0/24):"
    cat << 'SITE2'

  # host1: LACP bond (inherits vPC from Session 6 - required or unreachable)
  docker exec clab-vxlan-evpn-host1 sh -c '
    ip link set bond0 down 2>/dev/null
    ip link delete bond0 2>/dev/null
    ip link add bond0 type bond
    echo 802.3ad > /sys/class/net/bond0/bonding/mode
    echo fast > /sys/class/net/bond0/bonding/lacp_rate
    echo 100 > /sys/class/net/bond0/bonding/miimon
    ip link set eth1 down
    ip link set eth2 down
    ip addr flush dev eth1
    ip addr flush dev eth2
    ip link set eth1 master bond0
    ip link set eth2 master bond0
    ip link set eth1 up
    ip link set eth2 up
    ip link set bond0 up
    ip addr add 10.100.10.10/24 dev bond0
    ip route replace default via 10.100.10.1
  '

  # host2: Tenant-B
  docker exec clab-vxlan-evpn-host2 sh -c '
    ip addr flush dev eth1
    ip addr add 10.200.10.10/24 dev eth1
    ip link set eth1 up
    ip route replace default via 10.200.10.1
  '

  # host5 is in Site2 (separate AS 65001), attached to leaf4 in VLAN 60 / 10.100.30.0/24
  # NOTE: L3-only stretching - VLAN 60 only exists in Site2, NOT in Site1
  docker exec clab-vxlan-evpn-host5 sh -c '
    ip addr flush dev eth1
    ip addr add 10.100.30.10/24 dev eth1
    ip link set eth1 up
    ip route replace default via 10.100.30.1
  '

SITE2
    echo "Verify Multi-Site state (spine1 is the collapsed spine+BGW for Site1):"
    echo "  ssh admin@clab-vxlan-evpn-spine1"
    echo "  show bgp l2vpn evpn summary       # leaf RR clients + eBGP-EVPN to spine5 (Site2)"
    echo "  show nve interface nve1 detail    # Multisite bgw-if loopback2 oper Up"
    echo "  show ip route 10.0.2.200          # reachability to Site2 BGW VIP (via DCI OSPF)"
    echo ""
    echo "  # On leaf1, confirm the cross-site route has next-hop 10.0.2.100 (NOT 192.168.100.1):"
    echo "  ssh admin@clab-vxlan-evpn-leaf1; show ip route 10.100.30.0/24 vrf Tenant-A"
    echo ""
    echo "Multi-Site tests (cross-site ping):"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.30.10   # Site1 -> Site2"
    echo "  docker exec clab-vxlan-evpn-host5 ping -c 3 10.100.10.10   # Site2 -> Site1"
    echo "  docker exec clab-vxlan-evpn-host5 ping -c 3 203.0.113.10   # Site2 -> L3Out (via Site1)"
    echo "  docker exec clab-vxlan-evpn-host_internet ping -c 3 10.100.30.10  # external -> Site2"
    ;;
esac
