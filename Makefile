# Net-Rewire Makefile
# Build system for C components

CC = gcc
CFLAGS = -Wall -Wextra -O2 -std=c99
LDFLAGS =

# Targets
TARGETS = ubuntu/tunnel_server macos/NetRewirePacketTunnel/pktparse_test

.PHONY: all clean test

all: $(TARGETS)

# Ubuntu tunnel server
ubuntu/tunnel_server: ubuntu/tunnel_server.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) -lpthread

# Packet parser test
macos/NetRewirePacketTunnel/pktparse_test: macos/NetRewirePacketTunnel/pktparse_test.c macos/NetRewirePacketTunnel/pktparse.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

# Test the packet parser
test: macos/NetRewirePacketTunnel/pktparse_test
	./macos/NetRewirePacketTunnel/pktparse_test

# Clean build artifacts
clean:
	rm -f $(TARGETS)
	rm -f *.o

# Install Ubuntu server dependencies
ubuntu-deps:
	sudo apt-get update
	sudo apt-get install -y build-essential net-tools tcpdump iptables-persistent

# Setup Ubuntu server
ubuntu-setup: ubuntu-deps ubuntu/tunnel_server
	sudo chmod +x ubuntu/setup-vpn-forward.sh
	sudo ./ubuntu/setup-vpn-forward.sh

# Run Ubuntu server
ubuntu-run: ubuntu/tunnel_server
	sudo ./ubuntu/tunnel_server

help:
	@echo "Net-Rewire Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all          - Build all components"
	@echo "  test         - Run packet parser tests"
	@echo "  ubuntu-deps  - Install Ubuntu dependencies"
	@echo "  ubuntu-setup - Setup Ubuntu server"
	@echo "  ubuntu-run   - Run Ubuntu tunnel server"
	@echo "  clean        - Clean build artifacts"
	@echo ""
	@echo "For macOS development:"
	@echo "  - Open macos/NetRewireApp.xcodeproj in Xcode"
	@echo "  - Build and run the Network Extension target"