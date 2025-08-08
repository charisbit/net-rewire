#!/usr/bin/env bash
set -euo pipefail

# Net-Rewire Ubuntu VPN Forwarder Setup Script
# This script configures IP forwarding and iptables rules for TCP port 25 forwarding

echo "Setting up Net-Rewire VPN forwarder..."

# Configuration
PUB_IF="eth0"
VPN_IF="tun0"
TUNNEL_NET="10.8.0.0/24"

# Enable IP forwarding
echo "Enabling IP forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-net-rewire.conf
sudo sysctl --system

# Create tun0 interface if it doesn't exist
if ! ip link show "$VPN_IF" &>/dev/null; then
    echo "Creating $VPN_IF interface..."
    sudo ip tuntap add dev "$VPN_IF" mode tun
    sudo ip addr add 10.8.0.1/24 dev "$VPN_IF"
    sudo ip link set "$VPN_IF" up
fi

# Configure iptables rules for TCP port 25 forwarding
echo "Configuring iptables rules..."

# Clear existing rules for our setup (optional - be careful in production)
# sudo iptables -F FORWARD
# sudo iptables -t nat -F POSTROUTING

# Allow forwarding from VPN to public interface for TCP port 25
sudo iptables -A FORWARD -i "$VPN_IF" -o "$PUB_IF" -p tcp --dport 25 -j ACCEPT

# Allow established/related connections back through VPN
sudo iptables -A FORWARD -i "$PUB_IF" -o "$VPN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT

# NAT outgoing TCP port 25 traffic (MASQUERADE)
sudo iptables -t nat -A POSTROUTING -o "$PUB_IF" -p tcp --dport 25 -j MASQUERADE

# Additional security: drop other forwarded traffic from VPN (optional)
# sudo iptables -A FORWARD -i "$VPN_IF" -o "$PUB_IF" -j DROP

echo "Installing iptables-persistent..."
sudo apt-get update
sudo apt-get install -y iptables-persistent

echo "Saving iptables rules..."
sudo netfilter-persistent save

echo "Setup completed!"
echo ""
echo "Current configuration:"
echo "- IP forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"
echo "- VPN interface: $VPN_IF (10.8.0.1/24)"
echo "- Public interface: $PUB_IF"
echo "- Forwarding TCP port 25 traffic from $VPN_IF to $PUB_IF"
echo ""
echo "To verify rules:"
echo "  sudo iptables -L FORWARD -n -v"
echo "  sudo iptables -t nat -L POSTROUTING -n -v"
echo ""
echo "To monitor traffic:"
echo "  sudo tcpdump -ni $PUB_IF tcp port 25"
echo "  sudo tcpdump -ni $VPN_IF"