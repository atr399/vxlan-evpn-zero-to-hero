#!/bin/bash
# Usage: ./scripts/snapshot-list.sh
# Lists all existing snapshots and their disk usage.

set -euo pipefail

echo "Available snapshots:"
echo ""

# Get unique session names from images named vxlan-snapshot-*
sessions=$(docker images --format "{{.Repository}}" | \
           grep -E '^vxlan-snapshot-' | \
           sed -E 's/^vxlan-snapshot-(.+)$/\1/' | \
           sort -u)

if [ -z "$sessions" ]; then
  echo "  (none)"
  echo ""
  echo "To create a snapshot:"
  echo "  ./scripts/deploy.sh <session>     # boot + configure"
  echo "  # verify lab works"
  echo "  ./scripts/snapshot.sh <session>   # save current state"
  exit 0
fi

printf "  %-25s %-15s %s\n" "SESSION" "DISK USAGE" "IMAGES"
printf "  %-25s %-15s %s\n" "-------" "----------" "------"

total_kb=0
for session in $sessions; do
  prefix="vxlan-snapshot-${session}"
  count=$(docker images --format "{{.Repository}}" | grep -c "^${prefix}$" || true)
  
  # Total size in bytes for this session's images
  size_bytes=$(docker images "${prefix}*" --format "{{.Size}}" | \
    awk '{ 
      val=substr($1,1,length($1)-2)
      unit=substr($1,length($1)-1)
      if(unit=="kB") val*=1024
      else if(unit=="MB") val*=1024*1024
      else if(unit=="GB") val*=1024*1024*1024
      total+=val
    } END { printf "%d", total }')
  
  if [ -n "$size_bytes" ] && [ "$size_bytes" -gt 0 ]; then
    size_gb=$(awk -v b="$size_bytes" 'BEGIN { printf "%.1f GB", b/1024/1024/1024 }')
  else
    size_gb="(unknown)"
  fi
  
  printf "  %-25s %-15s %d images\n" "$session" "$size_gb" "$count"
done

echo ""
echo "Disk free on filesystem:"
df -h /var/lib/docker 2>/dev/null | tail -1 | awk '{print "  " $4 " available on " $6}'

echo ""
echo "To restore a snapshot:"
echo "  ./scripts/restore.sh <session-name>"
echo ""
echo "To delete a specific snapshot (frees disk):"
echo "  docker rmi \$(docker images vxlan-snapshot-<session>* -q)"
