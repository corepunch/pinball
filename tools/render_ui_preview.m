// Renders the shipping SpriteKit UI over the real SceneKit table, without a simulator.
#import <AppKit/AppKit.h>
#import <SceneKit/SceneKit.h>
#import <Metal/Metal.h>
#import "PBTableScene.h"
#import "PBGameUI.h"

static void Require(BOOL value, NSString *message) {
    if (!value) { NSLog(@"UI verification failed: %@", message); exit(1); }
}

static void Export(SCNRenderer *renderer, PBGameUI *ui, PBMenuScreen screen, NSString *path, CGSize size) {
    [ui showScreen:screen];
    NSImage *image = [renderer snapshotAtTime:1 withSize:size antialiasingMode:SCNAntialiasingModeMultisampling4X];
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
    Require([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES], @"PNG export");
    NSLog(@"Rendered %@", path);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: render_ui_preview Pinball.app output-directory\n"); return 2; }
        [NSApplication sharedApplication];
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:NULL];
        PBTableDefinition *table = [PBTableDefinition tableNamed:@"aurora" bundle:bundle error:NULL];
        PBSkin *skin = [PBSkin skinNamed:@"orbital" bundle:bundle];
        Require(table && skin, @"table and skin resources");
        PBTableScene *scene = [[PBTableScene alloc] initWithTable:table skin:skin];
        [scene fitCameraToAspect:874.0 / 402.0];
        SCNRenderer *renderer = [SCNRenderer rendererWithDevice:MTLCreateSystemDefaultDevice() options:nil];
        renderer.scene = scene.scene; renderer.pointOfView = scene.cameraNode;
        PBGameUI *ui = [[PBGameUI alloc] initWithBundle:bundle];
        ui.tableName = table.name;
        // A mid-progress player; free-play menus show when there is no level list.
        ui.levelStars = @[@3, @2, @1, @3, @1, @0, @-1, @-1, @-1, @-1, @-1, @-1, @-1, @-1, @-1];
        ui.totalStars = 10;
        ui.currentLevel = 5;
        ui.levelName = @"Second Orbit";
        ui.levelGoal = @"3 RAMPS";
        ui.levelTwoStarScore = 60000;
        ui.levelThreeStarScore = 150000;
        ui.levelBest = 42000;
        ui.resultStars = 2;
        ui.resultGoalMet = YES;
        ui.hasNextLevel = YES;
        [ui showLevelPageForLevel:5];
        [ui layoutForViewSize:CGSizeMake(402, 874) topInset:59 bottomInset:34];
        [ui updateScore:248650 best:985400 ball:2 ballCount:3];
        renderer.overlaySKScene = ui;
        NSArray *names = @[@"home", @"playing", @"paused", @"settings", @"help", @"results", @"confirm-home", @"confirm-restart", @"levels", @"level-intro"];
        for (NSInteger i = 0; i < names.count; i++) {
            Export(renderer, ui, (PBMenuScreen)i, [output stringByAppendingFormat:@"/ui-%@.png", names[i]], CGSizeMake(804, 1748));
        }
        // Touch routing: menu background is swallowed; a cancelled Play never starts.
        __block NSInteger actions = 0;
        __block PBUIAction lastAction = PBUIPlay;
        ui.actionHandler = ^(PBUIAction action) { actions++; lastAction = action; };
        [ui layoutForViewSize:CGSizeMake(402, 874) topInset:0 bottomInset:0];
        [ui showScreen:PBMenuHome];
        Require([ui pointerBegan:@"background" atPoint:CGPointMake(4, 4)], @"menu background captures touches");
        [ui pointerEnded:@"background" atPoint:CGPointMake(4, 4) cancelled:NO];
        CGPoint play = CGPointMake(201, 577); // 874/2 + 140: primary button in the centered home panel.
        Require([ui pointerBegan:@"play" atPoint:play], @"Play captures touch");
        [ui pointerEnded:@"play" atPoint:play cancelled:YES];
        Require(actions == 0, @"cancelled touch must not activate");
        [ui pointerBegan:@"play" atPoint:play];
        [ui pointerEnded:@"play" atPoint:play cancelled:NO];
        Require(actions == 1, @"Play activates exactly once");
        [ui pointerBegan:@"play" atPoint:play];
        [ui pointerMoved:@"play" atPoint:CGPointMake(4, 4)];
        [ui pointerEnded:@"play" atPoint:CGPointMake(4, 4) cancelled:NO];
        Require(actions == 1, @"dragging off a button cancels activation");
        [ui showScreen:PBMenuPlaying];
        Require(![ui pointerBegan:@"flipper" atPoint:CGPointMake(80, 650)], @"gameplay touch passes through HUD");
        [ui pointerBegan:@"pause" atPoint:CGPointMake(355, 42)];
        [ui pointerEnded:@"pause" atPoint:CGPointMake(355, 42) cancelled:NO];
        Require(actions == 2 && lastAction == PBUIPause, @"pause button activates while gameplay touches pass through");
        [ui layoutForViewSize:CGSizeMake(375, 667) topInset:20 bottomInset:0];
        [scene fitCameraToAspect:667.0 / 375.0];
        Export(renderer, ui, PBMenuHome, [output stringByAppendingPathComponent:@"ui-home-small.png"], CGSizeMake(750, 1334));
        Export(renderer, ui, PBMenuSettings, [output stringByAppendingPathComponent:@"ui-settings-small.png"], CGSizeMake(750, 1334));
        NSLog(@"UI pointer routing and small-screen previews verified");
    }
    return 0;
}
