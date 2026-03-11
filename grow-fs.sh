#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then echo "Please run as root"; exit 1; fi

# --- Auto-detect disk and VG ---
DISK=$(lsblk -ndo pkname /dev/mapper/$(lvs --noheadings -o lv_path debian-vg/root 2>/dev/null | tr -d ' /' | head -1) 2>/dev/null || echo "sda")
DISK="/dev/${DISK}"
VG=$(vgs --noheadings -o vg_name | xargs)

echo "--- LVM Disk Expander ---"
echo "Disk: $DISK | VG: $VG"
echo ""

# --- Grow partition table ---
# Partition 2 is the extended container — failure here is expected/ok
growpart ${DISK} 2 2>/dev/null && echo "Extended partition grown" || echo "Extended partition: no change (ok)"
growpart ${DISK} 5 2>/dev/null && echo "LVM partition grown" || echo "LVM partition: no change (ok)"

# --- Resize PV ---
pvresize ${DISK}5

# --- Show free space ---
FREE_MB=$(vgs $VG --units m --noheadings -o vg_free | tr -d ' m' | cut -d. -f1)
FREE_GB=$(echo "scale=2; $FREE_MB / 1024" | bc)
echo ""
echo "Available free space: ${FREE_GB} GB"
echo ""

# --- Show current LV sizes ---
echo "Current LV sizes:"
lvs $VG -o lv_name,lv_size --noheadings | awk '{printf "  %-10s %s\n", $1, $2}'
echo ""

# --- Ask for allocations ---
declare -A ALLOCS
TOTAL_REQUESTED=0

for LV in root var home tmp; do
    if lvs ${VG}/${LV} &>/dev/null; then
        read -p "Add to /${LV} (GB, or 0 to skip): " ADD
        ADD=${ADD:-0}
        if [[ "$ADD" =~ ^[0-9]+$ ]] && [ "$ADD" -gt 0 ]; then
            ALLOCS[$LV]=$ADD
            TOTAL_REQUESTED=$((TOTAL_REQUESTED + ADD))
        fi
    fi
done

# --- Validate total doesn't exceed free space ---
FREE_GB_INT=$(echo "$FREE_GB" | cut -d. -f1)
if [ "$TOTAL_REQUESTED" -gt "$FREE_GB_INT" ]; then
    echo ""
    echo "ERROR: Requested ${TOTAL_REQUESTED}GB but only ${FREE_GB}GB available."
    exit 1
fi

if [ "$TOTAL_REQUESTED" -eq 0 ]; then
    echo "Nothing to do."
    exit 0
fi

# --- Apply ---
echo ""
for LV in "${!ALLOCS[@]}"; do
    GB=${ALLOCS[$LV]}
    echo "Extending /${LV} by +${GB}G..."
    lvextend -L +"${GB}"G /dev/${VG}/${LV} -r
done

echo ""
echo "--- Done ---"
df -h | grep -E "Filesystem|mapper"