//
//  pktparse.c
//  NetRewirePacketTunnel
//
//  Created by Claude Code
//

#include "pktparse.h"
#include <string.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>

int pkt_parse(const uint8_t *buf, size_t len, struct pkt_info *info) {
    memset(info, 0, sizeof(*info));

    // Check minimum length for IP header
    if (len < sizeof(struct ip)) {
        return 0;
    }

    struct ip *iph = (struct ip *)buf;

    // Check IP version
    if ((iph->ip_v) != 4) {
        return 0;
    }

    // Calculate IP header length
    int ihl = iph->ip_hl * 4;
    if (len < ihl) {
        return 0;
    }

    // Fill IP information
    info->is_ipv4 = 1;
    info->ip_header_len = ihl;
    info->ip_src = iph->ip_src.s_addr;
    info->ip_dst = iph->ip_dst.s_addr;

    // Check if TCP
    if (iph->ip_p != IPPROTO_TCP) {
        return 1; // Valid IP packet but not TCP
    }

    // For TCP, check if we have enough data for TCP header
    if (len < ihl + sizeof(struct tcphdr)) {
        return 1; // Valid IP packet but TCP header incomplete
    }

    // Parse TCP header
    struct tcphdr *tcph = (struct tcphdr *)(buf + ihl);
    info->is_tcp = 1;
    info->tcp_header_len = tcph->th_off * 4;
    info->tcp_src = tcph->th_sport;
    info->tcp_dst = tcph->th_dport;

    return 1;
}