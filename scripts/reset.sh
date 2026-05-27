#!/bin/bash
# Usage: ./scripts/reset.sh <session-folder>
# Example: ./scripts/reset.sh 01-underlay
#
# Destroys and redeploys the named session for a clean start.

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
  exit 1
fi

cd "$LAB_DIR"

echo "Destroying current lab..."
containerlab destroy -t "$(basename "$TOPOLOGY")" --cleanup 2>/dev/null || true

echo "Redeploying fresh..."
containerlab deploy -t "$(basename "$TOPOLOGY")"
