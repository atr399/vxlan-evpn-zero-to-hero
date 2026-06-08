#!/bin/bash
# Apply Session 11 (Multi-Site cumulative) and configure all hosts.

set -e
cd "$(dirname "$0")/.."

echo "===================================================================="
echo "  Applying Session 11 (Multi-Site) cumulative cfg to 8 NX-OS switches"
echo "===================================================================="
./scripts/switch.sh 11-multisite

echo ""
echo "===================================================================="
echo "  Setting up hosts (Site1 + Site2)"
echo "===================================================================="

echo "[1/6] host1 with LACP bond (vPC 10) in Site1..."
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

echo "[2/6] host2 (Site1, VLAN 30, Tenant-B)..."
docker exec clab-vxlan-evpn-host2 sh -c '
  ip addr flush dev eth1
  ip addr add 10.200.10.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 10.200.10.1
'

echo "[3/6] external switch (L2Out bridge)..."
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

echo "[4/6] host3 (behind external switch, Site1 L2Out)..."
docker exec clab-vxlan-evpn-host3 sh -c '
  ip addr flush dev eth1
  ip addr add 10.100.50.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 10.100.50.1
'

echo "[5/6] host_internet (behind extrouter, Site1 L3Out)..."
docker exec clab-vxlan-evpn-host_internet sh -c '
  ip addr flush dev eth1
  ip addr add 203.0.113.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 203.0.113.1
'

echo "[6/6] host5 (Site2, VLAN 60 in Tenant-A, subnet 10.100.30.0/24)..."
docker exec clab-vxlan-evpn-host5 sh -c '
  ip addr flush dev eth1
  ip addr add 10.100.30.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 10.100.30.1
'

echo ""
echo "===================================================================="
echo "  Waiting 60 sec for Multi-Site convergence..."
echo "  (eBGP-EVPN over DCI + delay-restore 30 sec)"
echo "===================================================================="
sleep 60

echo ""
echo "===================================================================="
echo "  Multi-Site connectivity tests"
echo "===================================================================="

echo ""
echo "[1] Site1 host1 -> Site1 host2 (regression - intra-site cross-tenant):"
docker exec clab-vxlan-evpn-host1 ping -c 2 10.200.10.10

echo ""
echo "[2] Site1 host1 -> Site1 host3 (regression - L2Out):"
docker exec clab-vxlan-evpn-host1 ping -c 2 10.100.50.10

echo ""
echo "[3] Site1 host1 -> L3Out (regression):"
docker exec clab-vxlan-evpn-host1 ping -c 2 203.0.113.10

echo ""
echo "[4] **Site1 host1 -> Site2 host5 (CROSS-SITE L3, AS 65000 -> AS 65001):**"
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.30.10

echo ""
echo "[5] **Site2 host5 -> Site1 host1 (reverse cross-site):**"
docker exec clab-vxlan-evpn-host5 ping -c 3 10.100.10.10

echo ""
echo "[6] **Site2 host5 -> Site1 L3Out (Multi-Site + L3Out from foreign site):**"
docker exec clab-vxlan-evpn-host5 ping -c 3 203.0.113.10

echo ""
echo "[7] **External internet -> Site2 host5 (extrouter -> Site1 -> DCI -> Site2):**"
docker exec clab-vxlan-evpn-host_internet ping -c 3 10.100.30.10

echo ""
echo "===================================================================="
echo "  Done."
echo "===================================================================="
