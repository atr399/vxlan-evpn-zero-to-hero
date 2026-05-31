#!/bin/bash
# Internal helper: re-push session cfg files via SSH.
# Called by restore.sh if it detects the snapshot didn't preserve config.
# Not meant to be called directly.

set -euo pipefail

SESSION="${1:-}"

if [ -z "$SESSION" ]; then
  echo "Usage: $0 <session-folder> (internal)"
  exit 1
fi

LAB_DIR="labs/${SESSION}"
CFG_DIR="${LAB_DIR}/configs"

if [ ! -d "$CFG_DIR" ]; then
  echo "ERROR: cfg directory not found: $CFG_DIR"
  exit 1
fi

NODES=("spine1" "spine2" "leaf1" "leaf2")

for node in "${NODES[@]}"; do
  cfg_file="${CFG_DIR}/${node}.cfg"
  container="clab-vxlan-evpn-${node}"

  if [ ! -f "$cfg_file" ]; then
    echo "  $node: no cfg file, skipping"
    continue
  fi

  echo "  Pushing $cfg_file -> $container"

  # Build the config push as a single SSH session.
  # configure terminal, paste the cfg lines (stripped of comments/blanks),
  # end, and copy running-config startup-config.
  {
    echo "configure terminal"
    grep -v '^!' "$cfg_file" | grep -v '^[[:space:]]*$'
    echo "end"
    echo "copy running-config startup-config"
  } | sshpass -p admin ssh -tt \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "admin@${container}" 2>&1 | tail -5
done

echo ""
echo "Config re-push complete. Allow ~30 sec for protocols to converge."
