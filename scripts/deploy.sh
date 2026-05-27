#!/bin/bash
# Usage: ./scripts/deploy.sh <session-folder>
# Example: ./scripts/deploy.sh 01-underlay
#
# Deploys the named session's containerlab topology.

set -euo pipefail

SESSION="${1:-}"

if [ -z "$SESSION" ]; then
  echo "Usage: $0 <session-folder>"
  echo ""
  echo "Available sessions:"
  ls labs/ 2>/dev/null | sed 's/^/  /'
  exit 1
fi

LAB_DIR="labs/${SESSION}"
TOPOLOGY="${LAB_DIR}/topology.clab.yml"

if [ ! -f "$TOPOLOGY" ]; then
  echo "Topology not found: $TOPOLOGY"
  echo ""
  echo "Available sessions:"
  ls labs/ 2>/dev/null | sed 's/^/  /'
  exit 1
fi

echo "Deploying session: $SESSION"
echo "Topology: $TOPOLOGY"
echo ""
echo "This will take several minutes (Cisco Nexus 9000v needs 5-10 min per node to boot)."
echo "You can watch a node's boot progress in another terminal with:"
echo "  docker logs -f clab-vxlan-evpn-spine1"
echo ""

cd "$LAB_DIR"
containerlab deploy -t "$(basename "$TOPOLOGY")"
