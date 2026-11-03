// Verifies and captures the shipping SpriteKit table and HUD, without a simulator.
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import "PBTableSprites.h"
#import "PBGateGeometry.h"
#import "PBSpriteSnapshot.h"
#import "PBGameUI.h"
#import "PBTablePresentation.h"

static void Require(BOOL value, NSString *message) {
    if (!value) { NSLog(@"UI verification failed: %@", message); exit(1); }
}

static void VerifyFullScreen(PBGameUI *ui, PBTableDefinition *table, CGSize size, CGFloat top, CGFloat bottom) {
    [ui layoutForViewSize:size topInset:top bottomInset:bottom];
    [ui showScreen:PBMenuPlaying];
    Require(![ui childNodeWithName:@"//hud.board-outline"], @"no inset Roman arch around the board");
    Require(![ui childNodeWithName:@"//hud.header"], @"floating HUD has no panel");
    Require(![ui childNodeWithName:@"//hud.drain-outline"] && ![ui childNodeWithName:@"//hud.drain-outline-highlight"], @"no bright trim around the drain or shooter channel");
    SKShapeNode *sink = (SKShapeNode *)[ui childNodeWithName:@"//hud.sink"];
    Require(sink != nil, @"dark drain well remains");
    CGRect well = CGPathGetPathBoundingBox(sink.path);
    CGFloat scale = size.width / 402;
    CGSize logical = CGSizeMake(402, size.height / scale);
    PBWallDef *left = nil, *right = nil;
    for (PBWallDef *wall in table.walls) {
        if ([wall.identifier isEqualToString:@"apronL"]) left = wall;
        if ([wall.identifier isEqualToString:@"apronR"]) right = wall;
    }
    CGPoint a = PBTableScreenPoint(table.size, logical, top / scale, bottom / scale, left.points.points[0], 0);
    CGPoint b = PBTableScreenPoint(table.size, logical, top / scale, bottom / scale, right.points.points[0], 0);
    Require(fabs(CGRectGetMidX(well) - (a.x + b.x) * .5) < .01, @"sink follows the actual playfield drain axis");
    Require(CGRectGetMinY(well) < logical.height - a.y - 2, @"dark well follows the drain opening");
    Require(CGRectGetMinY(well) >= -.01, @"sink stays on screen");
}

static void Export(id renderer, PBGameUI *ui, PBMenuScreen screen, NSString *path, CGSize size) {
    [ui showScreen:screen];
    if (!renderer) return;
    NSImage *image = PBSpriteSnapshot(ui,size);
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
    Require([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES], @"PNG export");
    NSLog(@"Captured shipping sprite graph: %@", path);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || argc > 4) { fprintf(stderr, "usage: render_ui_preview resource-bundle output-directory [--check-only]\n"); return 2; }
        BOOL checkOnly = argc == 4 && strcmp(argv[3], "--check-only") == 0;
        Require(argc == 3 || checkOnly, @"unknown option");
        [NSApplication sharedApplication];
        PBCaptureTextureSources();
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:NULL];
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        PBTableDefinition *table = [PBTableDefinition tableNamed:environment[@"PB_PREVIEW_TABLE"] ?: @"aurora" bundle:bundle error:NULL];
        Require(table != nil, @"table resources");
        PBTableSprites *scene = [[PBTableSprites alloc] initWithTable:table];
        SKColor *original = ((SKSpriteNode *)[scene childNodeWithName:@"//table.floor"]).color;
        [scene setPlayfieldColor:SKColor.blueColor];
        SKColor *blue = [((SKSpriteNode *)[scene childNodeWithName:@"//table.floor"]).color colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
        Require(blue && blue.blueComponent>.99 && blue.redComponent<.01,@"skin selection can change the sprite field palette");
        [scene setPlayfieldColor:original];
        PBGame *game = [[PBGame alloc] initWithTable:table highScore:0 seed:17];
        [game requestNewGame]; [game update:1.0/60];
        [scene syncWithGame:game];
        id renderer = checkOnly ? nil : @YES;
        PBGameUI *ui = [[PBGameUI alloc] initWithBundle:bundle];
        ui.tableDefinition = table;
        VerifyFullScreen(ui, table, CGSizeMake(320, 568), 20, 0);
        VerifyFullScreen(ui, table, CGSizeMake(375, 667), 20, 0);
        VerifyFullScreen(ui, table, CGSizeMake(402, 874), 62, 34);
        VerifyFullScreen(ui, table, CGSizeMake(440, 956), 62, 34);
        ui.tableName = table.name;
        // A mid-progress player; free-play menus show when there is no level list.
        ui.levelStars = @[@3, @2, @1, @3, @1, @0, @-1, @-1, @-1, @-1, @-1, @-1, @-1, @-1, @-1];
        ui.totalStars = 10;
        ui.currentLevel = 5;
        ui.levelName = @"First Light";
        ui.levelGoal = @"24,000 POINTS";
        ui.levelTwoStarScore = 60000;
        ui.levelThreeStarScore = 150000;
        ui.levelBest = 42000;
        ui.resultStars = 2;
        ui.resultGoalMet = YES;
        ui.hasNextLevel = YES;
        [ui showLevelPageForLevel:5];
        [ui layoutForViewSize:CGSizeMake(402, 874) topInset:59 bottomInset:34];
        ui.levelGoalKind = @"score"; ui.levelTarget = 7100;
        [ui updateScore:3550 best:985400 ball:2 ballCount:3];
        scene.zPosition = -100;
        [ui addChild:scene];
        [scene layoutForViewSize:CGSizeMake(402,874) topInset:59 bottomInset:34];
        NSArray *names = @[@"home", @"playing", @"paused", @"settings", @"help", @"results", @"confirm-home", @"confirm-restart", @"levels", @"level-intro"];
        for (NSInteger i = 0; i < names.count; i++) {
            Export(renderer, ui, (PBMenuScreen)i, [output stringByAppendingFormat:@"/ui-%@.png", names[i]], CGSizeMake(804, 1748));
        }
        // The single score row and launch-channel gauge use the actual level target.
        ui.levelGoalKind = @"score";
        ui.levelTarget = 7100;
        [ui updateScore:3550 best:985400 ball:2 ballCount:3];
        Export(renderer, ui, PBMenuPlaying, [output stringByAppendingPathComponent:@"ui-playing-progress.png"], CGSizeMake(804, 1748));
        SKNode *fill = [ui childNodeWithName:@"//hud.progress-fill"];
        Require(fill && fabs(fill.yScale - .5) < .001, @"gauge is half full at half the required score");
        [ui updateScore:INT64_MAX best:INT64_MAX ball:3 ballCount:3];
        [ui showMessage:@"BALL SAVE — MULTIBALL JACKPOT"];
        Export(renderer, ui, PBMenuPlaying, [output stringByAppendingPathComponent:@"ui-playing-long.png"], CGSizeMake(804, 1748));
        fill = [ui childNodeWithName:@"//hud.progress-fill"];
        SKNode *score = [ui childNodeWithName:@"//hud.score"];
        SKNode *pause = [ui childNodeWithName:@"//hud.pause"];
        Require(score && pause, @"compact HUD nodes exist");
        Require(![ui childNodeWithName:@"//hud.balls"] && ![ui childNodeWithName:@"//hud.message"] && ![ui childNodeWithName:@"//hud.level"], @"no Ball, Save, level caption or message rows");
        Require(CGRectGetMaxX(score.frame) < CGRectGetMinX([pause calculateAccumulatedFrame]), @"largest score and target clear pause");
        Require(CGRectGetMinY(score.frame) >= 874 - 59 - 50, @"score occupies one safe-area row");
        Require(CGRectGetMaxY(score.frame) <= 874 - 59, @"score clears Dynamic Island");
        Require(fabs(fill.yScale - 1) < .001, @"progress saturates at the target");
        [ui updateScore:0 best:0 ball:1 ballCount:3];
        Require(fill.hidden && fill.yScale == 0, @"restart empties the gauge");
        ui.levelTarget = 3; ui.levelGoalKind = @"ramps"; ui.levelProgress = 1;
        [ui updateScore:5000 best:0 ball:1 ballCount:3];
        Require(fabs(fill.yScale - 1.0 / 3) < .001, @"mechanism goals use session progress, not points");
        ui.levelTarget = 0;
        [ui updateScore:5000 best:0 ball:1 ballCount:3];
        Require([ui childNodeWithName:@"//hud.progress"].hidden, @"free play has no invented level target");
        ui.levelTarget = 7100; ui.levelGoalKind = @"score";
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
        Require(![ui pointerBegan:@"header" atPoint:CGPointMake(100, 40)], @"decorative header passes touches through");
        PBGameViewLayout layout = PBGameViewLayoutMake(CGSizeMake(402, 874), 0, 0);
        CGPoint pausePoint = CGPointMake(CGRectGetMidX(layout.pause), CGRectGetMidY(layout.pause));
        [ui pointerBegan:@"pause" atPoint:pausePoint];
        [ui pointerEnded:@"pause" atPoint:pausePoint cancelled:NO];
        Require(actions == 2 && lastAction == PBUIPause, @"pause button activates while gameplay touches pass through");
        // The Dynamic Island's space remains decorative; it must never activate pause.
        [ui layoutForViewSize:CGSizeMake(402, 874) topInset:62 bottomInset:34];
        Require(![ui pointerBegan:@"island" atPoint:CGPointMake(201, 35)], @"Dynamic Island region has no controls");
        layout = PBGameViewLayoutMake(CGSizeMake(402, 874), 62, 34);
        pausePoint = CGPointMake(CGRectGetMidX(layout.pause), CGRectGetMidY(layout.pause));
        [ui pointerBegan:@"safe-pause" atPoint:pausePoint];
        [ui pointerEnded:@"safe-pause" atPoint:pausePoint cancelled:NO];
        Require(actions == 3 && lastAction == PBUIPause, @"pause follows the device safe area");
        [ui layoutForViewSize:CGSizeMake(375, 667) topInset:20 bottomInset:0];
        [scene layoutForViewSize:CGSizeMake(375, 667) topInset:20 bottomInset:0];
        Export(renderer, ui, PBMenuHome, [output stringByAppendingPathComponent:@"ui-home-small.png"], CGSizeMake(750, 1334));
        Export(renderer, ui, PBMenuSettings, [output stringByAppendingPathComponent:@"ui-settings-small.png"], CGSizeMake(750, 1334));
        [ui updateScore:52666 best:985400 ball:2 ballCount:3];
        Export(renderer, ui, PBMenuPlaying, [output stringByAppendingPathComponent:@"ui-playing-small.png"], CGSizeMake(750, 1334));
        // Live sprites follow actual physics on small and large phones.
        const CGSize phones[] = {{320,568},{375,667},{402,874},{440,956}};
        SKNode *ball = [scene childNodeWithName:@"//ball.0"];
        Require([ball isKindOfClass:SKSpriteNode.class], @"ball is a textured sprite");
        for (NSUInteger phone=0;phone<4;phone++) {
            CGSize size = phones[phone];
            CGFloat top = phone<2 ? 20 : 62, bottom = phone<2 ? 0 : 34;
            [scene layoutForViewSize:size topInset:top bottomInset:bottom];
            [game.world fitDisplayBoundaryToViewSize:size topInset:top bottomInset:bottom];
            CGPoint a = PBTableScreenPoint(table.size,size,top,bottom,0,0);
            CGPoint b = PBTableScreenPoint(table.size,size,top,bottom,simd_make_float2(table.ballRadius*2,0),0);
            Require(fabs((b.x-a.x)/size.width-.06834)<.00001,@"1/15 ball scale across phone sizes");
            [game.world placeBall:0 at:table.plunger.position velocity:0];
            [game.world autoPlunge];
            for (NSInteger i=0;i<120;i++) {
                [game setLeftPressed:i<60]; [game update:1.0/60]; [scene syncWithGame:game];
                CGPoint actual = [scene convertPoint:ball.position fromNode:ball.parent];
                CGPoint expected = PBTableScreenPoint(table.size,size,top,bottom,game.world.balls[0].position,0);
                Require(hypot(actual.x-expected.x,size.height-actual.y-expected.y)<.001,@"sprite and sphere positions match");
                Require(fabs([scene childNodeWithName:@"//flipperL"].zRotation-[game.world flipperAngle:0])<.0001,@"flipper sprite follows physics");
                if (table.gates.count) {
                    PBEdgeDef *gate = table.gates[0];
                    Require(fabs([scene childNodeWithName:[@"//" stringByAppendingString:gate.identifier]].zRotation-[game.world gateAngle:0]*PBGateOpeningSign(gate.a,gate.b,gate.passDirection))<.0001,@"gate rotates about physical hinge in the correct direction");
                }
            }
        }
        if (table.dropTargets.count) {
            [game.world setDropTarget:0 up:NO]; [scene syncWithGame:game];
            Require([scene childNodeWithName:[@"//" stringByAppendingString:table.dropTargets[0].identifier]].alpha<.2,@"dropped sprite clears the shot");
            [game.world setDropTarget:0 up:YES]; [scene syncWithGame:game];
            Require([scene childNodeWithName:[@"//" stringByAppendingString:table.dropTargets[0].identifier]].alpha==1,@"raised sprite returns with its collider");
        }
        __block BOOL changed = NO, updated = NO;
        ui.deferChanges = YES;
        [ui applyChange:^{ changed = YES; }];
        ui.frameHandler = ^(NSTimeInterval time) { Require(changed,@"queued changes precede simulation"); updated = YES; };
        [ui update:1]; Require(updated,@"SpriteKit scene drives the frame loop");
        ui.frameHandler = nil; ui.deferChanges = NO;
        [ui layoutForViewSize:CGSizeMake(402,874) topInset:59 bottomInset:34];
        [scene layoutForViewSize:CGSizeMake(402,874) topInset:59 bottomInset:34];
        [game.world placeBall:0 at:simd_make_float2(.45,.72) velocity:0];
        [scene syncWithGame:game];
        [ui updateScore:3550 best:985400 ball:1 ballCount:3];
        Export(renderer,ui,PBMenuPlaying,[output stringByAppendingPathComponent:@"mini-pinball.png"],CGSizeMake(804,1748));
        if (!checkOnly) {
            [game.world fitDisplayBoundaryToViewSize:CGSizeMake(402,874) topInset:59 bottomInset:34];
            [game requestNewGame]; [game update:.02]; [game.world autoPlunge];
            NSURL *url = [NSURL fileURLWithPath:[output stringByAppendingPathComponent:@"mini-pinball-motion.gif"]];
            CGImageDestinationRef gif = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("com.compuserve.gif"),150,NULL);
            CGImageDestinationSetProperties(gif,(__bridge CFDictionaryRef)@{(NSString *)kCGImagePropertyGIFDictionary:@{(NSString *)kCGImagePropertyGIFLoopCount:@0}});
            for (NSInteger i=0;i<150;i++) @autoreleasepool {
                [game setLeftPressed:i%50<8]; [game setRightPressed:i%60<8];
                [game update:.02]; [scene syncWithGame:game];
                NSImage *frame = PBSpriteSnapshot(ui,CGSizeMake(402,874));
                CGImageRef pixels = [frame CGImageForProposedRect:NULL context:nil hints:nil];
                CGImageDestinationAddImage(gif,pixels,(__bridge CFDictionaryRef)@{(NSString *)kCGImagePropertyGIFDictionary:@{(NSString *)kCGImagePropertyGIFDelayTime:@.02}});
            }
            Require(CGImageDestinationFinalize(gif),@"normal-speed sprite capture"); CFRelease(gif);
        }
        NSLog(@"UI pointer routing, HUD clearance, flat sprites and live physics verified%@", checkOnly ? @" (check-only; no screenshots rendered)" : @"");
    }
    return 0;
}
