// Renders the shipping SpriteKit UI over the real SceneKit table, without a simulator.
#import <AppKit/AppKit.h>
#import <SceneKit/SceneKit.h>
#import <Metal/Metal.h>
#import "PBTableScene.h"
#import "PBGameUI.h"
#import "PBTablePresentation.h"

static void Require(BOOL value, NSString *message) {
    if (!value) { NSLog(@"UI verification failed: %@", message); exit(1); }
}

static void VerifyShadowProjection(PBTableScene *scene, PBTableDefinition *table, CGSize size, CGFloat top, CGFloat bottom) {
    [scene fitCameraToViewSize:size topInset:top bottomInset:bottom];
    SCNNode *key = [scene.scene.rootNode childNodeWithName:@"lighting.key" recursively:YES];
    Require([key.light.type isEqualToString:SCNLightTypeDirectional], @"fixed directional key");
    Require(!key.light.automaticallyAdjustsShadowProjection, @"manual light projection");
    Require(CGSizeEqualToSize(key.light.shadowMapSize, CGSizeMake(4096, 2048)), @"4096x2048 shadow map (hard cap)");
    Require(key.light.shadowSampleCount >= 32, @"filtered shadow edges");
    Require(![scene.scene.rootNode childNodeWithName:@"lighting.rig" recursively:YES], @"no motion lighting rig");
    CGFloat span = key.light.orthographicScale;
    Require(span > 0 && span < 2.5, @"shadow map concentrates on the visible phone, not the oversized floor");
    SCNMatrix4 orientation = key.transform;
    SCNVector3 along = [key convertVector:SCNVector3Make(0, 0, -1) fromNode:scene.scene.rootNode];
    Require(fabs(along.x) > fabs(along.y), @"4096-texel map axis follows the long field axis");
    for (NSInteger i = 0; i < 8; i++) {
        float height = i & 4 ? .12f : 0;
        simd_float2 p = PBTablePointFromScreen(table.size, size, top, bottom,
            CGPointMake(i & 1 ? size.width : 0, i & 2 ? size.height : 0), height);
        SCNVector3 local = [key convertPosition:[scene worldPointAt:p height:height] fromNode:scene.scene.rootNode];
        Require(fabs(local.x) <= span * 2 && fabs(local.y) <= span, @"all display corners fit the shadow matrix");
        Require(-local.z >= key.light.zNear && -local.z <= key.light.zFar, @"receiver/caster depth fits the shadow matrix");
    }
    [scene fitCameraToViewSize:size topInset:top bottomInset:bottom];
    Require(SCNMatrix4EqualToMatrix4(orientation, key.transform), @"repeated layout keeps the shadow projection stable");
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

static void Export(SCNRenderer *renderer, PBGameUI *ui, PBMenuScreen screen, NSString *path, CGSize size) {
    [ui showScreen:screen];
    if (!renderer) return; // --check-only exercises real nodes/input without a graphics device.
    NSImage *image = [renderer snapshotAtTime:1 withSize:size antialiasingMode:SCNAntialiasingModeMultisampling4X];
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
    Require([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES], @"PNG export");
    NSLog(@"Rendered %@", path);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || argc > 4) { fprintf(stderr, "usage: render_ui_preview resource-bundle output-directory [--check-only]\n"); return 2; }
        BOOL checkOnly = argc == 4 && strcmp(argv[3], "--check-only") == 0;
        Require(argc == 3 || checkOnly, @"unknown option");
        [NSApplication sharedApplication];
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:NULL];
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        PBTableDefinition *table = [PBTableDefinition tableNamed:environment[@"PB_PREVIEW_TABLE"] ?: @"aurora" bundle:bundle error:NULL];
        PBSkin *skin = [PBSkin skinNamed:environment[@"PB_PREVIEW_SKIN"] ?: @"orbital" bundle:bundle];
        Require(table && skin, @"table and skin resources");
        PBTableScene *scene = [[PBTableScene alloc] initWithTable:table skin:skin];
        [scene fitCameraToViewSize:CGSizeMake(402, 874) topInset:59 bottomInset:34];
        VerifyShadowProjection(scene, table, CGSizeMake(393, 852), 59, 34);
        VerifyShadowProjection(scene, table, CGSizeMake(440, 956), 62, 34);
        VerifyShadowProjection(scene, table, CGSizeMake(375, 667), 20, 0);
        VerifyShadowProjection(scene, table, CGSizeMake(402, 874), 59, 34);
        Require(scene.cameraNode.camera.usesOrthographicProjection, @"world camera is orthographic");
        // SceneKit's actual view/projection matrix must agree with the UI's 2D boundary,
        // including elevated parts; otherwise it can drift even when both look plausible.
        simd_float4x4 projection = SCNMatrix4ToMat4([scene.cameraNode.camera projectionTransformWithViewportSize:CGSizeMake(402, 874)]);
        simd_float4x4 view = simd_inverse(scene.cameraNode.simdWorldTransform);
        for (NSInteger i = 0; i < 6; i++) {
            simd_float2 p = simd_make_float2(.1f + i * .15f, .1f + i * .3f);
            float elevation = i % 2 ? .12f : 0;
            SCNVector3 world = [scene worldPointAt:p height:elevation];
            simd_float4 clip = simd_mul(projection, simd_mul(view, simd_make_float4(world.x, world.y, world.z, 1)));
            CGPoint actual = CGPointMake((clip.x / clip.w + 1) * 201, (1 - clip.y / clip.w) * 437);
            CGPoint expected = PBTableScreenPoint(table.size, CGSizeMake(402, 874), 59, 34, p, elevation);
            Require(hypot(actual.x - expected.x, actual.y - expected.y) < .002, @"SceneKit and 2D overlay projections agree");
        }
        PBGame *game = [[PBGame alloc] initWithTable:table highScore:985400];
        NSMutableSet *guideLayers = [NSMutableSet set];
        [scene.scene.rootNode enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
            for (SCNMaterial *material in node.geometry.materials) {
                if (![@[@"guide_body", @"guide_face", @"guide_edge", @"guide_inlay", @"guide_mark", @"guide_tube"] containsObject:material.name]) continue;
                [guideLayers addObject:material.name];
                Require([material.lightingModelName isEqualToString:SCNLightingModelBlinn] && material.emission.intensity > 0, @"guide colour layers stay readable under grazing light");
                Require(!material.shaderModifiers[SCNShaderModifierEntryPointSurface], @"painted guides must not depend on a grey MatCap reflection");
            }
        }];
        Require(guideLayers.count == 6, @"compiled guides have all plate, cover and support-tube materials");
        for (NSUInteger i = 0; i < table.slingshots.count && i < table.plastics.count; i++) {
            PBPlasticDef *triangle = table.plastics[i];
            if (triangle.points.count != 3) continue;
            simd_float2 centre = (triangle.points.points[0] + triangle.points.points[1] + triangle.points.points[2]) / 3;
            SCNVector3 expected = [scene worldPointAt:centre height:.037f];
            NSString *name = [@"sling.flare." stringByAppendingString:table.slingshots[i].identifier];
            __block BOOL found = NO;
            [scene.scene.rootNode enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
                if (![node.light.name isEqualToString:name]) return;
                SCNVector3 light = node.worldPosition;
                float spotZ = light.z + (light.y - expected.y) * tanf(PBTableCameraTilt * (float)M_PI / 180);
                Require(fabs(light.x - expected.x) < 1e-5 && fabs(spotZ - expected.z) < 1e-5, @"slingshot flare lands at triangle centroid, not collision edge");
                found = YES;
            }];
            Require(found, @"triangle has its own flare light");
        }
        NSInteger fixtureBall = [game.world spawnBallAtPlunger];
        [game.world placeBall:fixtureBall at:table.plunger.position velocity:simd_make_float2(0, 0)];
        [scene syncWithGame:game elapsed:.001];
        SCNNode *ballVisual = [scene.scene.rootNode childNodeWithName:[NSString stringWithFormat:@"ball.visual.%ld", (long)fixtureBall] recursively:YES];
        Require([ballVisual.geometry isKindOfClass:SCNSphere.class], @"live ball has a sphere mesh");
        SCNMaterial *ballMaterial = ballVisual.geometry.firstMaterial;
        Require([ballMaterial.name isEqualToString:@"ball.coral-rubber"] && [ballMaterial.metalness.contents doubleValue] == 0, @"ball uses opaque nonmetallic coral rubber");
        Require([ballMaterial.roughness.contents doubleValue] >= .6 && [ballMaterial.clearCoat.contents doubleValue] == 0, @"rubber has a broad satin highlight and no lacquer coat");
        Require(ballMaterial.normal.contents != nil && ballMaterial.normal.intensity > 0 && ballMaterial.normal.intensity < .3, @"rubber has subtle mould grain");
        Require(![ballMaterial.shaderModifiers[SCNShaderModifierEntryPointFragment] containsString:@"pbPlayfield"], @"playfield reflections cannot replace the ball's colour");
        Require(fabs(((SCNSphere *)ballVisual.geometry).radius - table.ballRadius) < .00001, @"ball mesh radius exactly matches its collision radius");
        Require(fabs(table.ballRadius - .03 * 1.34 * .85) < .000001, @"ball is 15 percent smaller than the previous visible size");
        SCNVector3 physical = [scene worldPointAt:game.world.balls[fixtureBall].position height:game.world.balls[fixtureBall].z];
        Require(fabs(ballVisual.position.y - physical.y) < .00001, @"ball mesh and physical centre coincide");
        // A real wall collision deforms the actual mesh independently of its spin.
        [game.world placeBall:fixtureBall at:simd_make_float2(.8842f, 1) velocity:simd_make_float2(3, 0)];
        [game.world advanceOneTick];
        [scene syncWithGame:game elapsed:1.0 / 960];
        simd_float4x4 elastic = ballVisual.simdTransform;
        float horizontal = simd_length(simd_make_float3(elastic.columns[0].x, elastic.columns[1].x, elastic.columns[2].x));
        float vertical = simd_length(simd_make_float3(elastic.columns[0].y, elastic.columns[1].y, elastic.columns[2].y));
        simd_float3x3 mesh = { .columns = {elastic.columns[0].xyz, elastic.columns[1].xyz, elastic.columns[2].xyz} };
        Require(horizontal < .9 && vertical > 1.05, @"wall contact visibly squashes and bulges the mesh in the correct world axes");
        Require(fabs(simd_determinant(mesh) - 1) < 1e-5, @"rubber deformation preserves mesh volume even while rolling");
        Require(fabs(ballVisual.position.y - table.ballRadius * vertical) < 1e-5, @"deformed underside stays on the floor");
        // The shipping controller updates game + scene once per display frame.
        // A one-tick close-up alone previously missed the too-fast recovery.
        [game.world placeBall:fixtureBall at:simd_make_float2(.8842f, 1) velocity:simd_make_float2(2.4f, 0)];
        for (NSInteger frame = 0; frame < 5; frame++) {
            [game update:1.0 / 60];
            [scene syncWithGame:game elapsed:1.0 / 60];
            simd_float4x4 live = ballVisual.simdTransform;
            float extent = simd_length(simd_make_float3(live.columns[0].x, live.columns[1].x, live.columns[2].x));
            Require(!ballVisual.hidden && extent < .91f, @"live mesh stays visibly squeezed across five normal 60 Hz frames");
        }
        [game.world placeBall:fixtureBall at:table.plunger.position velocity:simd_make_float2(0, 0)];
        [scene syncWithGame:game elapsed:.001];
        id<MTLDevice> device = checkOnly ? nil : MTLCreateSystemDefaultDevice();
        Require(checkOnly || device != nil, @"Metal device unavailable; UI capture requires local graphics access");
        SCNRenderer *renderer = checkOnly ? nil : [SCNRenderer rendererWithDevice:device options:nil];
        renderer.scene = scene.scene; renderer.pointOfView = scene.cameraNode;
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
        ui.levelGoalKind = @"score"; ui.levelTarget = 7100;
        [ui updateScore:3550 best:985400 ball:2 ballCount:3];
        renderer.overlaySKScene = ui;
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
        [scene fitCameraToViewSize:CGSizeMake(375, 667) topInset:20 bottomInset:0];
        Export(renderer, ui, PBMenuHome, [output stringByAppendingPathComponent:@"ui-home-small.png"], CGSizeMake(750, 1334));
        Export(renderer, ui, PBMenuSettings, [output stringByAppendingPathComponent:@"ui-settings-small.png"], CGSizeMake(750, 1334));
        [ui updateScore:52666 best:985400 ball:2 ballCount:3];
        Export(renderer, ui, PBMenuPlaying, [output stringByAppendingPathComponent:@"ui-playing-small.png"], CGSizeMake(750, 1334));
        if (!checkOnly) {
            [ui layoutForViewSize:CGSizeMake(402, 874) topInset:59 bottomInset:34];
            [scene fitCameraToViewSize:CGSizeMake(402, 874) topInset:59 bottomInset:34];
            [ui updateScore:3550 best:985400 ball:2 ballCount:3];
            // Let SpriteKit finish the viewport resize before adding the transient effect.
            [renderer snapshotAtTime:1 withSize:CGSizeMake(804, 1748) antialiasingMode:SCNAntialiasingModeMultisampling4X];
            [ui showImpactAtPoint:CGPointMake(210, 420) color:SKColor.orangeColor sparks:0 points:1000];
            // SpriteKit overlay actions use the live renderer clock. Advance
            // real frames as well as SceneKit time to capture the completed pop.
            for (NSInteger frame = 0; frame < 12; frame++) {
                [renderer snapshotAtTime:1 + frame / 60.0 withSize:CGSizeMake(804, 1748) antialiasingMode:SCNAntialiasingModeMultisampling4X];
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0 / 60]];
            }
            NSImage *impact = [renderer snapshotAtTime:1.18 withSize:CGSizeMake(804, 1748) antialiasingMode:SCNAntialiasingModeMultisampling4X];
            NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:impact.TIFFRepresentation];
            Require([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:@"ui-playing-impact.png"] atomically:YES], @"floating score capture");
        }
        NSLog(@"UI pointer routing, HUD clearance and orthographic camera verified%@", checkOnly ? @" (check-only; no screenshots rendered)" : @"");
    }
    return 0;
}
