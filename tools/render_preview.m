// Render the actual SceneKit scene without playing or capturing another app.
// Build/run instructions are in Art/SKIN_GUIDE.md.
#import <AppKit/AppKit.h>
#import <SceneKit/SceneKit.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import "PBTableScene.h"
#import "PBLayoutValidator.h"

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

static void PBCheckTiltLighting(PBTableScene *scene, SCNRenderer *renderer, NSString *output, NSString *name) {
    SCNNode *key = [scene.scene.rootNode childNodeWithName:@"lighting.key" recursively:YES];
    SCNNode *rig = [scene.scene.rootNode childNodeWithName:@"lighting.rig" recursively:YES];
    PBRequire(key.light.castsShadow, @"tilt light must cast real shadows");
    simd_float3 neutralPosition = key.simdWorldPosition;
    simd_quatf left = simd_mul(simd_quaternion(0.38f, simd_make_float3(0, 1, 0)),
                              simd_quaternion(-0.18f, simd_make_float3(1, 0, 0)));
    [scene updateLightingForAttitude:left elapsed:1.0 / 60.0];
    float firstStep = simd_distance(key.simdWorldPosition, neutralPosition);
    for (int i = 0; i < 90; i++) [scene updateLightingForAttitude:left elapsed:1.0 / 60.0];
    float settledStep = simd_distance(key.simdWorldPosition, neutralPosition);
    PBRequire(firstStep > 0 && firstStep < settledStep * 0.5f && settledStep > 0.5f, @"tilt did not smoothly move the shadow light");
    PBExport(renderer, 3.0, [output stringByAppendingPathComponent:[name stringByAppendingString:@"-tilt-left.png"]]);
    simd_quatf right = simd_inverse(left);
    for (int i = 0; i < 90; i++) [scene updateLightingForAttitude:right elapsed:1.0 / 60.0];
    PBRequire(simd_distance(key.simdWorldPosition, neutralPosition) > 0.5f, @"opposite tilt did not move light");
    PBExport(renderer, 3.0, [output stringByAppendingPathComponent:[name stringByAppendingString:@"-tilt-right.png"]]);
    for (int i = 0; i < 90; i++) [scene updateLightingForAttitude:simd_quaternion(2.4f, simd_make_float3(0, 1, 0)) elapsed:1.0 / 60.0];
    PBRequire(simd_angle(rig.simdOrientation) <= 0.601f && key.simdWorldPosition.y > 0.8f, @"extreme tilt must keep light above table");
    simd_quatf previous = rig.simdOrientation;
    [scene updateLightingForAttitude:simd_quaternion(NAN, 0.0f, 0.0f, 1.0f) elapsed:1.0 / 60.0];
    [scene updateLightingForAttitude:simd_quaternion(0.0f, 0.0f, 0.0f, 0.0f) elapsed:1.0 / 60.0];
    PBRequire(simd_distance(previous.vector, rig.simdOrientation.vector) < 1e-5f, @"invalid motion sample corrupted light orientation");
    for (int i = 0; i < 90; i++) [scene updateLightingForAttitude:simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f) elapsed:1.0 / 60.0];
    PBRequire(simd_distance(key.simdWorldPosition, neutralPosition) < 0.001f, @"neutral grip did not restore lighting");
}

static void PBExportTiltAnimation(PBTableScene *scene, SCNRenderer *renderer, PBTableDefinition *table, NSString *path) {
    SCNVector3 camera = scene.cameraNode.position;
    CGFloat zoom = scene.cameraNode.camera.orthographicScale;
    simd_float2 centre = simd_make_float2(0, 0);
    for (PBSpotDef *bumper in table.bumpers) centre += bumper.position;
    centre /= (float)MAX(table.bumpers.count, 1);
    scene.cameraNode.camera.orthographicScale = 0.11;
    scene.cameraNode.position = SCNVector3Make(centre.x - table.size.x * 0.5f, camera.y,
                                               -(centre.y - table.size.y * 0.5f) + camera.y * tanf(PBTableCameraTilt * (float)M_PI / 180.0f));
    const int frames = 72;
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                       CFSTR("com.compuserve.gif"), frames, NULL);
    PBRequire(destination != NULL, @"could not create tilt animation");
    NSDictionary *properties = @{(__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFLoopCount: @0}};
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)properties);
    NSDictionary *frameProperties = @{(__bridge id)kCGImagePropertyGIFDictionary: @{(__bridge id)kCGImagePropertyGIFDelayTime: @(1.0 / 24.0)}};
    for (int i = 0; i < frames; i++) {
        @autoreleasepool {
            float phase = sinf((float)(2.0 * M_PI * i / frames));
            simd_quatf attitude = simd_mul(simd_quaternion(phase * 0.38f, simd_make_float3(0, 1, 0)),
                                          simd_quaternion(phase * -0.18f, simd_make_float3(1, 0, 0)));
            [scene updateLightingForAttitude:attitude elapsed:1.0 / 24.0];
            NSImage *image = [renderer snapshotAtTime:3.0 withSize:CGSizeMake(512, 512) antialiasingMode:SCNAntialiasingModeMultisampling4X];
            CGImageRef frame = [image CGImageForProposedRect:NULL context:nil hints:nil];
            CGImageDestinationAddImage(destination, frame, (__bridge CFDictionaryRef)frameProperties);
        }
    }
    PBRequire(CGImageDestinationFinalize(destination), @"tilt animation export failed");
    CFRelease(destination);
    scene.cameraNode.position = camera;
    scene.cameraNode.camera.orthographicScale = zoom;
    NSLog(@"Exported actual-scene tilt animation %@", path);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: render_preview resource-bundle output-directory [skin] [--tilt-animation]\n");
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
                    SCNNode *cap = [scene.scene.rootNode childNodeWithName:@"bumper.bumperA" recursively:YES];
                    __block SCNGeometry *painted = cap.geometry;
                    [cap enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
                        if ([node.geometry.name isEqualToString:@"cap_art"]) painted = node.geometry;
                    }];
                    SCNMaterial *idle = painted.firstMaterial;
                    SCNNode *otherCap = [scene.scene.rootNode childNodeWithName:@"bumper.bumperB" recursively:YES];
                    __block SCNGeometry *otherPainted = otherCap.geometry;
                    [otherCap enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
                        if ([node.geometry.name isEqualToString:@"cap_art"]) otherPainted = node.geometry;
                    }];
                    SCNMaterial *otherIdle = otherPainted.firstMaterial;
                    PBRequire(idle != nil, @"missing bumper node");
                    if (skin.modelKit) {
                        PBRequire(cap.childNodes.count >= 3, @"Blender bumper kit failed to load");
                        PBRequire([scene.scene.rootNode childNodeWithName:[NSString stringWithFormat:@"%@-%@", table.identifier, table.ramps.firstObject.identifier] recursively:YES] != nil, @"Blender ramp failed to load");
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
                    PBCheckTiltLighting(scene, renderer, output, name);
                    if (argc > 4 && strcmp(argv[4], "--tilt-animation") == 0) {
                        PBExportTiltAnimation(scene, renderer, table,
                            [output stringByAppendingPathComponent:[name stringByAppendingString:@"-tilt.gif"]]);
                    }
                }
            }
        }
    }
    return 0;
}
