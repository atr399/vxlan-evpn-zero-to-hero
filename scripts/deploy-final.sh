#!/bin/bash
# Apply Session 10 (cumulative final state with Multi-Pod) and configure all hosts.
# Saves walking through every prior session individually.

set -e
cd "$(dirname "$0")/.."

echo "===================================================================="
echo "  Applying Session 10 (Multi-Pod) cumulative cfg to 7 NX-OS switches"
echo "===================================================================="
./scripts/switch.sh 10-multipod

echo ""
echo "===================================================================="
echo "  Setting up hosts (Pod1 and Pod2)"
echo "===================================================================="

echo "[1/6] host1 with LACP bond (vPC 10) in Pod1..."
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

echo "[2/6] host2 (Pod1, VLAN 30, Tenant-B)..."
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

echo "[4/6] host3 (behind external switch, L2Out)..."
docker exec clab-vxlan-evpn-host3 sh -c '
  ip addr flush dev eth1
  ip addr add 10.100.50.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 10.100.50.1
'

echo "[5/6] host_internet (behind extrouter, L3Out)..."
docker exec clab-vxlan-evpn-host_internet sh -c '
  ip addr flush dev eth1
  ip addr add 203.0.113.10/24 dev eth1
  ip link set eth1 up
  ip route replace default via 203.0.113.1
'

echo "[6/6] host4 (Pod2, VLAN 20 in Tenant-A)..."
docker exec clab-vxlan-evpn-host4 sh -c '
  ip addr flush dev eth1
  ip addr add 10.100.20.20/24 dev eth1
  ip link set eth1 up
  ip route replace default via 10.100.20.1
'

echo ""
echo "===================================================================="
echo "  All hosts configured. Waiting 45 sec for BGP/EVPN convergence..."
echo "  (Multi-Pod adds inter-pod iBGP sessions, takes longer)"
echo "===================================================================="
sleep 45

echo ""
echo "===================================================================="
echo "  Multi-Pod connectivity tests"
echo "===================================================================="

echo ""
echo "[1] Pod1 host1 -> Pod1 host2 (cross-tenant via leak, same pod):"
docker exec clab-vxlan-evpn-host1 ping -c 2 10.200.10.10

echo ""
echo "[2] Pod1 host1 -> Pod1 host3 (L2Out external):"
docker exec clab-vxlan-evpn-host1 ping -c 2 10.100.50.10

echo ""
echo "[3] Pod1 host1 -> L3Out:"
docker exec clab-vxlan-evpn-host1 ping -c 2 203.0.113.10

echo ""
echo "[4] **Pod1 host1 -> Pod2 host4 (CROSS-POD, same Tenant-A):**"
docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.20

echo ""
echo "[5] **Pod2 host4 -> Pod1 host1 (reverse cross-pod):**"
docker exec clab-vxlan-evpn-host4 ping -c 3 10.100.10.10

echo ""
echo "[6] **Pod2 host4 -> Pod1 host2 (cross-pod, cross-tenant via leak):**"
docker exec clab-vxlan-evpn-host4 ping -c 3 10.200.10.10

echo ""
echo "[7] **Pod2 host4 -> L3Out (cross-pod, then out Pod1's L3Out):**"
docker exec clab-vxlan-evpn-host4 ping -c 3 203.0.113.10

echo ""
echo "===================================================================="
echo "  Done."
echo "===================================================================="
