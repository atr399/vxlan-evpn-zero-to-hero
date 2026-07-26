#!/bin/bash
# Verify host container network state before testing a session.
# Usage: ./scripts/check-hosts.sh
# switch.sh pushes SWITCH config but never touches hosts - this checks the host side.

C="clab-vxlan-evpn"
echo "=== Host state check ==="

check_ip() {
  local host="$1" want="$2"
  local got
  got=$(docker exec "${C}-${host}" ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | grep -v '172.20' | awk '{print $2}' | head -1)
  if [ -z "$got" ]; then
    printf "  %-14s MISSING (expected %s)\n" "$host" "$want"
  elif [ "$got" = "$want" ]; then
    printf "  %-14s OK  %s\n" "$host" "$got"
  else
    printf "  %-14s DIFF got %s (expected %s)\n" "$host" "$got" "$want"
  fi
}

# host1 bond check (Sessions 6+)
if docker exec "${C}-host1" cat /proc/net/bonding/bond0 >/dev/null 2>&1; then
  ports=$(docker exec "${C}-host1" sh -c "grep -c 'Slave Interface' /proc/net/bonding/bond0" 2>/dev/null)
  mii=$(docker exec "${C}-host1" sh -c "grep -m1 'MII Status' /proc/net/bonding/bond0" 2>/dev/null | awk '{print $3}')
  printf "  %-14s bond0 present, %s slaves, MII %s\n" "host1" "${ports:-?}" "${mii:-?}"
else
  check_ip host1 "10.100.10.10/24"
fi

# Common hosts (only checks ones that exist)
for h in host2 host3 host5 host_internet; do
  docker inspect "${C}-${h}" >/dev/null 2>&1 || continue
  case "$h" in
    host2)         check_ip host2 "10.200.10.10/24" ;;
    host3)         check_ip host3 "10.100.50.10/24" ;;
    host5)         check_ip host5 "10.100.30.10/24" ;;
    host_internet) check_ip host_internet "203.0.113.10/24" ;;
  esac
done

echo ""
echo "vPC member port (if vPC sessions active):"
sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR admin@${C}-leaf1 'show vpc | include Po10' 2>/dev/null \
  | sed 's/^/  /' || echo "  (leaf1 not reachable or no vPC)"