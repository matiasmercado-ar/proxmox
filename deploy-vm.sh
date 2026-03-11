#!/bin/bash
# --- CONFIGURATION ---
TEMPLATE_ID=900
TARGET_STORAGE="local-zfs"
GATEWAY="192.168.100.1"
DNS_SERVERS="192.168.100.100,192.168.100.1"

# --- LIMITS ---
MAX_CPU=8
MAX_RAM=16
MAX_DISK=200

if [ "$EUID" -ne 0 ]; then echo "Please run as root"; exit 1; fi

echo "--- Proxmox ZFS Deployer ---"

read -p "VM Name (will become hostname): " VM_NAME
read -p "VM ID: " VM_ID
read -p "CPU Cores (Max $MAX_CPU): " VM_CORES
read -p "RAM in GB (Max $MAX_RAM): " VM_RAM_GB
read -p "Extra Disk Space GB (Max $MAX_DISK): " DISK_INC
SUGGESTED_IP="192.168.100.${VM_ID}"
read -p "Static IP [suggested: ${SUGGESTED_IP}] (Y/y to confirm, or type 192.168.100.x): " VM_IP_INPUT
if [[ "$VM_IP_INPUT" =~ ^[Yy]$ ]] || [[ -z "$VM_IP_INPUT" ]]; then
    VM_IP="$SUGGESTED_IP"
else
    VM_IP="$VM_IP_INPUT"
fi

# --- VALIDATION ---
if ! [[ "$VM_CORES" =~ ^[0-9]+$ ]] || [ "$VM_CORES" -gt "$MAX_CPU" ]; then
    echo "ERROR: CPU must be a number and max is $MAX_CPU cores."; exit 1
fi
if ! [[ "$VM_RAM_GB" =~ ^[0-9]+$ ]] || [ "$VM_RAM_GB" -gt "$MAX_RAM" ]; then
    echo "ERROR: RAM must be a number and max is ${MAX_RAM}GB."; exit 1
fi
if ! [[ "$DISK_INC" =~ ^[0-9]+$ ]] || [ "$DISK_INC" -gt "$MAX_DISK" ]; then
    echo "ERROR: Disk must be a number and max is ${MAX_DISK}GB."; exit 1
fi
if [[ ! "$VM_IP" =~ ^192\.168\.100\.[0-9]{1,3}$ ]]; then
    echo "ERROR: Only IPs in the 192.168.100.x range are permitted."; exit 1
fi
if qm status "$VM_ID" &>/dev/null; then
    echo "ERROR: VM ID $VM_ID already exists."; exit 1
fi

# --- EXECUTION ---
VM_RAM_MB=$((VM_RAM_GB * 1024))

echo "Cloning Template $TEMPLATE_ID → VM $VM_ID ($VM_NAME)..."
qm clone $TEMPLATE_ID $VM_ID --name "$VM_NAME" --full --storage $TARGET_STORAGE

echo "Configuring CPU / RAM..."
qm set $VM_ID --cores $VM_CORES --memory $VM_RAM_MB --agent enabled=1

echo "Resizing disk by +${DISK_INC}G..."
qm resize $VM_ID scsi0 +${DISK_INC}G

echo "Applying Cloud-Init: IP, gateway, DNS, hostname..."
qm set $VM_ID \
    --ipconfig0 ip=${VM_IP}/24,gw=${GATEWAY} \
    --nameserver "${DNS_SERVERS}" \
    --searchdomain "local" \
    --ciuser root

echo "Starting $VM_NAME..."
qm start $VM_ID

echo ""
echo "------------------------------------------------"
echo " Deployment Successful!"
echo " VM Name  : $VM_NAME"
echo " VM ID    : $VM_ID"
echo " IP       : $VM_IP/24"
echo " Gateway  : $GATEWAY"
echo " DNS      : $DNS_SERVERS"
echo "------------------------------------------------"
echo ""
echo "Wait ~30s for cloud-init, then:"
echo "  ssh root@$VM_IP"