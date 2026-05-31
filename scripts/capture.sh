#!/bin/bash
# Usage: ./scripts/capture.sh <node> <interface> <output-name> [extra-tcpdump-filter]
#
# Captures packets on a specific interface of a clab node and saves to a
# .pcap file in the current session's pcaps/ folder, ready to open in
# Wireshark.
#
# Examples:
#   ./scripts/capture.sh leaf1 eth1 03-l2vni-ping-vxlan 'udp port 4789'
#   ./scripts/capture.sh spine1 eth1 04-anycast-arp 'arp or icmp'
#
# After capture, copy the .pcap file to your local PC (e.g. via VS Code's
# right-click "Download...") and open in Wireshark.

set -euo pipefail

NODE="${1:-}"
IFACE="${2:-}"
OUTNAME="${3:-}"
FILTER="${4:-}"
COUNT="${COUNT:-50}"

if [ -z "$NODE" ] || [ -z "$IFACE" ] || [ -z "$OUTNAME" ]; then
  echo "Usage: $0 <node> <interface> <output-name> [tcpdump-filter]"
  echo ""
  echo "Examples:"
  echo "  $0 leaf1 eth1 03-l2vni-ping-vxlan 'udp port 4789'"
  echo "  $0 spine1 eth1 04-anycast-arp 'arp or icmp'"
  echo ""
  echo "Environment variables:"
  echo "  COUNT     Number of packets to capture (default 50)"
  exit 1
fi

CONTAINER="clab-vxlan-evpn-${NODE}"

# Determine which session folder we are in based on cwd
if [[ "$(pwd)" == *"/labs/"* ]]; then
  SESSION_DIR="$(pwd | sed -E 's|(.*/labs/[^/]+).*|\1|')"
else
  SESSION_DIR="$(pwd)"
fi

PCAP_DIR="${SESSION_DIR}/pcaps"
mkdir -p "$PCAP_DIR"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
PCAP_FILE="${PCAP_DIR}/${OUTNAME}-${TIMESTAMP}.pcap"

echo "Capturing on ${CONTAINER}:${IFACE}"
echo "Filter: ${FILTER:-<none>}"
echo "Count:  ${COUNT}"
echo "Output: ${PCAP_FILE}"
echo ""
echo "Trigger your traffic now (e.g. start a ping in another terminal)."
echo "Capture will stop after ${COUNT} packets or Ctrl-C."
echo ""

# -w writes raw pcap suitable for Wireshark
# -U flushes per packet so you can interrupt safely
sudo docker exec "$CONTAINER" tcpdump -i "$IFACE" -nn -e -U -w - ${FILTER:+$FILTER} -c "$COUNT" 2>/dev/null > "$PCAP_FILE"

echo ""
echo "Saved: $PCAP_FILE"
echo "Size:  $(du -h "$PCAP_FILE" | cut -f1)"
echo ""
echo "To open in Wireshark on your PC:"
echo "  1. In VS Code, right-click the .pcap file in the explorer"
echo "  2. Select 'Download...' to save it locally"
echo "  3. Open it in Wireshark"
echo ""
echo "To preview here in the terminal:"
echo "  tcpdump -r ${PCAP_FILE} -nn -e | head -20"
