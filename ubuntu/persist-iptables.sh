#!/usr/bin/env bash
set -euo pipefail

# Net-Rewire iptables persistence script
# This script ensures iptables rules are restored on system reboot

echo "Setting up iptables persistence for Net-Rewire..."

# Check if iptables-persistent is installed
if ! command -v netfilter-persistent &> /dev/null; then
    echo "Installing iptables-persistent..."
    sudo apt-get update
    sudo apt-get install -y iptables-persistent
fi

# Save current rules
echo "Saving current iptables rules..."
sudo netfilter-persistent save

# Create systemd service to ensure rules are applied at boot
cat << EOF | sudo tee /etc/systemd/system/net-rewire-iptables.service
[Unit]
Description=Net-Rewire iptables rules
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
sudo systemctl daemon-reload
sudo systemctl enable net-rewire-iptables.service

# Create a script to manually restore rules if needed
cat << 'EOF' | sudo tee /usr/local/bin/net-rewire-restore-rules
#!/bin/bash
# Net-Rewire iptables rules restore script

/sbin/iptables-restore /etc/iptables/rules.v4
echo "Net-Rewire iptables rules restored"
EOF

sudo chmod +x /usr/local/bin/net-rewire-restore-rules

echo "Persistence setup completed!"
echo ""
echo "Commands:"
echo "  sudo systemctl status net-rewire-iptables.service"
echo "  sudo net-rewire-restore-rules"
echo "  sudo netfilter-persistent save"