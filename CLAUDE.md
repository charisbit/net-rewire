# Net-Rewire — Design spec for Claude Code

**Goal:** implement a macOS Network Extension (`NEPacketTunnelProvider`) in Objective-C that captures *outbound* TCP port **25** traffic on the host, sends those packets through a VPN tunnel to an Ubuntu server, and makes the Ubuntu server forward them to the public Internet while preserving transparent behavior for the client (i.e., replies reach the client). The doc below is a complete engineering spec an agent can follow and implement end-to-end (macOS + Ubuntu + packaging + tests).

---

## 1. High-level architecture (summary)

* **macOS side**

  * App bundle contains a Network Extension of type `Packet Tunnel` (`NEPacketTunnelProvider`) implemented in Objective-C.
  * The NE provider captures packets at the IP packet level via the `packetFlow` API (`readPackets` / `writePackets`).
  * The provider inspects each packet; only packets whose *destination TCP port == 25* are forwarded into the tunnel. Non-SMTP traffic is left to the normal host stack (not tunneled).
  * Packets sent into tunnel use a point-to-point utun-like interface (created for the extension). The provider writes raw IP packets into the `packetFlow`.
  * For performance/robustness, heavy packet parsing/rewriting (if any) can be implemented in C and called from Objective-C.

* **Ubuntu side (VPN server / forwarder)**

  * The server receives IP packets from the macOS tunnel on `tun0` (or equivalent).
  * Ubuntu enables IP forwarding and applies `iptables` rules:

    * Accept forwarded TCP:25 from VPN peer.
    * NAT (SNAT or MASQUERADE) outgoing packets out `eth0` so replies can be routed back.
  * Optionally, log or rate-limit SMTP flows.

* **Key behaviors**

  * macOS decides based on L4 port (25) which flows to send via tunnel.
  * Ubuntu NATs the source to its public IP (or VPN public address) so external SMTP servers reply correctly.
  * The provider preserves original 4-tuple so the application on macOS sees the connection as normal (transparency depends on NAT behavior on Ubuntu; client perceives successful connection).

---

## 2. Deliverables for Claude Code agent

1. Xcode project skeleton (Objective-C) with:

   * containing App target and Network Extension target (`Packet Tunnel`).
   * entitlements and `Info.plist` entries ready for NE.
2. `PacketTunnelProvider.m` (Objective-C) implementing:

   * `startTunnelWithOptions:completionHandler:`
   * `stopTunnelWithReason:completionHandler:`
   * `readPackets` loop, packet classification by L4 port 25, forwarding to `packetFlow`.
   * writePackets path for injecting packets back to host when needed.
   * integration hooks into a C library for packet parsing (optional).
   * logging and metrics.
3. Minimal C library (`pktparse.c/h`) with:

   * functions to parse IP/TCP headers and extract ports, return offsets.
   * optional fast checksum recalculation helpers if rewriting needed.
4. Packaging and entitlements guidance:

   * `com.apple.developer.networking.networkextension` entitlement values for `packet-tunnel`.
   * provisioning profile notes (requires developer account to sign).
5. Ubuntu server configuration scripts:

   * enable IP forwarding
   * iptables commands to accept & masquerade TCP:25 from VPN peer
   * persistence steps (`netfilter-persistent` or systemd scripts)
6. Test plan and commands (tcpdump, `nc`, `iptables -L -n -v`, `pfctl` checks if relevant).
7. Logging, metrics, failure modes and recommended mitigation.
8. CI/CD notes: building with `clang`/Objective-C, code signing step is manual on macOS; unit tests for packet parser C code.

---

## 3. File layout (recommended)

```
net-rewire/
├─ macos/
│  ├─ NetRewireApp/                 # macOS app project (Xcode)
│  └─ NetRewirePacketTunnel/        # Network Extension target
│     ├─ PacketTunnelProvider.h
│     ├─ PacketTunnelProvider.m
│     ├─ pktparse.c
│     ├─ pktparse.h
│     ├─ Info.plist (extension)
│     └─ Entitlements.entitlements
├─ ubuntu/
│  ├─ setup-vpn-forward.sh
│  └─ persist-iptables.sh
├─ docs/
│  └─ design.md  # this document
└─ Makefile (for building C helpers)
```

---

## 4. macOS Network Extension — detailed design

### 4.1 Extension responsibilities

* Create tunnel network settings (assign `10.8.0.33/24` or chosen address).
* Only tunnel packets destined to TCP port 25.
* For tunneled packets:

  * write the raw IP packet to `self.packetFlow` (`[self.packetFlow writePackets:withProtocols:]`).
* For packets coming back from the tunnel (i.e., packets that Ubuntu forwards back), read them from `packetFlow` and inject them into the host stack by writing to `packetFlow` (depending on whether provider opened both sides — see Apple doc). Practically: We will use `packetFlow` only as readPackets callback to receive (for some modes), and use the extension’s network stack to forward.
* Maintain NAT/conntrack correlation is handled by Ubuntu. macOS should not SNAT packets before sending into tunnel (send original src 10.8.0.33), so Ubuntu can SNAT.

> Note: `NEPacketTunnelProvider` basically gives a user-space IP network path: you `readPackets` to get outbound packets that would otherwise go out the host, and `writePackets` to inject packets into the host. The provider writes outbound packets into the underlying tunnel to reach the server; the server must forward them.

### 4.2 `PacketTunnelProvider` key pseudocode (Objective-C)

```objective-c
// PacketTunnelProvider.h
#import <NetworkExtension/NetworkExtension.h>

@interface PacketTunnelProvider : NEPacketTunnelProvider
@end
```

```objective-c
// PacketTunnelProvider.m
#import "PacketTunnelProvider.h"
#import "pktparse.h" // C helpers

@implementation PacketTunnelProvider {
    BOOL _running;
}

- (void)startTunnelWithOptions:(NSDictionary *)options completionHandler:(void (^)(NSError *))completionHandler {
    // 1. Prepare network settings (local IP on tunnel)
    NEPacketTunnelNetworkSettings *settings =
      [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:@"10.8.0.1"]; // remote = server
    NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc] initWithAddresses:@[@"10.8.0.33"] subnetMasks:@[@"255.255.255.0"]];
    // We do NOT add defaultRoute here, because we only intercept port 25 flows.
    // Add a specific included route for nothing (we rely on packetFlow capture)
    ipv4.includedRoutes = @[]; // Leave includedRoutes empty so default routing remains for other traffic
    settings.IPv4Settings = ipv4;
    settings.MTU = @1400;

    [self setTunnelNetworkSettings:settings completionHandler:^(NSError *error) {
        if (error) { completionHandler(error); return; }

        _running = YES;
        [self startPacketCaptureLoop];
        completionHandler(nil);
    }];
}

- (void)startPacketCaptureLoop {
    __weak typeof(self) weakSelf = self;
    [self.packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets, NSArray<NSNumber *> *protocols) {
        for (NSData *pkt in packets) {
            const uint8_t *bytes = (const uint8_t *)pkt.bytes;
            size_t len = pkt.length;
            // parse ip header
            struct pkt_info info;
            if (pkt_parse(bytes, len, &info) && info.is_tcp) {
                if (ntohs(info.tcp_dst) == 25) {
                    // send to tunnel (this writes into the virtual interface)
                    [weakSelf.packetFlow writePackets:@[pkt] withProtocols:protocols];
                    continue;
                }
            }
            // not port25: write packet back to host stack -> drop or let OS handle?
            // Because readPackets returns packets that OS intended to send but were intercepted,
            // if we do nothing the OS packet is dropped. To avoid dropping non-25 flows,
            // do NOT request to capture them in the first place. (See 'capture mode' further below.)
        }
        // loop
        if (weakSelf->_running) [weakSelf startPacketCaptureLoop];
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    _running = NO;
    completionHandler();
}

@end
```

**Important notes and choices:**

* **How to capture only port 25 flows?**

  * `NEPacketTunnelProvider` can be configured to capture *all* traffic or configured with `includeRoutes` / `excludeRoutes` to control what traffic is routed to the tunnel. There is no built-in "capture only TCP:25" option. Therefore two approaches:

    1. **Capture everything** and filter inside `readPackets`, but then you must re-inject non-25 packets into host stack. Re-injecting non-25 into host is complicated and error prone.
    2. **Prefer**: Do not set a default route through the tunnel. Instead configure system routing so that only traffic to addresses that should go through the tunnel are routed there. But L3 routing cannot match port. So we must use `NEPacketTunnelProvider` packetFlow capture *mode*, which can be configured in `NEPacketTunnelNetworkSettings` to capture all traffic, then implement re-inject. This is feasible but careful: re-injecting requires `writePackets` to the `packetFlow` *with modified packets or with appropriate protocols* — practically it's simpler to capture everything and forward only port 25, and for non-25, re-write them back to the interface by calling `self.packetFlow writePackets:...` with original packet (or use `NEFilterPacketProvider` variant).
  * **Recommended approach**: use `NEPacketTunnelProvider` and set the system routing so that the system's routing still sends non-tunneled traffic out normal default; configure the extension to *only intercept flows by using a `perApp` or `perRoute` rule if possible*. In many real deployments, you configure the VPN so that it does **not** become the default route, and the extension captures only selected addresses; since we want port-based selection, the reliable way is to capture all traffic and handle non-25 by writing them back, or use `NEFilterPacketProvider` to filter and not capture—NEFilter allows allow/drop decisions without full tunnel semantics.
  * **For this project**: **capture all outbound packets** in `readPackets`, filter by port 25 and write those to a UDP/TCP socket to the Ubuntu endpoint or writePackets to the packetFlow (depending on tunnel implementation). For non-25, just `writePackets` back to `packetFlow` so OS continues as if nothing happened (this may need careful ordering).

* **Packet injection model**: when using a real VPN tunnel (sending out over TLS/UDP to the server), you normally encapsulate the original IP packet in your transport (e.g., use an authenticated UDP/TCP to server) rather than relying on packetFlow alone. Implementation will:

  * upon intercepting a port-25 packet, send it via a reliable tunnel socket to the Ubuntu server; the Ubuntu server decapsulates, obtains the raw IP packet, and forwards it via `eth0` after NAT.
  * For replies, Ubuntu will capture the reply packets and encapsulate back to the macOS provider, which calls `writePackets` to inject into the host stack.

So you need a **simple encapsulation protocol** (e.g., prepend 4-byte length and send raw IP bytes over a TLS socket). Further details below.

### 4.3 Encapsulation & transport between macOS <-> Ubuntu

* Use a secure TCP/TLS connection (or simple TLS) for reliability. Minimal protocol:

  * Client (macOS) opens TLS socket to server: `server:port` (e.g., 10.8.0.34:12345).
  * Each frame = 4-byte big-endian length + raw IP packet bytes.
  * Server reads a frame, obtains raw IP packet, forwards to network (via raw socket or `tun` interface on server).
  * Server sends back frames for returning packets.

**Why encapsulate?** `NEPacketTunnelProvider` does not automatically create an L2 path to the server; provider must send tunneled data over a user socket. Encapsulation is the standard design.

### 4.4 Packet parser C helper (pktparse.h / .c)

* `pkt_parse(const uint8_t *pkt, size_t len, struct pkt_info *out)`:

  * Validate IPv4 header length and version.
  * Fill `out->is_tcp`, `out->ip_src`, `out->ip_dst`, `out->tcp_src`, `out->tcp_dst`, offsets.
* Keep minimal footprint; no memory allocation on hot path.

---

## 5. Ubuntu server — detailed configuration

### 5.1 Prereqs

* Ubuntu 20.04+ (example).
* `iptables` (or `nftables`), `tcpdump`, `net-tools`.
* Open port for encapsulation server (e.g., `12345`), e.g., simple TCP/TLS server program.
* `tun` device or server process that receives encapsulated raw IP packets and injects them to kernel for forwarding (or server uses raw sockets to send directly).

### 5.2 Steps

1. **Enable IP forwarding**

```bash
sudo sysctl -w net.ipv4.ip_forward=1
# persist
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.d/99-sysctl.conf
sudo sysctl --system
```

2. **iptables rules (accept & NAT)**

Assume:

* VPN peer interface from macOS is `tun0` (server side).
* Public interface is `eth0`.

```bash
# Accept forwarding from VPN to eth0 for TCP:25 (established/related back)
sudo iptables -A FORWARD -i tun0 -o eth0 -p tcp --dport 25 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o tun0 -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow forwarding from server process to internet
sudo iptables -A FORWARD -i tun0 -o eth0 -j ACCEPT

# NAT outgoing to public IP (MASQUERADE):
sudo iptables -t nat -A POSTROUTING -o eth0 -p tcp --dport 25 -j MASQUERADE
```

**Note:** MASQUERADE matches packets leaving `eth0` destined to port 25; you can also use `-s 10.8.0.33` if you want to restrict.

3. **Persist iptables**

```bash
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

4. **Encapsulation server**

* Implement (or run) a simple server that:

  * Listens on TCP/TLS port (e.g., 12345).
  * Accepts incoming connections from macOS app (mutual auth optional).
  * For each received frame (4B length + packet bytes), it:

    * Option A: writes the raw IP packet to `tun0` device (requires creating `tun0` and setting ip).
    * Option B: sends raw packets via a raw socket (e.g., `sendto()` with `AF_INET` and proper IP header), but this requires privileges and careful handling.
  * For returning packets: capture replies from kernel (either via `tun0` readback or via `pcap`/`raw socket` capturing), encapsulate and send back to macOS client.

**Recommended:** create a `tun0` per client (or reuse single `tun0` and use src IP mapping). Simpler approach: the macOS side builds an overlay by writing original IP packets into TLS; the server decapsulates and uses `iptables` DNAT/SNAT rules to forward.

### 5.3 Simple server concept

* Use `tun` device and `tun` reads/writes: create `tun0` with IP `10.8.0.1/24`. When server receives encapsulated packet from macOS, write directly to `tun0`. Kernel will see it as local routed packet and apply routing rules (forward to eth0). Replies that kernel receives destined to 10.8.0.33 will be routed to `tun0`, your server reads from tun0, encapsulates, and sends to the macOS client.

Server pseudo steps:

1. create `tun0` and assign `10.8.0.1/24`.
2. enable forwarding & iptables MASQUERADE for eth0.
3. accept TLS connections from macOS client(s).
4. For each client:

   * read frames from socket => write to `tun0`.
   * read frames from `tun0` => write to socket.

This is analogous to a simple user-space VPN server.

---

## 6. Security and deployment notes

* **Encryption:** Use TLS for encapsulation to prevent sniffing. Use mutual TLS for authentication if possible.
* **Authorization:** Validate incoming client certificate or token from macOS app before accepting packets.
* **Firewall:** On Ubuntu, restrict TCP encapsulation port to known client IP(s)/certs.
* **Rate limiting:** Prevent abusable open relaying by rate limiting or requiring upstream relay authorization.
* **Logging:** Log per-connection events and NAT events, but avoid logging packet bodies (privacy).

---

## 7. Test plan (practical commands)

### 7.1 On Ubuntu

* Verify tun and forwarding:

```bash
ip addr show tun0
sysctl net.ipv4.ip_forward
iptables -t nat -L -n -v
iptables -L FORWARD -n -v
```

* Start tcpdump to watch outgoing SMTP packets:

```bash
sudo tcpdump -n -i eth0 tcp port 25
```

### 7.2 On macOS (development machine)

* In the app, start the extension and tail logs.
* Run:

```bash
nc -v -w 5 smtp.dtype.info 25
```

* On Ubuntu, check `tcpdump` to see SYN packets from server `eth0`.
* Confirm reply frames travel back through the tunnel and that `nc` on macOS receives SMTP banner.

### 7.3 End-to-end verification

1. macOS: `nc -v smtp.example.com 25` should show `220 ...` banner.
2. Ubuntu `tcpdump -ni eth0 tcp port 25` should show the outward packets.
3. `iptables -t nat -L -n -v` should show counters incremented for MASQUERADE rule.

---

## 8. Failure modes and mitigations

* **No response for SYN:** likely Ubuntu didn't NAT or forwarding disabled. Check `sysctl net.ipv4.ip_forward`, `iptables FORWARD`, and `POSTROUTING`.
* **Packets stuck on macOS:** provider must write replies correctly; check provider logs and `packetFlow` usage.
* **Dropped non-25 traffic:** if capturing everything and forgetting to re-inject, other packets will be dropped. Ensure non-25 are re-written to host or avoid capturing them (preferred if possible).
* **Performance issues:** reading/writing packets in userland has overhead. Keep `pktparse` in C, avoid copying buffers; consider batching of packets when writing.
* **Security risk (open relay):** ensure server restricts client connections and prevents unauthorized relay.

---

## 9. Implementation details & code snippets

### 9.1 Minimal C packet parser (`pktparse.h`)

```c
// pktparse.h
#ifndef PKTPARSE_H
#define PKTPARSE_H
#include <stdint.h>
#include <arpa/inet.h>

struct pkt_info {
    int is_ipv4;
    int is_tcp;
    uint32_t ip_src;
    uint32_t ip_dst;
    uint16_t tcp_src;
    uint16_t tcp_dst;
    int ip_header_len;
    int tcp_header_len;
};

int pkt_parse(const uint8_t *buf, size_t len, struct pkt_info *info);

#endif
```

### 9.2 Minimal `pktparse.c` (safely parse IPv4/TCP)

```c
// pktparse.c
#include "pktparse.h"
#include <string.h>
#include <netinet/ip.h>
#include <netinet/tcp.h>

int pkt_parse(const uint8_t *buf, size_t len, struct pkt_info *info) {
    memset(info, 0, sizeof(*info));
    if (len < sizeof(struct ip)) return 0;
    struct ip *iph = (struct ip *)buf;
    if ((iph->ip_v) != 4) return 0;
    int ihl = iph->ip_hl * 4;
    if (len < ihl + sizeof(struct tcphdr)) return 0;
    info->is_ipv4 = 1;
    info->ip_header_len = ihl;
    info->ip_src = iph->ip_src.s_addr;
    info->ip_dst = iph->ip_dst.s_addr;
    if (iph->ip_p != IPPROTO_TCP) return 1;
    struct tcphdr *tcph = (struct tcphdr *)(buf + ihl);
    info->is_tcp = 1;
    info->tcp_header_len = tcph->th_off * 4;
    info->tcp_src = tcph->th_sport;
    info->tcp_dst = tcph->th_dport;
    return 1;
}
```

### 9.3 Encapsulation framing (Objective-C pseudocode)

* When sending packet to server:

  * `uint32_t len = htonl(packet.length); write(fd, &len, 4); write(fd, packet.bytes, packet.length);`

* When receiving:

  * read 4 bytes → `len`, then read `len` bytes → raw packet → `writePackets` into `packetFlow` on macOS side.

---

## 10. Entitlements & provisioning (macOS)

* Add capability: **Network Extensions** in Xcode for the app group.
* `Info.plist` (extension) must include NE extension point:

  * `NSExtension` → `NSExtensionAttributes` — specify `nets`? (Xcode template will do this).
* Entitlements (example `NetRewirePacketTunnel.entitlements`):

```xml
<plist>
  <dict>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
      <string>packet-tunnel</string>
    </array>
    <key>com.apple.developer.networking.vpn.api</key>
    <true/>
  </dict>
</plist>
```

* **Code signing / provisioning:** building and running Network Extension requires a signed provisioning profile with NE capability granted; manual steps are outside scope but must be followed by developer with Apple Developer Program.

---

## 11. Build & test checklist for Claude Code agent

1. Create Xcode project with app and extension targets.
2. Hook in C files into extension target and configure bridging headers if needed.
3. Implement `PacketTunnelProvider.m` per pseudocode; implement TLS socket to server and encapsulation.
4. Implement simple server in Ubuntu (C or Python) that creates `tun0`, reads frames from TCP socket and writes to `tun0`, and reads `tun0` to send back frames.
5. Configure Ubuntu iptables for forwarding & NAT.
6. Run extension in debug mode (Xcode) and test `nc -v smtp.example.com 25`.
7. Use `tcpdump` on server `eth0` and `tun0` to verify.
8. Add logging and metrics, tune performance.

---

## 12. Testing & diagnostics commands (summary)

* On macOS (developer machine):

  * `log stream --predicate 'subsystem == "com.apple.NetworkExtension"'` (for NE logs)
  * `sudo tcpdump -nvi utunX tcp port 25`
  * `nc -v -w 5 smtp.example.com 25`

* On Ubuntu:

  * `sudo iptables -L -n -v`
  * `sudo iptables -t nat -L -n -v`
  * `sudo tcpdump -nvi eth0 tcp port 25`
  * `sudo tcpdump -nvi tun0`

---

## 13. Metrics & logging

* Log counters:

  * Packets inspected, port25 packets sent to tunnel, packets returned, tunnel errors.
* Log connection events to remote server (connected/disconnected/retries).
* Track dropped packets and reasons.

---

## 14. Performance considerations

* Batch multiple packets in single write to TLS socket to reduce syscall overhead.
* Use C parser for hot path.
* Avoid copying buffers unnecessarily. Use `NSData` with underlying bytes when possible.

---

## 15. Implementation timeline (suggested sprints for agent)

1. **Sprint 0 — skeleton**

   * Create Xcode target scaffolding, entitlements, and build pipeline for extension.
2. **Sprint 1 — C parser + encapsulation**

   * Implement pktparse.c, test with unit tests (simulate packet bytes).
3. **Sprint 2 — Ubuntu server**

   * Small tun server that reads/writes packets, test with `socat`/`nc`.
4. **Sprint 3 — NE provider core**

   * Read packets and encapsulate, send to server; implement writeback path.
5. **Sprint 4 — iptables & NAT**

   * Add iptables on Ubuntu, run end-to-end tests.
6. **Sprint 5 — security & polishing**

   * Add TLS, certs, logging, packaging, docs.

---

## 16. Example Ubuntu `setup-vpn-forward.sh` (starter)

```bash
#!/usr/bin/env bash
set -euo pipefail

# enable forwarding
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-net-rewire.conf
sudo sysctl --system

# interfaces (adjust accordingly)
PUB_IF=eth0
VPN_IF=tun0

# firewall: allow forward and masquerade (SMTP)
sudo iptables -A FORWARD -i "$VPN_IF" -o "$PUB_IF" -p tcp --dport 25 -j ACCEPT
sudo iptables -A FORWARD -i "$PUB_IF" -o "$VPN_IF" -m state --state ESTABLISHED,RELATED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -o "$PUB_IF" -p tcp --dport 25 -j MASQUERADE

# persist
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

---

## 17. Security checklist

* Use TLS for client↔server tunnel.
* Enforce client authentication (certs or tokens).
* Apply strict iptables rules to only accept encapsulation port from expected peers.
* Monitor for abuse (open relay behavior).

---

## 18. Deliver final artifacts (for Claude Code)

1. Xcode project skeleton + extension code (Objective-C).
2. `pktparse.c/h` + unit tests.
3. Example server program for Ubuntu (preferably in C or Python) with `tun` usage.
4. `ubuntu/setup-vpn-forward.sh` and persistence steps.
5. README with exact run & debug commands and expected outputs.
6. Shell scripts for local instrumentation (tcpdump, pfctl commands).
7. Optional: packaged `.mobileconfig` or script to install extension (manual signing remains required).

---

## 19. Example commit message (for initial commit)

```
feat: add NEPacketTunnelProvider skeleton (Objective-C) + pktparse C helper and Ubuntu forwarder scripts

- Xcode project scaffold for macOS app + Packet Tunnel Network Extension (Objective-C)
- PacketTunnelProvider core loop and encapsulation plan
- C packet parser (pktparse.c/h) for fast L4 inspection
- Ubuntu server setup script: enable IP forwarding and iptables MASQUERADE for TCP:25
- README + test plan + diagnostics
```

---

## 20. Final notes / guidance to the agent

* Prefer Objective-C for NE provider implementation since it integrates naturally with C helper functions.
* Implement a simple, robust, length-prefixed packet encapsulation protocol over TLS for the tunnel.
* On macOS, avoid dropping non-25 traffic: either do not capture it in the first place (optimal) or ensure proper reinjection.
* Provide unit tests for `pktparse` (feed example IPv4/TCP packets and test port extraction).
* Include CI steps to compile the C helper library; extension building/signing can be done locally by developer with Apple account.
