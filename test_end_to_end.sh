#!/usr/bin/env bash
set -euo pipefail

# Net-Rewire End-to-End Test Script
# This script helps validate the complete system

echo "=== Net-Rewire End-to-End Test ==="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test functions
function test_packet_parser() {
    echo -e "${YELLOW}Testing packet parser...${NC}"
    if make test > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Packet parser tests passed${NC}"
        return 0
    else
        echo -e "${RED}✗ Packet parser tests failed${NC}"
        return 1
    fi
}

function test_ubuntu_build() {
    echo -e "${YELLOW}Testing Ubuntu server build...${NC}"
    # Ubuntu server requires Linux headers, skip on macOS
    if [[ "$(uname)" == "Darwin" ]]; then
        echo -e "${YELLOW}⚠ Ubuntu server build skipped (requires Linux headers)${NC}"
        return 0
    elif make ubuntu/tunnel_server > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Ubuntu server builds successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Ubuntu server build failed${NC}"
        return 1
    fi
}

function test_configuration_scripts() {
    echo -e "${YELLOW}Testing configuration scripts...${NC}"

    # Test script syntax
    if bash -n ubuntu/setup-vpn-forward.sh && bash -n ubuntu/persist-iptables.sh; then
        echo -e "${GREEN}✓ Configuration scripts have valid syntax${NC}"
        return 0
    else
        echo -e "${RED}✗ Configuration scripts have syntax errors${NC}"
        return 1
    fi
}

function test_file_structure() {
    echo -e "${YELLOW}Checking project structure...${NC}"

    required_files=(
        "macos/NetRewireApp/NetRewireApp/AppDelegate.m"
        "macos/NetRewirePacketTunnel/PacketTunnelProvider.m"
        "macos/NetRewirePacketTunnel/pktparse.c"
        "macos/NetRewirePacketTunnel/pktparse.h"
        "ubuntu/tunnel_server.c"
        "ubuntu/setup-vpn-forward.sh"
        "Makefile"
        "README.md"
    )

    all_exist=true
    for file in "${required_files[@]}"; do
        if [[ -f "$file" ]]; then
            echo -e "  ${GREEN}✓ $file${NC}"
        else
            echo -e "  ${RED}✗ $file (missing)${NC}"
            all_exist=false
        fi
    done

    if $all_exist; then
        echo -e "${GREEN}✓ All required files present${NC}"
        return 0
    else
        echo -e "${RED}✗ Some required files are missing${NC}"
        return 1
    fi
}

function show_test_commands() {
    echo ""
    echo -e "${YELLOW}=== Manual Test Commands ===${NC}"
    echo ""
    echo "1. Build and test packet parser:"
    echo "   make test"
    echo ""
    echo "2. Setup Ubuntu server:"
    echo "   make ubuntu-setup"
    echo ""
    echo "3. Run Ubuntu tunnel server:"
    echo "   make ubuntu-run"
    echo ""
    echo "4. Test SMTP connection (on macOS):"
    echo "   nc -v smtp.gmail.com 25"
    echo ""
    echo "5. Monitor traffic (on Ubuntu):"
    echo "   sudo tcpdump -ni eth0 tcp port 25"
    echo "   sudo tcpdump -ni tun0"
    echo ""
    echo "6. Check iptables rules (on Ubuntu):"
    echo "   sudo iptables -L FORWARD -n -v"
    echo "   sudo iptables -t nat -L POSTROUTING -n -v"
    echo ""
    echo "7. View macOS VPN logs:"
    echo "   log stream --predicate 'subsystem == \"com.apple.NetworkExtension\"'"
}

# Run tests
all_passed=true

echo "Running automated tests..."
echo ""

test_packet_parser || all_passed=false
echo ""

test_ubuntu_build || all_passed=false
echo ""

test_configuration_scripts || all_passed=false
echo ""

test_file_structure || all_passed=false
echo ""

# Summary
if $all_passed; then
    echo -e "${GREEN}=== All automated tests passed! ===${NC}"
    echo ""
    echo "The project is ready for manual testing."
    echo "Follow the steps below to test the complete system:"
else
    echo -e "${RED}=== Some tests failed ===${NC}"
    echo ""
    echo "Please fix the issues above before proceeding."
fi

show_test_commands

echo ""
echo -e "${YELLOW}=== Next Steps ===${NC}"
echo "1. Setup Ubuntu server with: make ubuntu-setup"
echo "2. Run tunnel server with: make ubuntu-run"
echo "3. Open Xcode project: open macos/NetRewireApp.xcodeproj"
echo "4. Build and run the Network Extension"
echo "5. Test with: nc -v smtp.gmail.com 25"

if $all_passed; then
    exit 0
else
    exit 1
fi