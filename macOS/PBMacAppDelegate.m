//
//  PBMacAppDelegate.m
//
//  Keys: Z or Left Shift or Left Arrow = left flipper. / or Right Shift or Right Arrow = right flipper.
//  Space or Return = plunger (hold to charge). X, C, V = nudge left, up, right. S = next skin.
//

#import "PBMacAppDelegate.h"
#import <Carbon/Carbon.h>
#import <SceneKit/SceneKit.h>
#import "PBGameController.h"

/// iPhone 17 screen, in points.
static const CGFloat kPreviewWidth = 402;
static const CGFloat kPreviewHeight = 874;
static const float kNudgeImpulse = 0.42f;

@interface PBKeyboardView : SCNView
@property (nonatomic, weak) PBGameController *controller;
@end

@implementation PBKeyboardView

- (BOOL)acceptsFirstResponder { return YES; }

- (BOOL)handleKeyCode:(unsigned short)code down:(BOOL)down {
    PBGame *game = self.controller.game;
    switch (code) {
        case kVK_ANSI_Z:
        case kVK_LeftArrow: [game setLeftPressed:down]; return YES;
        case kVK_ANSI_Slash:
        case kVK_RightArrow: [game setRightPressed:down]; return YES;
        case kVK_Space:
        case kVK_Return: [game setPlungerPressed:down]; return YES;
        case kVK_ANSI_X: if (down) [game requestNudgeX:-kNudgeImpulse y:0]; return YES;
        case kVK_ANSI_C: if (down) [game requestNudgeX:0 y:kNudgeImpulse]; return YES;
        case kVK_ANSI_V: if (down) [game requestNudgeX:kNudgeImpulse y:0]; return YES;
        case kVK_ANSI_S: if (down) [self.controller selectNextSkin]; return YES;
    }
    return NO;
}

- (void)keyDown:(NSEvent *)event {
    if (event.isARepeat) return;
    if (![self handleKeyCode:event.keyCode down:YES]) [super keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    if (![self handleKeyCode:event.keyCode down:NO]) [super keyUp:event];
}

- (void)flagsChanged:(NSEvent *)event {
    PBGame *game = self.controller.game;
    if (event.keyCode == kVK_Shift) [game setLeftPressed:(event.modifierFlags & NSEventModifierFlagShift) != 0];
    if (event.keyCode == kVK_RightShift) [game setRightPressed:(event.modifierFlags & NSEventModifierFlagShift) != 0];
}

@end

@implementation PBMacAppDelegate {
    NSWindow *_window;
    PBGameController *_controller;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMenu];

    // Same size as the phone. On a display too short for that, keep the shape and scale down.
    CGFloat available = NSScreen.mainScreen.visibleFrame.size.height - 32;
    CGFloat scale = MIN(1.0, available / kPreviewHeight);
    NSRect frame = NSMakeRect(0, 0, floor(kPreviewWidth * scale), floor(kPreviewHeight * scale));

    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Pinball Preview";
    [_window center];

    PBKeyboardView *view = [[PBKeyboardView alloc] initWithFrame:frame options:nil];
    view.backgroundColor = NSColor.blackColor;
    _window.contentView = view;
    _controller = [[PBGameController alloc] initWithView:view];
    view.controller = _controller;

    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:view];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }

- (void)buildMenu {
    NSMenu *menuBar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [menuBar addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit Pinball" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = menuBar;
}

@end
