//
//  AppDelegate.m
//  NetRewireApp
//
//  Created by Claude Code
//

#import "AppDelegate.h"
#import <NetworkExtension/NetworkExtension.h>

@interface AppDelegate ()
@property (strong) NETunnelProviderManager *manager;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Create the main window
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window setTitle:@"Net-Rewire"];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];

    // Create UI elements
    NSButton *startButton = [[NSButton alloc] initWithFrame:NSMakeRect(150, 150, 100, 30)];
    [startButton setTitle:@"Start VPN"];
    [startButton setButtonType:NSButtonTypeMomentaryPushIn];
    [startButton setBezelStyle:NSBezelStyleRounded];
    [startButton setTarget:self];
    [startButton setAction:@selector(startVPN:)];

    NSButton *stopButton = [[NSButton alloc] initWithFrame:NSMakeRect(150, 100, 100, 30)];
    [stopButton setTitle:@"Stop VPN"];
    [stopButton setButtonType:NSButtonTypeMomentaryPushIn];
    [stopButton setBezelStyle:NSBezelStyleRounded];
    [stopButton setTarget:self];
    [stopButton setAction:@selector(stopVPN:)];

    NSTextField *statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 50, 300, 30)];
    [statusLabel setStringValue:@"VPN Status: Not Connected"];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];

    NSView *contentView = self.window.contentView;
    [contentView addSubview:startButton];
    [contentView addSubview:stopButton];
    [contentView addSubview:statusLabel];

    // Load VPN configuration
    [self loadVPNConfiguration];
}

- (void)loadVPNConfiguration {
    [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager *> * _Nullable managers, NSError * _Nullable error) {
        if (error) {
            NSLog(@"Error loading VPN managers: %@", error);
            return;
        }

        if (managers.count > 0) {
            self.manager = managers[0];
        } else {
            [self createVPNConfiguration];
        }
    }];
}

- (void)createVPNConfiguration {
    self.manager = [[NETunnelProviderManager alloc] init];

    // Configure the VPN
    NETunnelProviderProtocol *protocol = [[NETunnelProviderProtocol alloc] init];
    protocol.providerBundleIdentifier = @"com.netrewire.NetRewirePacketTunnel";
    protocol.serverAddress = @"10.8.0.1"; // Ubuntu server address

    self.manager.protocolConfiguration = protocol;
    self.manager.localizedDescription = @"Net-Rewire VPN";

    [self.manager saveToPreferencesWithCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"Error saving VPN configuration: %@", error);
        } else {
            NSLog(@"VPN configuration saved successfully");
        }
    }];
}

- (IBAction)startVPN:(id)sender {
    if (!self.manager) {
        NSLog(@"No VPN manager available");
        return;
    }

    NSError *error = nil;
    [self.manager.connection startVPNTunnelWithOptions:@{} andReturnError:&error];

    if (error) {
        NSLog(@"Error starting VPN: %@", error);
    } else {
        NSLog(@"VPN started successfully");
    }
}

- (IBAction)stopVPN:(id)sender {
    if (!self.manager) {
        NSLog(@"No VPN manager available");
        return;
    }

    [self.manager.connection stopVPNTunnel];
    NSLog(@"VPN stopped");
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

@end