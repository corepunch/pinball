// Render the actual SceneKit scene without playing or capturing another app.
// Build/run instructions are in Art/SKIN_GUIDE.md.
#import <AppKit/AppKit.h>
#import <SceneKit/SceneKit.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import "PBTableScene.h"
#import "PBLayoutValidator.h"
#import "PBTablePresentation.h"
#import "PBGateGeometry.h"

static void PBRequire(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"Preview validation failed: %@", message); exit(1); }
}

static void PBExport(SCNRenderer *renderer, double time, NSString *path) {
    NSImage *image = [renderer snapshotAtTime:time withSize:CGSizeMake(804, 1743)
                           antialiasingMode:SCNAntialiasingModeMultisampling4X];
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    PBRequire([png writeToFile:path atomically:YES], @"PNG export failed");
    NSLog(@"Validated and rendered %@", path);
}

// Enlarge the upper channels without changing the gameplay camera angle.
static void PBExportChannelWalls(PBTableScene *scene, SCNRenderer *renderer, PBTableDefinition *table, NSString *path) {
    __block BOOL hasLining = NO;
    [scene.scene.rootNode enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
        for (SCNMaterial *material in node.geometry.materials) {
            if ([material.name isEqualToString:@"channel_liner"]) {
                PBRequire([material.lightingModelName isEqualToString:SCNLightingModelBlinn], @"inner walls must receive real lighting");
                hasLining = YES;
            }
        }
    }];
    PBRequire(hasLining || table.ramps.count == 0, @"channel inner-wall lining failed to load");
    SCNVector3 camera = scene.cameraNode.position;
    CGFloat scale = scene.cameraNode.camera.orthographicScale;
    float top = 0;
    for (PBRampDef *ramp in table.ramps) for (NSInteger i = 0; i < ramp.pointCount; i++) top = MAX(top, [ramp pointAtIndex:i].y);
    // A close-up: the same lens, lowered over the ramps' top end.
    scene.cameraNode.camera.orthographicScale = .46 * .45 * .5;
    scene.cameraNode.position = SCNVector3Make(camera.x, camera.y,
        table.size.y * .5f - (top - .09f) + camera.y * tanf(PBTableCameraTilt * (float)M_PI / 180.0f));
    NSImage *image = [renderer snapshotAtTime:2.016 withSize:CGSizeMake(1000, 450) antialiasingMode:SCNAntialiasingModeMultisampling4X];
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
    PBRequire([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES], @"channel wall close-up failed");
    scene.cameraNode.position = camera;
    scene.cameraNode.camera.orthographicScale = scale;
    NSLog(@"Verified channel lining and exported gameplay-angle close-up %@", path);
}

static void PBExportSlingshotFasteners(PBTableScene *scene, SCNRenderer *renderer, PBTableDefinition *table, NSString *output) {
    simd_float4x4 cameraTransform = scene.cameraNode.simdTransform;
    SCNVector3 camera = scene.cameraNode.position;
    CGFloat scale = scene.cameraNode.camera.orthographicScale;
    for (PBPlasticDef *part in table.plastics) {
        if (![part.identifier hasPrefix:@"plasticSling"]) continue;
        simd_float2 low = part.points.points[0], high = low;
        for (NSInteger i = 1; i < part.points.count; i++) {
            low = simd_min(low, part.points.points[i]); high = simd_max(high, part.points.points[i]);
        }
        simd_float2 centre = (low + high) * .5f;
        scene.cameraNode.camera.orthographicScale = .19;
        scene.cameraNode.position = SCNVector3Make(centre.x - table.size.x * .5f, camera.y,
            table.size.y * .5f - centre.y + camera.y * tanf(PBTableCameraTilt * (float)M_PI / 180.0f));
        NSImage *image = [renderer snapshotAtTime:2.016 withSize:CGSizeMake(512, 768) antialiasingMode:SCNAntialiasingModeMultisampling4X];
        NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
        NSString *path = [output stringByAppendingFormat:@"/%@-fasteners.png", part.identifier];
        PBRequire([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES], @"slingshot fastener close-up export");
        // True orthographic isometry: equal x/y/z camera offsets, using the live
        // compiled model and production materials, not a replacement mesh.
        SCNVector3 target = [scene worldPointAt:centre height:.0185f];
        scene.cameraNode.position = SCNVector3Make(target.x + 1, target.y + 1, target.z + 1);
        [scene.cameraNode lookAt:target];
        scene.cameraNode.camera.orthographicScale = .18;
        NSImage *isometry = [renderer snapshotAtTime:2.016 withSize:CGSizeMake(1000, 1000) antialiasingMode:SCNAntialiasingModeMultisampling4X];
        NSBitmapImageRep *isoBitmap = [NSBitmapImageRep imageRepWithData:isometry.TIFFRepresentation];
        NSString *isoPath = [output stringByAppendingFormat:@"/%@-isometry.png", part.identifier];
        PBRequire([[isoBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:isoPath atomically:YES], @"slingshot isometry export");
        scene.cameraNode.simdTransform = cameraTransform;
        NSLog(@"Rendered real slingshot isometry %@", isoPath);
    }
    scene.cameraNode.simdTransform = cameraTransform; scene.cameraNode.camera.orthographicScale = scale;
}

static void PBExportLowerLanes(PBTableScene *scene, SCNRenderer *renderer, PBTableDefinition *table, NSString *output, NSString *name) {
    SCNVector3 camera = scene.cameraNode.position;
    CGFloat scale = scene.cameraNode.camera.orthographicScale;
    // Exactly one table width: the left image edge is the physical display edge,
    // so the outer lane can be compared with the three interior channels.
    scene.cameraNode.camera.orthographicScale = .2;
    scene.cameraNode.position = SCNVector3Make(0, camera.y,
        table.size.y * .5f - .43f + camera.y * tanf(PBTableCameraTilt * (float)M_PI / 180));
    NSImage *image = [renderer snapshotAtTime:2.016 withSize:CGSizeMake(1200, 480) antialiasingMode:SCNAntialiasingModeMultisampling4X];
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
    PBRequire([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:name] atomically:YES], @"lower channel clearance close-up");
    scene.cameraNode.position = camera; scene.cameraNode.camera.orthographicScale = scale;
}

static void PBExportHardwareConstruction(PBTableScene *scene, SCNRenderer *renderer, PBTableDefinition *table, NSString *output) {
    simd_float4x4 camera = scene.cameraNode.simdTransform;
    CGFloat scale = scene.cameraNode.camera.orthographicScale;
    simd_float2 centre = (table.flippers[0].pivot + table.flippers[1].pivot) * .5f;
    centre.y = .325f;
    for (NSInteger detail = 0; detail < 2; detail++) {
        simd_float2 at = centre;
        if (detail) {
            PBFlipperDef *flipper = table.flippers[0];
            at = flipper.pivot + simd_make_float2(cosf(flipper.restAngle), sinf(flipper.restAngle)) * flipper.length * .45f;
        }
        SCNVector3 target = [scene worldPointAt:at height:detail ? .038f : .02f];
        scene.cameraNode.position = SCNVector3Make(target.x + 1, target.y + 1, target.z + 1);
        [scene.cameraNode lookAt:target];
        scene.cameraNode.camera.orthographicScale = detail ? .075 : .32;
        CGSize size = detail ? CGSizeMake(1000, 600) : CGSizeMake(1200, 800);
        NSImage *image = [renderer snapshotAtTime:2.016 withSize:size antialiasingMode:SCNAntialiasingModeMultisampling4X];
        NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
        NSString *name = detail ? @"flipper-pivot-detail.png" : @"lower-hardware-isometry.png";
        PBRequire([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:name] atomically:YES], @"plate/tube and small pivot isometric capture");
    }
    scene.cameraNode.simdTransform = camera; scene.cameraNode.camera.orthographicScale = scale;
}

static void PBExportSlingshotFlare(PBTableScene *scene, SCNRenderer *renderer, PBTableDefinition *table, NSString *output) {
    if (!table.slingshots.count) return;
    PBGame *trial = [[PBGame alloc] initWithTable:table highScore:0];
    NSMutableArray<NSNumber *> *balls = [NSMutableArray array];
    for (PBEdgeDef *sling in table.slingshots) {
        simd_float2 edge = sling.b - sling.a;
        simd_float2 normal = simd_normalize(simd_make_float2(-edge.y, edge.x));
        NSInteger ball = [trial.world spawnBallAtPlunger];
        PBRequire(ball >= 0, @"slingshot flare fixture ball");
        [balls addObject:@(ball)];
        [trial.world placeBall:ball at:(sling.a + sling.b) * .5f + normal * (table.ballRadius + .007f) velocity:-normal * 2];
    }
    [trial.world advanceOneTick];
    for (NSUInteger i = 0; i < table.slingshots.count; i++) PBRequire([trial.world slingFlash:i] < .002f, @"flare triggered by a real slingshot collision");
    for (NSNumber *ball in balls) [trial.world removeBall:ball.integerValue];
    [scene syncWithGame:trial elapsed:1.0 / 960];
    SCNVector3 camera = scene.cameraNode.position;
    CGFloat scale = scene.cameraNode.camera.orthographicScale;
    for (NSInteger phase = 0; phase < 3; phase++) {
        [scene syncWithGame:trial elapsed:phase ? 160.0 / 960 : 0];
        scene.cameraNode.camera.orthographicScale = .28;
        scene.cameraNode.position = SCNVector3Make((table.flippers[0].pivot.x + table.flippers[1].pivot.x) * .5f - table.size.x * .5f, camera.y,
            table.size.y * .5f - .43f + camera.y * tanf(PBTableCameraTilt * (float)M_PI / 180));
        NSImage *image = [renderer snapshotAtTime:2.02 + phase * 160.0 / 960 withSize:CGSizeMake(1000, 680) antialiasingMode:SCNAntialiasingModeMultisampling4X];
        NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
        NSString *name = phase == 0 ? @"slingshot-flare-peak.png" : phase == 1 ? @"slingshot-flare-mid.png" : @"slingshot-flare-centres.png";
        PBRequire([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:name] atomically:YES], @"slingshot flare centre export");
        for (NSInteger tick = 0; tick < 160; tick++) [trial.world advanceOneTick];
    }
    scene.cameraNode.position = camera; scene.cameraNode.camera.orthographicScale = scale;
    NSLog(@"Rendered real slingshot impact flare peak and decay phases %@", output);
}

static void PBCheckFixedShadows(PBTableScene *scene) {
    SCNNode *key = [scene.scene.rootNode childNodeWithName:@"lighting.key" recursively:YES];
    PBRequire(key.light.castsShadow && [key.light.type isEqualToString:SCNLightTypeDirectional], @"fixed directional shadow light");
    PBRequire(!key.light.automaticallyAdjustsShadowProjection && key.light.shadowCascadeCount == 1, @"one manually fitted shadow projection");
    PBRequire(CGSizeEqualToSize(key.light.shadowMapSize, CGSizeMake(4096, 2048)), @"4096x2048 shadow map (hard cap)");
    PBRequire(![scene.scene.rootNode childNodeWithName:@"lighting.rig" recursively:YES], @"no device-driven lighting rig");
}

static void PBExportShadowComparison(PBTableScene *scene, SCNRenderer *renderer, NSString *output, NSString *name) {
    SCNNode *key = [scene.scene.rootNode childNodeWithName:@"lighting.key" recursively:YES];
    CGSize high = key.light.shadowMapSize;
    // Same light, projection and camera: this pair isolates map resolution.
    key.light.shadowMapSize = CGSizeMake(2048, 1024);
    PBExport(renderer, 2.016, [output stringByAppendingPathComponent:[name stringByAppendingString:@"-shadows-2k.png"]]);
    key.light.shadowMapSize = high;
    PBExport(renderer, 2.016, [output stringByAppendingPathComponent:[name stringByAppendingString:@"-shadows-4k.png"]]);
    key.light.castsShadow = NO;
    PBExport(renderer, 2.016, [output stringByAppendingPathComponent:[name stringByAppendingString:@"-shadows-off.png"]]);
    key.light.castsShadow = YES;
}

// Exercise the actual GPU shadow projection across the otherwise empty upper board.
// These raised test spheres exist only during QA and are removed before returning.
static void PBCheckRenderedShadowCoverage(PBTableScene *scene, SCNRenderer *renderer, PBTableDefinition *table, NSString *output) {
    SCNNode *key = [scene.scene.rootNode childNodeWithName:@"lighting.key" recursively:YES];
    SCNNode *fixture = [SCNNode node];
    NSMutableArray<NSValue *> *receivers = [NSMutableArray array];
    const CGSize view = {402, 402 * 2.168};
    simd_float3 toward = key.simdWorldTransform.columns[2].xyz;
    const float height = .08f;
    for (NSInteger row = 0; row < 4; row++) for (NSInteger column = 0; column < 5; column++) {
        CGPoint screen = CGPointMake(view.width * (.08 + .20 * column), view.height * (.08 + .19 * row));
        simd_float2 p = PBTablePointFromScreen(table.size, view, 59, 34, screen, height);
        SCNSphere *sphere = [SCNSphere sphereWithRadius:.018];
        sphere.firstMaterial.lightingModelName = SCNLightingModelLambert;
        sphere.firstMaterial.diffuse.contents = NSColor.whiteColor;
        SCNNode *node = [SCNNode nodeWithGeometry:sphere];
        node.position = [scene worldPointAt:p height:height];
        [fixture addChildNode:node];
        simd_float2 receiver = p + simd_make_float2(-toward.x, toward.z) * height / toward.y;
        SCNVector3 point = [scene worldPointAt:receiver height:0];
        [receivers addObject:[NSValue valueWithSCNVector3:point]];
    }
    [scene.scene.rootNode addChildNode:fixture];
    PBExport(renderer, 2.016, [output stringByAppendingPathComponent:@"shadow-coverage.png"]);
    NSImage *on = [renderer snapshotAtTime:2.016 withSize:CGSizeMake(804, 1743) antialiasingMode:SCNAntialiasingModeMultisampling4X];
    key.light.castsShadow = NO;
    NSImage *off = [renderer snapshotAtTime:2.016 withSize:CGSizeMake(804, 1743) antialiasingMode:SCNAntialiasingModeMultisampling4X];
    key.light.castsShadow = YES;
    [fixture removeFromParentNode];
    NSBitmapImageRep *a = [NSBitmapImageRep imageRepWithData:on.TIFFRepresentation];
    NSBitmapImageRep *b = [NSBitmapImageRep imageRepWithData:off.TIFFRepresentation];
    simd_float4x4 projection = SCNMatrix4ToMat4([scene.cameraNode.camera projectionTransformWithViewportSize:CGSizeMake(804, 1743)]);
    simd_float4x4 camera = simd_inverse(scene.cameraNode.simdWorldTransform);
    for (NSValue *value in receivers) {
        SCNVector3 point = value.SCNVector3Value;
        simd_float4 clip = simd_mul(projection, simd_mul(camera, simd_make_float4(point.x, point.y, point.z, 1)));
        NSInteger x = lround((clip.x / clip.w + 1) * 402), y = lround((1 - clip.y / clip.w) * 871.5);
        CGFloat difference = 0;
        for (NSInteger dy = -2; dy <= 2; dy++) for (NSInteger dx = -2; dx <= 2; dx++) {
            NSColor *lit = [[b colorAtX:x + dx y:y + dy] colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
            NSColor *shadow = [[a colorAtX:x + dx y:y + dy] colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
            difference = MAX(difference, lit.redComponent + lit.greenComponent + lit.blueComponent -
                shadow.redComponent - shadow.greenComponent - shadow.blueComponent);
        }
        PBRequire(difference > .06, [NSString stringWithFormat:@"GPU shadow missing at display point %ld,%ld", (long)x, (long)y]);
    }
    NSLog(@"Verified 20 rendered shadow receivers across the screen with a 4096x2048 map");
}

// Same geometry, camera and lamp sprites: only actual omni lights change between these frames.
static void PBCheckLocalLighting(PBTableScene *scene, SCNRenderer *renderer, NSString *output, NSString *name) {
    NSMutableArray<SCNLight *> *lights = [NSMutableArray array];
    NSMutableArray<NSNumber *> *levels = [NSMutableArray array];
    __block BOOL responsiveMetal = NO;
    [scene.scene.rootNode enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
        if ([node.light.type isEqualToString:SCNLightTypeOmni]) {
            [lights addObject:node.light]; [levels addObject:@(node.light.intensity)];
        }
        for (SCNMaterial *material in node.geometry.materials) {
            if ([material valueForKey:@"pbMatcap"]) {
                PBRequire(![material.lightingModelName isEqualToString:SCNLightingModelConstant], @"metal must receive local light");
                responsiveMetal = YES;
            }
        }
    }];
    PBRequire(responsiveMetal && lights.count >= 3, @"missing metal or local lights");
    for (SCNLight *light in lights) light.intensity = 0;
    PBExport(renderer, 3.0, [output stringByAppendingPathComponent:[name stringByAppendingString:@"-local-off.png"]]);
    for (SCNLight *light in lights) light.intensity = 90;
    PBExport(renderer, 3.0, [output stringByAppendingPathComponent:[name stringByAppendingString:@"-local-on.png"]]);
    for (NSUInteger i = 0; i < lights.count; i++) lights[i].intensity = levels[i].doubleValue;
}

// Freeze the physics fixture and animate the real deck materials and attract lamps.
static void PBExportRampChase(PBTableScene *scene, SCNRenderer *renderer, PBGame *game, NSString *path) {
    [game.world removeAllPlayBalls];
    NSInteger ball = [game.world spawnBallAtPlunger];
    [game.world placeBall:ball at:simd_make_float2(.4775f, .13f) velocity:simd_make_float2(0, 0)];
    for (int i = 0; i < 30; i++) [scene syncWithGame:game elapsed:.03];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("com.compuserve.gif"), 16, NULL);
    PBRequire(destination != NULL, @"could not create ramp chase preview");
    NSDictionary *properties = @{(__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFLoopCount: @0}};
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)properties);
    NSDictionary *frameProperties = @{(__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFDelayTime: @.045}};
    NSMutableSet *states = [NSMutableSet set];
    __block SCNMaterial *first = nil;
    NSMutableDictionary<NSString *, SCNMaterial *> *decks = [NSMutableDictionary dictionary];
    NSMutableSet *activeGroups = [NSMutableSet set];
    [scene.scene.rootNode enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
        for (SCNMaterial *material in node.geometry.materials) {
            if ([material.name hasPrefix:@"ramp_step_"]) decks[material.name] = material;
            if ([material.name isEqualToString:@"ramp_step_0"]) first = material;
        }
    }];
    __block BOOL endArrows = NO;
    [scene.scene.rootNode enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
        for (SCNMaterial *material in node.geometry.materials) if ([material.name isEqualToString:@"channel_arrow"]) endArrows = YES;
    }];
    PBRequire(first != nil || endArrows, @"missing channel arrows");
    for (int i = 0; i < 16; i++) {
        @autoreleasepool {
            [scene syncWithGame:game elapsed:.045];
            if (first) [states addObject:first.diffuse.contents];
            for (SCNMaterial *deck in decks.allValues) if (deck.emission.intensity > 1) [activeGroups addObject:deck.name];
            NSImage *image = [renderer snapshotAtTime:6.0 + i * .045 withSize:CGSizeMake(512, 1110) antialiasingMode:SCNAntialiasingModeMultisampling4X];
            CGImageRef frame = [image CGImageForProposedRect:NULL context:nil hints:nil];
            CGImageDestinationAddImage(destination, frame, (__bridge CFDictionaryRef)frameProperties);
        }
    }
    if (first) PBRequire(states.count == 2 && activeGroups.count == 4, @"chase did not visit all four authored phases");
    PBRequire(CGImageDestinationFinalize(destination), @"ramp chase GIF failed");
    CFRelease(destination);
    NSLog(@"Verified channel arrows and exported lamp animation %@", path);
}

// Normal-speed capture through the same game-update/scene-sync path as iPhone.
// GIF stores delays in centiseconds: use 50 Hz for an exact 0.02 s playback
// interval rather than claiming a rounded GIF delay is a true 60 Hz video.
static void PBExportBallRealtime(PBTableScene *scene, SCNRenderer *renderer, PBTableDefinition *table, NSString *output) {
    PBGame *trial = [[PBGame alloc] initWithTable:table highScore:0];
    [trial requestNewGame]; [trial update:0];
    [trial.world removeAllPlayBalls];
    NSInteger ball = [trial.world spawnBallAtPlunger];
    [trial.world placeBall:ball at:simd_make_float2(.83f, 1) velocity:simd_make_float2(2.4f, 0)];
    CGFloat scale = scene.cameraNode.camera.orthographicScale;
    const NSInteger frames = 60;
    CGImageDestinationRef destinations[2];
    NSArray *names = @[@"ball-realtime.gif", @"ball-realtime-closeup.gif"];
    for (NSInteger view = 0; view < 2; view++) {
        destinations[view] = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:[output stringByAppendingPathComponent:names[view]]], CFSTR("com.compuserve.gif"), frames, NULL);
        PBRequire(destinations[view] != NULL, @"normal-speed animation destination");
        CGImageDestinationSetProperties(destinations[view], (__bridge CFDictionaryRef)@{
            (__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFLoopCount: @0}});
    }
    NSDictionary *properties = @{(__bridge id)kCGImagePropertyGIFDictionary: @{
        (__bridge id)kCGImagePropertyGIFDelayTime: @.02,
        (__bridge id)kCGImagePropertyGIFUnclampedDelayTime: @.02}};
    NSInteger squeezedFrames = 0;
    for (NSInteger frame = 0; frame < frames; frame++) {
        @autoreleasepool {
            [trial update:.02];
            [scene syncWithGame:trial elapsed:.02];
            SCNVector3 gameplayCamera = scene.cameraNode.position;
            scene.cameraNode.camera.orthographicScale = scale;
            simd_float3x3 shape = PBSoftBallShape([trial.world softBallAtIndex:ball]);
            if (PBSoftBallSupport(shape, simd_make_float3(1, 0, 0)) < .91f) squeezedFrames++;
            for (NSInteger view = 0; view < 2; view++) {
                if (view == 1) {
                    simd_float2 p = trial.world.balls[ball].position;
                    scene.cameraNode.camera.orthographicScale = .22;
                    scene.cameraNode.position = SCNVector3Make(p.x - table.size.x * .5f, gameplayCamera.y,
                        table.size.y * .5f - p.y + gameplayCamera.y * tanf(PBTableCameraTilt * (float)M_PI / 180));
                }
                NSImage *image = [renderer snapshotAtTime:8 + frame * .02 withSize:view ? CGSizeMake(512, 512) : CGSizeMake(402, 872) antialiasingMode:SCNAntialiasingModeMultisampling4X];
                CGImageRef pixels = [image CGImageForProposedRect:NULL context:nil hints:nil];
                CGImageDestinationAddImage(destinations[view], pixels, (__bridge CFDictionaryRef)properties);
                if (view == 0 && frame == 3) {
                    NSBitmapImageRep *still = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
                    PBRequire([[still representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:@"ball-realtime-impact.png"] atomically:YES], @"gameplay-size impact export");
                }
            }
            scene.cameraNode.position = gameplayCamera;
        }
    }
    for (NSInteger view = 0; view < 2; view++) {
        PBRequire(CGImageDestinationFinalize(destinations[view]), @"normal-speed ball animation export");
        CFRelease(destinations[view]);
    }
    scene.cameraNode.camera.orthographicScale = scale;
    PBRequire(squeezedFrames >= 4, @"ordinary impact stays visibly squeezed in normal-speed gameplay frames");
    NSLog(@"Verified real-time game-update/render capture, %ld visibly squeezed frames at 50 Hz (no slow motion)", (long)squeezedFrames);
}

// Slow-motion capture of a real collision with the existing shooter wall.
static void PBExportBallDeformation(PBTableScene *scene, SCNRenderer *renderer, PBTableDefinition *table, NSString *output) {
    PBGame *trial = [[PBGame alloc] initWithTable:table highScore:0];
    NSInteger ball = [trial.world spawnBallAtPlunger];
    [trial.world placeBall:ball at:simd_make_float2(.83f, 1.0f) velocity:simd_make_float2(2.4f, 0)];
    SCNVector3 camera = scene.cameraNode.position;
    CGFloat scale = scene.cameraNode.camera.orthographicScale;
    scene.cameraNode.camera.orthographicScale = .22;
    SCNVector3 closeCamera = SCNVector3Make(.72f - table.size.x * .5f, camera.y,
        table.size.y * .5f - 1.02f + camera.y * tanf(PBTableCameraTilt * (float)M_PI / 180.0f));
    NSString *path = [output stringByAppendingPathComponent:@"ball-deformation.gif"];
    const NSInteger frames = 72;
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("com.compuserve.gif"), frames, NULL);
    PBRequire(destination != NULL, @"could not create rubber-ball animation");
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{
        (__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFLoopCount: @0}});
    NSDictionary *properties = @{(__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFDelayTime: @(1.0 / 30)}};
    float minimum = 1;
    BOOL rebound = NO;
    for (NSInteger frame = 0; frame < frames; frame++) {
        @autoreleasepool {
            [scene syncWithGame:trial elapsed:1.0 / 120];
            // syncWithGame restores the gameplay camera (including shake).
            scene.cameraNode.position = closeCamera;
            SCNNode *visual = [scene.scene.rootNode childNodeWithName:[NSString stringWithFormat:@"ball.visual.%ld", (long)ball] recursively:YES];
            simd_float3 position = visual.simdWorldPosition;
            simd_float4x4 projection = SCNMatrix4ToMat4([scene.cameraNode.camera projectionTransformWithViewportSize:CGSizeMake(512, 512)]);
            simd_float4 clip = simd_mul(projection, simd_mul(simd_inverse(scene.cameraNode.simdWorldTransform), simd_make_float4(position, 1)));
            PBRequire(!visual.hidden && fabsf(clip.x / clip.w) < .9f && fabsf(clip.y / clip.w) < .9f, @"rubber ball remains visible throughout the actual close-up");
            simd_float3x3 shape = PBSoftBallShape([trial.world softBallAtIndex:ball]);
            float extent = PBSoftBallSupport(shape, simd_make_float3(1, 0, 0));
            minimum = MIN(minimum, extent);
            rebound |= extent > 1.01f;
            NSImage *image = [renderer snapshotAtTime:4.0 + frame / 120.0 withSize:CGSizeMake(512, 512) antialiasingMode:SCNAntialiasingModeMultisampling4X];
            CGImageRef pixels = [image CGImageForProposedRect:NULL context:nil hints:nil];
            CGImageDestinationAddImage(destination, pixels, (__bridge CFDictionaryRef)properties);
            if (frame == 0 || frame == 4 || frame == 13 || frame == frames - 1) {
                NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
                NSString *still = [output stringByAppendingFormat:@"/ball-deformation-%02ld.png", (long)frame];
                PBRequire([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:still atomically:YES], @"ball deformation still export");
                if (frame == 13) {
                    PBRequire([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:@"ball-material-rubber.png"] atomically:YES], @"rubber material comparison export");
                    SCNMaterial *rubber = visual.geometry.firstMaterial;
                    SCNMaterial *previous = [rubber copy];
                    previous.roughness.contents = @.30;
                    previous.clearCoat.contents = @.35;
                    previous.clearCoatRoughness.contents = @.24;
                    previous.normal.contents = nil;
                    visual.geometry.firstMaterial = previous;
                    NSImage *before = [renderer snapshotAtTime:4.0 + frame / 120.0 withSize:CGSizeMake(512, 512) antialiasingMode:SCNAntialiasingModeMultisampling4X];
                    NSBitmapImageRep *old = [NSBitmapImageRep imageRepWithData:before.TIFFRepresentation];
                    PBRequire([[old representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingPathComponent:@"ball-material-before.png"] atomically:YES], @"previous material comparison export");
                    visual.geometry.firstMaterial = rubber;
                }
            }
            for (NSInteger tick = 0; tick < 8; tick++) [trial.world advanceOneTick];
        }
    }
    PBRequire(CGImageDestinationFinalize(destination), @"rubber-ball animation export");
    CFRelease(destination);
    PBRequire(minimum < .85f && rebound, @"real wall contact squashes then elastically stretches the ball");
    scene.cameraNode.position = camera;
    scene.cameraNode.camera.orthographicScale = scale;
    NSLog(@"Verified and exported real rubber-ball impact (4x slow motion), minimum normal extent %.3f", minimum);
}

static void PBExportGatePhysics(PBTableScene *scene, SCNRenderer *renderer, PBTableDefinition *table, NSString *output) {
    if (!table.gates.count) return;
    PBEdgeDef *gate = table.gates[0];
    PBGateGeometry geometry = PBGateGeometryMake(table.ballRadius);
    PBGame *trial = [[PBGame alloc] initWithTable:table highScore:0];
    NSInteger ball = [trial.world spawnBallAtPlunger];
    [trial.world setPlungerPulled:YES];
    for (int i = 0; i < 960; i++) [trial.world advanceOneTick];
    [trial.world setPlungerPulled:NO];
    simd_float2 edge = gate.b - gate.a;
    simd_float2 normal = simd_normalize(simd_make_float2(-edge.y, edge.x));
    if (simd_dot(normal, gate.passDirection) < 0) normal = -normal;
    for (int i = 0; i < 960 && simd_dot(trial.world.balls[ball].position - gate.a, normal) < -.12f; i++) [trial.world advanceOneTick];
    SCNVector3 camera = scene.cameraNode.position;
    CGFloat scale = scene.cameraNode.camera.orthographicScale;
    simd_float2 centre = (gate.a + gate.b) * .5f;
    SCNVector3 closeCamera = SCNVector3Make(centre.x - table.size.x * .5f, camera.y,
        table.size.y * .5f - centre.y + camera.y * tanf(PBTableCameraTilt * (float)M_PI / 180.0f));
    scene.cameraNode.camera.orthographicScale = .20;
    NSString *path = [output stringByAppendingPathComponent:@"shooter-gate.gif"];
    const NSInteger frames = 48;
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("com.compuserve.gif"), frames, NULL);
    PBRequire(destination != NULL, @"could not create gate physics animation");
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{(__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFLoopCount: @0}});
    BOOL open = NO;
    for (NSInteger frame = 0; frame < frames; frame++) {
        @autoreleasepool {
            [scene syncWithGame:trial elapsed:1.0 / 120];
            scene.cameraNode.position = closeCamera;
            float angle = [trial.world gateAngle:0];
            SCNNode *bar = [scene.scene.rootNode childNodeWithName:[@"gate.bar." stringByAppendingString:gate.identifier] recursively:YES];
            simd_float2 tip = PBGateTip(gate.a, gate.b, gate.passDirection, angle);
            simd_float2 at = (gate.a + tip) * .5f;
            float height = geometry.barHeight;
            SCNVector3 expected = [scene worldPointAt:at height:height];
            PBRequire(simd_distance(bar.simdWorldPosition, simd_make_float3(expected.x, expected.y, expected.z)) < 1e-5f, @"drawn gate bar matches the moving physical collider");
            SCNNode *pivot = [scene.scene.rootNode childNodeWithName:[@"gate.pivot." stringByAppendingString:gate.identifier] recursively:YES];
            SCNVector3 fixed = [scene worldPointAt:gate.a height:height];
            PBRequire(simd_distance(pivot.simdWorldPosition, simd_make_float3(fixed.x, fixed.y, fixed.z)) < 1e-5f, @"door hinge never moves or rises");
            SCNVector3 end = [bar convertPosition:SCNVector3Make(0, -simd_length(edge) * .5f, 0) toNode:scene.scene.rootNode];
            SCNVector3 expectedEnd = [scene worldPointAt:tip height:height];
            PBRequire(simd_distance(simd_make_float3(end.x, end.y, end.z), simd_make_float3(expectedEnd.x, expectedEnd.y, expectedEnd.z)) < 1e-5f, @"moving end of the mesh matches the rotating collider");
            if (angle > 1.4f) {
                open = YES;
                PBRequire(simd_dot(tip - gate.a, edge) / simd_length_squared(edge) < .2f, @"door rotates around its hinge instead of rising parallel to itself");
            }
            NSImage *image = [renderer snapshotAtTime:7.0 + frame / 120.0 withSize:CGSizeMake(512, 512) antialiasingMode:SCNAntialiasingModeMultisampling4X];
            CGImageRef pixels = [image CGImageForProposedRect:NULL context:nil hints:nil];
            NSDictionary *properties = @{(__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFDelayTime: @(frame % 3 == 2 ? .04 : .03)}};
            CGImageDestinationAddImage(destination, pixels, (__bridge CFDictionaryRef)properties);
            if (frame == 0 || frame == 6 || frame == 14 || frame == 47) {
                NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
                PBRequire([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[output stringByAppendingFormat:@"/shooter-gate-%02ld.png", (long)frame] atomically:YES], @"gate still export");
            }
            for (int tick = 0; tick < 8; tick++) [trial.world advanceOneTick];
        }
    }
    PBRequire(CGImageDestinationFinalize(destination), @"gate animation export failed"); CFRelease(destination);
    PBRequire(open && [trial.world gateAngle:0] < .01f, @"gate opens for a real plunge then closes to its stop");
    scene.cameraNode.position = camera; scene.cameraNode.camera.orthographicScale = scale;
    NSLog(@"Verified fixed shooter-gate hinge, planar rotation, endpoint alignment and closing");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || argc > 5 || (argc == 5 && strcmp(argv[4], "--shadow-compare") != 0 && strcmp(argv[4], "--ball-deformation") != 0 && strcmp(argv[4], "--ball-realtime") != 0 && strcmp(argv[4], "--gate-physics") != 0)) {
            fprintf(stderr, "usage: render_preview resource-bundle output-directory [skin] [--shadow-compare|--ball-deformation|--ball-realtime|--gate-physics]\n");
            return 2;
        }
        [NSApplication sharedApplication];
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        PBRequire(bundle != nil, @"invalid resource bundle");
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        [[NSFileManager defaultManager] createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:NULL];
        NSError *error;
        NSString *tableName = NSProcessInfo.processInfo.environment[@"PB_PREVIEW_TABLE"] ?: @"aurora";
        PBTableDefinition *table = [PBTableDefinition tableNamed:tableName bundle:bundle error:&error];
        // Aurora's previews keep their plain skin names.
        NSString *prefix = [tableName isEqualToString:@"aurora"] ? @"" : [tableName stringByAppendingString:@"-"];
        PBRequire(table != nil, error.description ?: @"missing table");
        NSArray<NSString *> *names = [PBSkin availableSkinsInBundle:bundle];
        PBRequire([names containsObject:@"orbital"] && [names containsObject:@"abyss"], @"missing new skins");
        PBRequire(![names containsObject:@"orbital-playfield"] && ![names containsObject:@"abyss-playfield"], @"source images in skin selector");
        NSArray *required = @[@"playfield", @"bumper_cap", @"slingshot", @"wall_top", @"side_rail", @"flipper", @"ramp",
                              @"plastic", @"drop_target", @"standup", @"spinner", @"gate", @"environment", @"inserts", @"dmd_bezel", @"detail"];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        PBRequire(device != nil, @"Metal device unavailable");
        for (NSString *name in names) {
            @autoreleasepool {
                PBSkin *skin = [PBSkin skinNamed:name bundle:bundle];
                PBRequire(skin != nil, [@"invalid skin: " stringByAppendingString:name]);
                for (NSString *slot in required) {
                    CGImageRef image = [skin imageForSlot:slot];
                    PBRequire(image && CGImageGetWidth(image) > 0 && CGImageGetHeight(image) > 0, slot);
                }
                for (NSInteger i = 0; i < 16; i++) PBRequire([skin insertIcon:i] != nil, @"invalid insert crop");
                BOOL premium = [name isEqualToString:@"orbital"] || [name isEqualToString:@"abyss"];
                if (premium) PBRequire([skin hasImageForSlot:@"bumper_cap_lit"], @"missing authored state");
                if (argc > 3 && ![name isEqualToString:[NSString stringWithUTF8String:argv[3]]]) continue;

                PBGame *game = [[PBGame alloc] initWithTable:table highScore:1250000];
                PBTableScene *scene = [[PBTableScene alloc] initWithTable:table skin:skin];
                [game addObserver:scene];
                [scene fitCameraToAspect:2.168];
                SCNRenderer *renderer = [SCNRenderer rendererWithDevice:device options:nil];
                renderer.scene = scene.scene;
                renderer.pointOfView = scene.cameraNode;
                for (int i = 0; i < 120; i++) {
                    [game update:1.0 / 60.0];
                    [scene syncWithGame:game elapsed:1.0 / 60.0];
                }
                // Warm pipeline, then export at the same 2x scale as a phone screenshot.
                [renderer snapshotAtTime:2.0 withSize:CGSizeMake(804, 1743) antialiasingMode:SCNAntialiasingModeMultisampling4X];
                NSString *path = [output stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.png", prefix, name]];
                PBExport(renderer, 2.016, path);
                if (premium) {
                    PBExportChannelWalls(scene, renderer, table, [output stringByAppendingPathComponent:[name stringByAppendingString:@"-channels.png"]]);
                    PBCheckFixedShadows(scene);
                    PBExportSlingshotFasteners(scene, renderer, table, output);
                    PBExportLowerLanes(scene, renderer, table, output, @"lower-lanes-equal.png");
                    SCNLight *guideKey = [scene.scene.rootNode childNodeWithName:@"lighting.key" recursively:YES].light;
                    CGFloat keyIntensity = guideKey.intensity;
                    guideKey.intensity = 0;
                    PBExportLowerLanes(scene, renderer, table, output, @"lower-guides-fill-only.png");
                    guideKey.intensity = keyIntensity;
                    PBExportHardwareConstruction(scene, renderer, table, output);
                    PBExportSlingshotFlare(scene, renderer, table, output);
                    if (argc > 4 && strcmp(argv[4], "--gate-physics") == 0) PBExportGatePhysics(scene, renderer, table, output);
                    if (argc > 4 && strcmp(argv[4], "--ball-deformation") == 0) PBExportBallDeformation(scene, renderer, table, output);
                    if (argc > 4 && strcmp(argv[4], "--ball-realtime") == 0) PBExportBallRealtime(scene, renderer, table, output);
                    if (argc > 4 && strcmp(argv[4], "--shadow-compare") == 0) {
                        PBExportShadowComparison(scene, renderer, output, name);
                        PBCheckRenderedShadowCoverage(scene, renderer, table, output);
                    }
                }
                // The hit, idle and chase checks need two bumpers to compare; a bare board has none.
                if (premium && table.bumpers.count >= 2) {
                    SCNNode *cap = [scene.scene.rootNode childNodeWithName:[@"bumper." stringByAppendingString:table.bumpers[0].identifier] recursively:YES];
                    __block SCNGeometry *painted = cap.geometry;
                    [cap enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
                        if ([node.geometry.name isEqualToString:@"cap_art"]) painted = node.geometry;
                    }];
                    SCNMaterial *idle = painted.firstMaterial;
                    SCNNode *otherCap = [scene.scene.rootNode childNodeWithName:[@"bumper." stringByAppendingString:table.bumpers[1].identifier] recursively:YES];
                    __block SCNGeometry *otherPainted = otherCap.geometry;
                    [otherCap enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
                        if ([node.geometry.name isEqualToString:@"cap_art"]) otherPainted = node.geometry;
                    }];
                    SCNMaterial *otherIdle = otherPainted.firstMaterial;
                    PBRequire(idle != nil, @"missing bumper node");
                    if (skin.modelKit) {
                        PBRequire(cap.childNodes.count >= 3, @"bumper kit failed to load");
                        for (PBRampDef *ramp in table.ramps) {
                            PBRequire([scene.scene.rootNode childNodeWithName:ramp.model ?: [NSString stringWithFormat:@"%@-%@", table.identifier, ramp.identifier] recursively:YES] != nil, @"compiled ramp failed to load");
                        }
                    }
                    [game setLeftPressed:YES];
                    [game update:1.0 / 60.0];
                    [game setLeftPressed:NO];
                    [game.world removeAllPlayBalls];
                    NSInteger ball = [game.world spawnBallAtPlunger];
                    PBRequire(ball >= 0, @"could not create state-test ball");
                    PBSpotDef *bumper = table.bumpers.firstObject;
                    [game.world placeBall:ball at:bumper.position - simd_make_float2(0, bumper.radius + table.ballRadius + 0.006f)
                                 velocity:simd_make_float2(0, 1.4f)];
                    [game update:1.0 / 60.0];
                    [scene syncWithGame:game elapsed:1.0 / 60.0];
                    PBRequire([game.world bumperFlash:0] < 0.02f, @"fixture missed bumper");
                    PBRequire(painted.firstMaterial != idle, @"bumper did not select authored hit artwork");
                    PBRequire(otherPainted.firstMaterial == otherIdle, @"bumper instances share animated geometry");
                    path = [output stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@-hit.png", prefix, name]];
                    PBExport(renderer, 2.05, path);
                    [game.world removeAllPlayBalls];
                    for (int i = 0; i < 30; i++) {
                        [game update:1.0 / 60.0];
                        [scene syncWithGame:game elapsed:1.0 / 60.0];
                    }
                    PBRequire(painted.firstMaterial == idle, @"bumper failed to return to idle artwork");
                    PBCheckLocalLighting(scene, renderer, output, name);
                    if (table.ramps.count > 0)
                        PBExportRampChase(scene, renderer, game, [output stringByAppendingPathComponent:[name stringByAppendingString:@"-chase.gif"]]);
                }
            }
        }
    }
    return 0;
}
