//
//  PacketTunnelProvider.m
//  NetRewirePacketTunnel
//
//  Created by Claude Code
//

#import "PacketTunnelProvider.h"
#import "pktparse.h"
#import <NetworkExtension/NetworkExtension.h>
#import <Security/Security.h>

// Tunnel configuration
#define TUNNEL_SERVER_IP @"10.8.0.1"
#define TUNNEL_CLIENT_IP @"10.8.0.33"
#define TUNNEL_SERVER_PORT 12345
#define TUNNEL_SUBNET_MASK @"255.255.255.0"

@interface PacketTunnelProvider () {
    BOOL _running;
    int _tunnelSocket;
    dispatch_queue_t _packetQueue;
    NSMutableArray *_packetBuffer;
}

@property (strong) NSTimer *reconnectTimer;

@end

@implementation PacketTunnelProvider

- (void)startTunnelWithOptions:(NSDictionary *)options completionHandler:(void (^)(NSError *))completionHandler {
    NSLog(@"Starting Net-Rewire tunnel...");

    // Initialize packet processing queue
    _packetQueue = dispatch_queue_create("com.netrewire.packet_queue", DISPATCH_QUEUE_SERIAL);
    _packetBuffer = [NSMutableArray array];

    // Configure tunnel network settings
    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:TUNNEL_SERVER_IP];

    // Configure IPv4 settings
    NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc] initWithAddresses:@[TUNNEL_CLIENT_IP] subnetMasks:@[TUNNEL_SUBNET_MASK]];

    // Don't set default route - we only want to capture specific traffic
    ipv4.includedRoutes = @[];
    settings.IPv4Settings = ipv4;
    settings.MTU = @1400;

    // Apply network settings
    [self setTunnelNetworkSettings:settings completionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"Error setting tunnel network settings: %@", error);
            completionHandler(error);
            return;
        }

        // Start tunnel operations
        _running = YES;

        // Connect to tunnel server
        [self connectToTunnelServer];

        // Start packet processing loop
        [self startPacketCaptureLoop];

        NSLog(@"Tunnel started successfully");
        completionHandler(nil);
    }];
}

- (void)connectToTunnelServer {
    dispatch_async(_packetQueue, ^{
        [self setupTunnelSocket];
    });
}

- (void)setupTunnelSocket {
    // Create socket to tunnel server
    _tunnelSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (_tunnelSocket < 0) {
        NSLog(@"Error creating tunnel socket");
        return;
    }

    // Configure server address
    struct sockaddr_in serverAddr;
    memset(&serverAddr, 0, sizeof(serverAddr));
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_port = htons(TUNNEL_SERVER_PORT);
    inet_pton(AF_INET, [TUNNEL_SERVER_IP UTF8String], &serverAddr.sin_addr);

    // Connect to server
    int result = connect(_tunnelSocket, (struct sockaddr *)&serverAddr, sizeof(serverAddr));
    if (result < 0) {
        NSLog(@"Error connecting to tunnel server: %s", strerror(errno));
        close(_tunnelSocket);
        _tunnelSocket = -1;

        // Schedule reconnect
        [self scheduleReconnect];
        return;
    }

    NSLog(@"Connected to tunnel server");

    // Start receiving packets from server
    [self startReceivingFromServer];
}

- (void)scheduleReconnect {
    if (_reconnectTimer) {
        [_reconnectTimer invalidate];
    }

    _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                       target:self
                                                     selector:@selector(connectToTunnelServer)
                                                     userInfo:nil
                                                      repeats:NO];
}

- (void)startReceivingFromServer {
    dispatch_async(_packetQueue, ^{
        [self receiveLoop];
    });
}

- (void)receiveLoop {
    while (_running && _tunnelSocket >= 0) {
        // Read packet length (4 bytes)
        uint32_t packetLength = 0;
        ssize_t bytesRead = recv(_tunnelSocket, &packetLength, 4, 0);

        if (bytesRead <= 0) {
            NSLog(@"Connection to server lost");
            close(_tunnelSocket);
            _tunnelSocket = -1;
            [self scheduleReconnect];
            break;
        }

        // Convert network byte order to host byte order
        packetLength = ntohl(packetLength);

        if (packetLength > 65535 || packetLength == 0) {
            NSLog(@"Invalid packet length: %u", packetLength);
            continue;
        }

        // Read packet data
        NSMutableData *packetData = [NSMutableData dataWithLength:packetLength];
        bytesRead = recv(_tunnelSocket, [packetData mutableBytes], packetLength, 0);

        if (bytesRead <= 0) {
            NSLog(@"Error reading packet data");
            continue;
        }

        // Inject packet back to host stack
        [self.packetFlow writePackets:@[packetData] withProtocols:@[@(AF_INET)]];

        NSLog(@"Received packet from server, length: %zu", bytesRead);
    }
}

- (void)startPacketCaptureLoop {
    __weak typeof(self) weakSelf = self;

    [self.packetFlow readPacketsWithCompletionHandler:^(NSArray<NSData *> *packets, NSArray<NSNumber *> *protocols) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_running) {
            return;
        }

        [strongSelf processPackets:packets protocols:protocols];

        // Continue reading packets
        if (strongSelf->_running) {
            [strongSelf startPacketCaptureLoop];
        }
    }];
}

- (void)processPackets:(NSArray<NSData *> *)packets protocols:(NSArray<NSNumber *> *)protocols {
    for (NSUInteger i = 0; i < packets.count; i++) {
        NSData *packet = packets[i];

        // Parse packet using C helper
        struct pkt_info info;
        const uint8_t *bytes = (const uint8_t *)packet.bytes;
        size_t len = packet.length;

        if (pkt_parse(bytes, len, &info) && info.is_tcp) {
            // Check if destination port is 25 (SMTP)
            if (ntohs(info.tcp_dst) == 25) {
                NSLog(@"Forwarding TCP port 25 packet to tunnel");
                [self sendPacketToTunnel:packet];
            } else {
                // Non-SMTP traffic - write back to host stack
                [self.packetFlow writePackets:@[packet] withProtocols:@[protocols[i]]];
            }
        } else {
            // Non-TCP traffic - write back to host stack
            [self.packetFlow writePackets:@[packet] withProtocols:@[protocols[i]]];
        }
    }
}

- (void)sendPacketToTunnel:(NSData *)packet {
    if (_tunnelSocket < 0) {
        NSLog(@"Tunnel socket not connected, dropping packet");
        return;
    }

    dispatch_async(_packetQueue, ^{
        // Send packet length (4 bytes, network byte order)
        uint32_t packetLength = htonl((uint32_t)packet.length);
        ssize_t bytesSent = send(self->_tunnelSocket, &packetLength, 4, 0);

        if (bytesSent != 4) {
            NSLog(@"Error sending packet length");
            return;
        }

        // Send packet data
        bytesSent = send(self->_tunnelSocket, packet.bytes, packet.length, 0);

        if (bytesSent != packet.length) {
            NSLog(@"Error sending packet data");
        } else {
            NSLog(@"Sent packet to tunnel, length: %zu", packet.length);
        }
    });
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    NSLog(@"Stopping Net-Rewire tunnel, reason: %ld", (long)reason);

    _running = NO;

    // Clean up resources
    if (_reconnectTimer) {
        [_reconnectTimer invalidate];
        _reconnectTimer = nil;
    }

    if (_tunnelSocket >= 0) {
        close(_tunnelSocket);
        _tunnelSocket = -1;
    }

    _packetBuffer = nil;
    _packetQueue = nil;

    completionHandler();
}

- (void)handleAppMessage:(NSData *)messageData completionHandler:(void (^)(NSData *))completionHandler {
    // Handle messages from the containing app
    if (completionHandler) {
        completionHandler([@"OK" dataUsingEncoding:NSUTF8StringEncoding]);
    }
}

- (void)sleepWithCompletionHandler:(void (^)(void))completionHandler {
    // Tunnel is going to sleep
    completionHandler();
}

- (void)wake {
    // Tunnel is waking up
}

@end