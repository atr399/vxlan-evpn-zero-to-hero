#!/bin/bash
# Usage: ./scripts/teardown.sh
#
# Destroys the running lab. Keeps the warm baseline snapshot.
# After this, use ./scripts/lab.sh <session> to bring a session back up.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTIVE_TOPO="${REPO_ROOT}/scripts/_active.clab.yml"

echo "==> Destroying current lab..."
if [ -f "$ACTIVE_TOPO" ]; then
  containerlab destroy -t "$ACTIVE_TOPO" --cleanup 2>/dev/null || true
fi

# Also clean up any session-specific topology that might be running
for topo in "${REPO_ROOT}"/labs/*/topology.clab.yml; do
  [ -f "$topo" ] && containerlab destroy -t "$topo" --cleanup 2>/dev/null || true
done

echo ""
echo "Lab torn down. Warm baseline snapshots are preserved."
echo ""
echo "To start a session:"
echo "  ./scripts/lab.sh 01-underlay"
echo ""
echo "Disk used by warm baseline:"
docker images vxlan-warm* --format "  {{.Repository}}:{{.Tag}}  {{.Size}}" 2>/dev/null || \
  echo "  (no warm baseline found; run ./scripts/bootstrap.sh)"
