#!/bin/bash
# Apply Session 9 (cumulative final state) and configure all hosts in one shot.
# Saves walking through sessions 4 -> 5b -> 6a -> 6b -> 6c -> 8 -> 9 individually.
#
# Usage:  ./scripts/deploy-final.sh

set -e
cd "$(dirname "$0")/.."

echo "===================================================================="
echo "  Applying Session 9 cumulative cfg to all four NX-OS switches"
echo "===================================================================="
./scripts/switch.sh 09-l3out

echo ""
echo "===================================================================="
echo "  Setting up hosts"
echo "===================================================================="

echo "[1/5] host1 with LACP bond (vPC 10)..."
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

echo "[2/5] host2 (VLAN 30, Tenant-B)..."
docker exec clab-vxlan-evpn-host2 sh -c '
  ip addr flush dev eth1
  ip addr add 10.200.10.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 10.200.10.1
'

echo "[3/5] external switch (L2Out bridge with VLAN 50 sub-interface)..."
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

echo "[4/5] host3 (behind external switch, VLAN 50, Tenant-A)..."
docker exec clab-vxlan-evpn-host3 sh -c '
  ip addr flush dev eth1
  ip addr add 10.100.50.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 10.100.50.1
'

echo "[5/5] host_internet (behind extrouter, simulates the internet)..."
docker exec clab-vxlan-evpn-host_internet sh -c '
  ip addr flush dev eth1
  ip addr add 203.0.113.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 203.0.113.1
'

echo ""
echo "===================================================================="
echo "  All hosts configured. Waiting 30 sec for BGP convergence..."
echo "===================================================================="
sleep 30

echo ""
echo "===================================================================="
echo "  Quick connectivity tests"
echo "===================================================================="

echo ""
echo "[1] host1 -> host2 (Tenant-A -> Tenant-B via route leak, cross-leaf):"
docker exec clab-vxlan-evpn-host1 ping -c 2 10.200.10.10

echo ""
echo "[2] host1 -> host3 (Tenant-A, leaf1 -> L2Out external -> host3):"
docker exec clab-vxlan-evpn-host1 ping -c 2 10.100.50.10

echo ""
echo "[3] host1 -> 203.0.113.10 (fabric -> L3Out via leaf1):"
docker exec clab-vxlan-evpn-host1 ping -c 2 203.0.113.10

echo ""
echo "[4] host2 -> 203.0.113.10 (Tenant-B -> leak -> L3Out, via leaf2 direct eBGP):"
docker exec clab-vxlan-evpn-host2 ping -c 2 203.0.113.10

echo ""
echo "[5] host_internet -> 10.100.10.10 (external -> fabric):"
docker exec clab-vxlan-evpn-host_internet ping -c 2 10.100.10.10

echo ""
echo "[6] host_internet -> 10.200.10.10 (external -> fabric Tenant-B via leak):"
docker exec clab-vxlan-evpn-host_internet ping -c 2 10.200.10.10

echo ""
echo "===================================================================="
echo "  Done."
echo "===================================================================="
