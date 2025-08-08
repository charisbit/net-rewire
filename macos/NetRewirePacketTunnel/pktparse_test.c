//
//  pktparse_test.c
//  NetRewirePacketTunnel
//
//  Created by Claude Code
//

#include "pktparse.h"
#include <stdio.h>
#include <assert.h>
#include <string.h>

// Sample IPv4/TCP packet (SYN packet to port 25)
static const uint8_t test_packet[] = {
    // IP header
    0x45, 0x00, 0x00, 0x3c, 0x00, 0x01, 0x00, 0x00, 0x40, 0x06, 0x00, 0x00,
    0xc0, 0xa8, 0x01, 0x01,  // src: 192.168.1.1
    0xc0, 0xa8, 0x01, 0x02,  // dst: 192.168.1.2
    // TCP header
    0x04, 0xd2, 0x00, 0x19,  // src: 1234, dst: 25
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x50, 0x02, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00
};

void test_valid_tcp_packet() {
    struct pkt_info info;
    int result = pkt_parse(test_packet, sizeof(test_packet), &info);

    assert(result == 1);
    assert(info.is_ipv4 == 1);
    assert(info.is_tcp == 1);
    assert(info.ip_header_len == 20);
    assert(info.tcp_header_len == 20);
    assert(info.tcp_src == htons(1234));
    assert(info.tcp_dst == htons(25));

    printf("✓ Valid TCP packet test passed\n");
}

void test_short_packet() {
    struct pkt_info info;
    int result = pkt_parse(test_packet, 10, &info);

    assert(result == 0);
    printf("✓ Short packet test passed\n");
}

void test_non_tcp_packet() {
    uint8_t udp_packet[] = {
        0x45, 0x00, 0x00, 0x3c, 0x00, 0x01, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00, // UDP protocol
        0xc0, 0xa8, 0x01, 0x01, 0xc0, 0xa8, 0x01, 0x02,
        // Add some UDP header data to make packet long enough
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    };

    struct pkt_info info;
    int result = pkt_parse(udp_packet, sizeof(udp_packet), &info);

    assert(result == 1);
    assert(info.is_ipv4 == 1);
    assert(info.is_tcp == 0);

    printf("✓ Non-TCP packet test passed\n");
}

int main() {
    printf("Running pktparse unit tests...\n");

    test_valid_tcp_packet();
    test_short_packet();
    test_non_tcp_packet();

    printf("All tests passed! ✅\n");
    return 0;
}