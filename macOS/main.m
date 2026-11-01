//
//  main.m
//  macOS preview host: the game in a window the size of an iPhone screen.
//

#import <AppKit/AppKit.h>
#import "PBMacAppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        PBMacAppDelegate *delegate = [PBMacAppDelegate new];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
