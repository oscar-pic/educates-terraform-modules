#!/bin/bash
# Description: Checks for /var/run/reboot-required and reboots the node safely.
# Usage: ./reboot_if_required.sh <ssh_key_path> <ssh_user> <ip_address>

SSH_KEY=$1
SSH_USER=$2
IP_ADDR=$3

echo "------------------------------------------------------------"
echo "🔍 Checking for pending reboot on ${IP_ADDR}..."

# Check for the reboot flag file on the remote Ubuntu node
REBOOT_NEEDED=$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${IP_ADDR}" "[ -f /var/run/reboot-required ] && echo 'yes' || echo 'no'")

if [ "$REBOOT_NEEDED" == "yes" ]; then
    echo "⚠️  System restart IS required. Initiating reboot now..."
    
    # Trigger reboot. SSH will disconnect; we use '|| true' to prevent script failure on disconnect.
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${IP_ADDR}" "sudo shutdown -r now" || true
    
    echo "⏳ Waiting for ${IP_ADDR} to come back online..."
    sleep 15
    
    # Wait until the SSH port (22) is reachable again using netcat (nc)
    until nc -zv -w 5 "${IP_ADDR}" 22 2>/dev/null; do
        echo "   ...still waiting for ${IP_ADDR} to respond..."
        sleep 5
    done
    
    echo "✅ Node ${IP_ADDR} is back online and fully updated!"
else
    echo "    No reboot required for node ${IP_ADDR}. Skipping."
fi
echo "------------------------------------------------------------"