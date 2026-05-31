#!/bin/bash
# Usage: ./scripts/lab.sh <session-folder>
# Example: ./scripts/lab.sh 04-anycast-gw
#
# Deploys a session in ~90 seconds:
# 1. Destroys any running lab
# 2. Deploys 4 NX-OS nodes from warm baseline snapshot (~30 sec to boot)
# 3. Pushes the session's cfg files via SSH in parallel (~30-60 sec)
# 4. Verifies a session-specific config marker exists
# 5. Reports what host setup to run
#
# Requires: ./scripts/bootstrap.sh has been run at least once.

set -euo pipefail

SESSION="${1:-}"

if [ -z "$SESSION" ]; then
  echo "Usage: $0 <session-folder>"
  echo ""
  echo "Available sessions:"
  ls labs/ 2>/dev/null | grep -v pcaps | sed 's/^/  /'
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

# Check warm baseline exists
for node in "${NODES[@]}"; do
  if ! docker image inspect "vxlan-warm:${node}" >/dev/null 2>&1; then
    echo "ERROR: Warm baseline image vxlan-warm:${node} not found."
    echo "Run ./scripts/bootstrap.sh first (one-time, ~20 min)."
    exit 1
  fi
done

# Check sshpass is available (for cfg push)
if ! command -v sshpass >/dev/null 2>&1; then
  echo "ERROR: sshpass not installed. Run: sudo apt install -y sshpass"
  exit 1
fi

# Generate a temporary topology that uses warm baseline images
WARM_TOPO="${REPO_ROOT}/scripts/_active.clab.yml"

echo "==> Generating warm topology..."
cat > "$WARM_TOPO" << 'EOF'
name: vxlan-evpn

topology:
  nodes:
    spine1:
      kind: cisco_n9kv
      image: vxlan-warm:spine1
    spine2:
      kind: cisco_n9kv
      image: vxlan-warm:spine2
    leaf1:
      kind: cisco_n9kv
      image: vxlan-warm:leaf1
    leaf2:
      kind: cisco_n9kv
      image: vxlan-warm:leaf2
    host1:
      kind: linux
      image: alpine:latest
    host2:
      kind: linux
      image: alpine:latest

  links:
    - endpoints: ["spine1:eth1", "leaf1:eth1"]
    - endpoints: ["spine1:eth2", "leaf2:eth1"]
    - endpoints: ["spine2:eth1", "leaf1:eth2"]
    - endpoints: ["spine2:eth2", "leaf2:eth2"]
    - endpoints: ["leaf1:eth3", "host1:eth1"]
    - endpoints: ["leaf2:eth3", "host2:eth1"]
EOF

# Destroy anything currently running
echo "==> Destroying any current lab..."
containerlab destroy -t "$WARM_TOPO" --cleanup 2>/dev/null || true
# Also nuke any session-specific topology
for topo in "${REPO_ROOT}"/labs/*/topology.clab.yml; do
  [ -f "$topo" ] && containerlab destroy -t "$topo" --cleanup 2>/dev/null || true
done

echo ""
echo "==> Deploying from warm baseline..."
START_TIME=$(date +%s)
containerlab deploy -t "$WARM_TOPO"

# Wait for healthy
echo ""
echo "==> Waiting for NX-OS to be responsive..."
ready=0
for i in $(seq 1 24); do
  ready=0
  for node in "${NODES[@]}"; do
    container="clab-vxlan-evpn-${node}"
    status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
    [ "$status" = "healthy" ] && ready=$((ready+1))
  done
  if [ "$ready" -eq 4 ]; then
    echo "  All 4 NX-OS nodes healthy."
    break
  fi
  echo "  [$i/24] $ready/4 healthy..."
  sleep 5
done

if [ "$ready" -lt 4 ]; then
  echo "WARNING: not all nodes healthy in 2 min. Continuing anyway."
fi

echo ""
echo "==> Pushing session cfg files in parallel..."

# Push each node's cfg in parallel
PUSH_LOG="${REPO_ROOT}/scripts/_push.log"
> "$PUSH_LOG"

push_cfg() {
  local node="$1"
  local cfg_file="${CFG_DIR}/${node}.cfg"
  local container="clab-vxlan-evpn-${node}"

  if [ ! -f "$cfg_file" ]; then
    echo "  [$node] no cfg file, skipping" >> "$PUSH_LOG"
    return
  fi

  echo "  [$node] pushing $(wc -l < "$cfg_file") lines..." >> "$PUSH_LOG"

  # Strip comments and blank lines, then push via SSH
  {
    echo "terminal length 0"
    echo "configure terminal"
    grep -v '^!' "$cfg_file" | grep -v '^[[:space:]]*$'
    echo "end"
    echo "copy running-config startup-config"
  } | sshpass -p admin ssh -tt \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout=10 \
      "admin@${container}" >> "$PUSH_LOG" 2>&1 || \
      echo "  [$node] push failed (see $PUSH_LOG)" >> "$PUSH_LOG"
}

# Kick off parallel pushes
for node in "${NODES[@]}"; do
  push_cfg "$node" &
done

# Wait for all pushes to finish
wait

cat "$PUSH_LOG" | grep -E '^\s+\[' || true

# Verify session marker
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
  if sshpass -p admin ssh \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o LogLevel=ERROR \
       "admin@${container}" "show running-config | include \"$MARKER\"" 2>/dev/null | grep -q "$MARKER"; then
    echo "  Config OK on $NODE (found: $MARKER)"
  else
    echo "  WARNING: marker '$MARKER' missing on $NODE"
    echo "  Check $PUSH_LOG for push errors"
  fi
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "============================================================"
echo "Session $SESSION deployed in ${ELAPSED}s"
echo "============================================================"

# Print host setup commands relevant to this session
case "$SESSION" in
  03-l2vni)
    echo ""
    echo "Run host setup:"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr add 10.100.10.10/24 dev eth1 && ip link set eth1 up\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr add 10.100.10.11/24 dev eth1 && ip link set eth1 up\""
    echo ""
    echo "Then test:"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.10.11"
    ;;
  04-anycast-gw)
    echo ""
    echo "Run host setup:"
    echo "  docker exec clab-vxlan-evpn-host1 sh -c \"ip addr add 10.100.10.10/24 dev eth1 && ip link set eth1 up && ip route replace default via 10.100.10.1\""
    echo "  docker exec clab-vxlan-evpn-host2 sh -c \"ip addr add 10.100.20.10/24 dev eth1 && ip link set eth1 up && ip route replace default via 10.100.20.1\""
    echo ""
    echo "Then test:"
    echo "  docker exec clab-vxlan-evpn-host1 ping -c 3 10.100.20.10"
    ;;
esac

echo ""
echo "To inspect:    docker ps"
echo "To tear down:  ./scripts/teardown.sh"
