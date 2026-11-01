//
//  PBTableScene.m
//

#import "PBTableScene.h"
#import "PBDotMatrix.h"
#import "PBGeometry.h"
#import "PBPlayfieldPainter.h"

static const CGFloat kFieldOfView = 44.0;

/// Samples a texture by world position, so the apron and playfield share one image and
/// any mesh can show painted art without its own UVs.
static NSString *PBWorldUVModifier(simd_float2 size) {
    return [NSString stringWithFormat:
            @"float4 pbWorld = scn_node.modelTransform * _geometry.position;\n"
            @"_geometry.texcoords[0] = float2(pbWorld.x / %f + 0.5, pbWorld.z / %f + 0.5);\n", size.x, size.y];
}

/// PBR can produce NaN or infinity at silhouette edges under a close light. One such pixel
/// becomes a black square once bloom downsamples it, so every PBR material filters them out.
static NSString *const kPBHDRGuard =
    @"float3 pbGuard = _output.color.rgb;\n"
    @"if (any(isnan(pbGuard)) || any(isinf(pbGuard))) pbGuard = float3(0.0);\n"
    @"_output.color.rgb = min(pbGuard, float3(6.0));\n";

/// SCNFloor ignores overridden texcoords, so the floor samples its art by world position
/// in a surface modifier instead.
static NSString *PBFloorSurfaceModifier(simd_float2 size) {
    return [NSString stringWithFormat:
            @"#pragma arguments\n"
            @"texture2d<float> pbPlayfield;\n"
            @"#pragma body\n"
            @"constexpr sampler pbSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear, max_anisotropy(8));\n"
            @"float3 pbP = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;\n"
            @"float2 pbUV = float2(pbP.x / %f + 0.5, pbP.z / %f + 0.5);\n"
            @"_surface.diffuse = pbPlayfield.sample(pbSampler, pbUV);\n", size.x, size.y];
}

/// Chrome ball that mirrors the playfield it actually sits over. A reflection ray that
/// hits the table is traced into the playfield texture, so the reflection moves correctly
/// with the ball. Rays going up keep SceneKit's environment reflection of the room.
static NSString *PBBallReflectionModifier(simd_float2 size) {
    return [NSString stringWithFormat:
            @"#pragma arguments\n"
            @"texture2d<float> pbPlayfield;\n"
            @"#pragma body\n"
            @"constexpr sampler pbSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);\n"
            @"float3 pbN = normalize((scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz);\n"
            @"float3 pbV = normalize((scn_frame.inverseViewTransform * float4(_surface.view, 0.0)).xyz);\n"
            @"float3 pbP = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;\n"
            @"float3 pbR = reflect(-pbV, pbN);\n"
            @"if (pbR.y < -0.03) {\n"
            @"  float pbT = -pbP.y / pbR.y;\n"
            @"  float2 pbHit = pbP.xz + pbR.xz * pbT;\n"
            @"  float2 pbUV = float2(pbHit.x / %f + 0.5, pbHit.y / %f + 0.5);\n"
            @"  float3 pbColor = pbPlayfield.sample(pbSampler, pbUV, level(2.0)).rgb;\n"
            @"  float pbAmount = smoothstep(0.03, 0.30, -pbR.y);\n"
            @"  _output.color.rgb = mix(_output.color.rgb, pbColor * 1.25, pbAmount * 0.92);\n"
            @"}\n%@", size.x, size.y, kPBHDRGuard];
}

@interface PBLampView : NSObject
@property (nonatomic, strong) SCNNode *node;
@property (nonatomic) float intensity;
@end
@implementation PBLampView @end

@interface PBFlasherView : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, strong) SCNLight *light;
@property (nonatomic, strong) SCNNode *glow;
@property (nonatomic, strong) SCNMaterial *dome;
@property (nonatomic) float level;
@end
@implementation PBFlasherView @end

@implementation PBTableScene {
    PBTableDefinition *_table;
    PBSkin *_skin;
    simd_float2 _size;
    CGImageRef _playfieldImage;
    SCNNode *_root;
    SCNCamera *_camera;
    CGFloat _baseCameraHeight;

    NSMutableArray<SCNNode *> *_ballNodes;
    NSMutableArray<SCNNode *> *_flipperNodes;
    NSMutableArray<SCNNode *> *_dropNodes;
    NSMutableArray<SCNNode *> *_spinnerPlates;
    NSMutableArray<SCNNode *> *_gatePlates;
    NSMutableArray<SCNMaterial *> *_bumperCaps;
    NSMutableArray<SCNNode *> *_slingBands;
    NSMutableArray<SCNNode *> *_standupNodes;
    NSMutableArray<PBLampView *> *_lamps;
    NSMutableArray<PBFlasherView *> *_flashers;
    SCNNode *_plungerRod;
    float _plungerRodBase;
    SCNLight *_bumperLight;
    NSMutableArray<SCNLight *> *_slingLights;
    PBDotMatrix *_dmd;
    NSMutableDictionary<NSString *, SCNMaterial *> *_litMaterials;

    double _clock;
    float _shake;
    uint32_t _shakeSeed;
}

- (instancetype)initWithTable:(PBTableDefinition *)table skin:(PBSkin *)skin {
    if ((self = [super init])) {
        _table = table;
        _skin = skin;
        _size = table.size;
        _scene = [SCNScene scene];
        _root = _scene.rootNode;
        _shakeSeed = 0x12345;
        _litMaterials = [NSMutableDictionary dictionary];

        _playfieldImage = [PBPlayfieldPainter newPlayfieldForTable:table skin:skin];

        [self buildCameraAndLights];
        [self buildPlayfield];
        [self buildCabinet];
        [self buildWalls];
        [self buildPosts];
        [self buildPlastics];
        [self buildBumpers];
        [self buildSlingshots];
        [self buildFlippers];
        [self buildTargets];
        [self buildSpinnersAndGates];
        [self buildRamps];
        [self buildLamps];
        [self buildFlashers];
        [self buildPlunger];
        [self buildApron];
        [self buildBalls];
    }
    return self;
}

- (void)dealloc { CGImageRelease(_playfieldImage); }

#pragma mark - Helpers

- (SCNVector3)at:(simd_float2)p height:(float)height { return PBScenePoint(_size, p.x, p.y, height); }

static inline CGColorRef PBCGColor(simd_float3 c) CF_RETURNS_RETAINED;
static inline CGColorRef PBCGColor(simd_float3 c) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat components[4] = { c.x, c.y, c.z, 1 };
    CGColorRef color = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    return color;
}

- (id)color:(simd_float3)c {
    return (__bridge_transfer id)PBCGColor(c);
}

- (SCNMaterial *)pbrWithDiffuse:(id)diffuse metalness:(CGFloat)metalness roughness:(CGFloat)roughness {
    SCNMaterial *material = [SCNMaterial material];
    material.lightingModelName = SCNLightingModelPhysicallyBased;
    material.diffuse.contents = diffuse;
    material.metalness.contents = @(metalness);
    material.roughness.contents = @(roughness);
    material.shaderModifiers = @{ SCNShaderModifierEntryPointFragment: kPBHDRGuard };
    return material;
}

- (SCNMaterial *)metal {
    return [self pbrWithDiffuse:[self color:_skin.metalColor] metalness:1.0 roughness:0.22];
}

- (SCNMaterial *)rubber {
    return [self pbrWithDiffuse:[self color:_skin.rubberColor] metalness:0.0 roughness:0.6];
}

- (SCNMaterial *)tileMaterial:(NSString *)slot metalness:(CGFloat)metalness roughness:(CGFloat)roughness {
    SCNMaterial *material = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:slot] metalness:metalness roughness:roughness];
    material.diffuse.wrapS = SCNWrapModeRepeat;
    material.diffuse.wrapT = SCNWrapModeRepeat;
    return material;
}

/// An additive, HDR sprite lying on the table: lit lamps, glows. Values above 1 feed the bloom.
- (SCNMaterial *)additiveMaterial:(CGImageRef)image intensity:(CGFloat)intensity {
    SCNMaterial *material = [SCNMaterial material];
    material.lightingModelName = SCNLightingModelConstant;
    material.diffuse.contents = (__bridge id)image;
    material.diffuse.intensity = intensity;
    material.blendMode = SCNBlendModeAdd;
    material.writesToDepthBuffer = NO;
    material.readsFromDepthBuffer = YES;
    return material;
}

- (SCNNode *)spriteOfSize:(float)size material:(SCNMaterial *)material {
    SCNPlane *plane = [SCNPlane planeWithWidth:size height:size];
    plane.firstMaterial = material;
    SCNNode *node = [SCNNode nodeWithGeometry:plane];
    node.eulerAngles = SCNVector3Make(-(float)M_PI_2, 0, 0);
    node.castsShadow = NO;
    return node;
}

- (SCNNode *)addNodeWithGeometry:(SCNGeometry *)geometry material:(SCNMaterial *)material {
    if (material) geometry.firstMaterial = material;
    SCNNode *node = [SCNNode nodeWithGeometry:geometry];
    [_root addChildNode:node];
    return node;
}

/// Prism from a table-space outline. The node's origin is the table origin at floor level.
- (SCNNode *)prismNodeWithGeometry:(SCNGeometry *)geometry height:(float)height baseHeight:(float)baseHeight {
    SCNNode *node = [SCNNode nodeWithGeometry:geometry];
    node.eulerAngles = SCNVector3Make(-(float)M_PI_2, 0, 0);
    node.position = PBScenePoint(_size, 0, 0, baseHeight + height * 0.5f);
    return node;
}

#pragma mark - Camera and lights

- (void)buildCameraAndLights {
    _camera = [SCNCamera camera];
    _camera.projectionDirection = SCNCameraProjectionDirectionVertical;
    _camera.fieldOfView = kFieldOfView;
    _camera.zNear = 0.1;
    _camera.zFar = 20.0;
    _camera.wantsHDR = YES;
    _camera.wantsExposureAdaptation = NO;
    _camera.exposureOffset = 0.0;
    _camera.bloomIntensity = 0.9;
    _camera.bloomThreshold = 1.25;
    _camera.bloomBlurRadius = 9.0;
    _camera.vignettingIntensity = 0.35;
    _camera.vignettingPower = 1.2;
    _camera.colorFringeStrength = 0.25;
    _camera.colorFringeIntensity = 0.35;
    // No screen-space ambient occlusion: it renders the whole frame black with this scene
    // in the simulator. PBPlayfieldPainter bakes contact shadows instead.

    _cameraNode = [SCNNode node];
    _cameraNode.camera = _camera;
    _cameraNode.eulerAngles = SCNVector3Make(-(float)M_PI_2, 0, 0);
    [_root addChildNode:_cameraNode];
    [self fitCameraToAspect:(CGFloat)_size.y / _size.x];

    // The skin's environment panel lights everything softly and fills chrome reflections.
    _scene.lightingEnvironment.contents = (__bridge id)[_skin imageForSlot:@"environment"];
    _scene.lightingEnvironment.intensity = _skin.ambient * 0.7f;
    _scene.background.contents = [self color:simd_make_float3(0.0f, 0.0f, 0.0f)];

    SCNLight *ambient = [SCNLight light];
    ambient.type = SCNLightTypeAmbient;
    ambient.intensity = 420.0f * _skin.ambient;
    ambient.color = [self color:simd_make_float3(0.92f, 0.92f, 1.0f)];
    SCNNode *ambientNode = [SCNNode node];
    ambientNode.light = ambient;
    [_root addChildNode:ambientNode];

    SCNLight *key = [SCNLight light];
    key.type = SCNLightTypeSpot;
    key.intensity = _skin.keyIntensity * 0.62f;
    key.color = [self color:_skin.keyColor];
    key.spotInnerAngle = 50;
    key.spotOuterAngle = 86;
    key.attenuationStartDistance = 0;
    key.attenuationEndDistance = 0;
    key.castsShadow = YES;
    key.shadowMapSize = CGSizeMake(2048, 2048);
    key.shadowSampleCount = 8;
    key.shadowRadius = 2.5;
    key.shadowColor = [self color:simd_make_float3(0.0f, 0.0f, 0.0f)];
    key.shadowBias = 2.0;
    key.zNear = 1.0;
    key.zFar = 8.0;
    SCNNode *keyNode = [SCNNode node];
    keyNode.light = key;
    // Off-axis, like a cabinet's lamps. Directly above, the mirror direction of every
    // up-facing surface would point into the overhead camera and wash the parts out.
    keyNode.position = SCNVector3Make(-2.2f, 2.9f, 1.4f);
    [keyNode lookAt:SCNVector3Make(0, 0, 0)];
    [_root addChildNode:keyNode];

    _bumperLight = [self addEffectLightAt:_table.bumpers.count ? _table.bumpers[0].position : simd_make_float2(0.5f, 1.5f) height:0.2f color:simd_make_float3(1.0f, 0.75f, 0.45f) range:0.7f];
    _slingLights = [NSMutableArray array];
    for (PBEdgeDef *sling in _table.slingshots) {
        [_slingLights addObject:[self addEffectLightAt:(sling.a + sling.b) * 0.5f height:0.14f color:simd_make_float3(1.0f, 0.9f, 0.8f) range:0.5f]];
    }
}

/// Always-on lights whose intensity animates. Toggling lights would force shader recompiles.
- (SCNLight *)addEffectLightAt:(simd_float2)position height:(float)height color:(simd_float3)color range:(float)range {
    SCNLight *light = [SCNLight light];
    light.type = SCNLightTypeOmni;
    light.color = [self color:color];
    light.intensity = 0;
    light.attenuationStartDistance = 0;
    light.attenuationEndDistance = range;
    light.attenuationFalloffExponent = 2.0;
    SCNNode *node = [SCNNode node];
    node.light = light;
    node.position = [self at:position height:height];
    [_root addChildNode:node];
    return light;
}

- (void)fitCameraToAspect:(CGFloat)heightOverWidth {
    CGFloat visibleHeight = MAX((CGFloat)_size.y, (CGFloat)_size.x * heightOverWidth);
    _baseCameraHeight = visibleHeight * 0.5 / tan(kFieldOfView * M_PI / 360.0);
    _cameraNode.position = SCNVector3Make(0, _baseCameraHeight, 0);
}

#pragma mark - Static table

- (void)buildPlayfield {
    // SCNFloor gives true planar reflections of everything above it: the polished
    // clear-coat look, with ball and bumpers mirrored in the playfield.
    SCNFloor *floor = [SCNFloor floor];
    floor.width = _size.x * 2.0f;
    floor.length = _size.y * 2.0f;
    floor.reflectivity = 0.28;
    floor.reflectionFalloffStart = 0.0;
    floor.reflectionFalloffEnd = 0.32;
    floor.reflectionResolutionScaleFactor = 0.75;

    // Lambert, not PBR: with the camera straight above, a specular highlight from the
    // overhead light would burn out the middle of the art. Gloss comes from the reflections.
    SCNMaterial *material = [SCNMaterial material];
    material.lightingModelName = SCNLightingModelLambert;
    material.diffuse.contents = [self color:simd_make_float3(1.0f, 1.0f, 1.0f)];
    material.shaderModifiers = @{ SCNShaderModifierEntryPointSurface: PBFloorSurfaceModifier(_size) };
    SCNMaterialProperty *art = [SCNMaterialProperty materialPropertyWithContents:(__bridge id)_playfieldImage];
    art.mipFilter = SCNFilterModeLinear;
    [material setValue:art forKey:@"pbPlayfield"];
    floor.firstMaterial = material;
    [self addNodeWithGeometry:floor material:nil];
}

- (void)buildCabinet {
    // A raised frame around the arch. Its outer edge runs off-screen, so the playfield
    // appears to fill the display edge to edge, inside a real cabinet.
    const float margin = 0.6f;
    PBBezierPath *path = [PBBezierPath bezierPath];
    path.flatness = 0.001;
    [path moveToPoint:CGPointMake(-margin, -margin)];
    PBBezierLineTo(path, CGPointMake(_size.x + margin, -margin));
    PBBezierLineTo(path, CGPointMake(_size.x + margin, _size.y + margin));
    PBBezierLineTo(path, CGPointMake(-margin, _size.y + margin));
    [path closePath];

    PBWallDef *outer = nil;
    for (PBWallDef *wall in _table.walls) if ([wall.identifier isEqualToString:@"outer"]) outer = wall;
    if (outer) {
        const simd_float2 *p = outer.points.points;
        NSInteger n = outer.points.count;
        [path moveToPoint:CGPointMake(p[0].x + outer.radius, -margin + 0.01)];
        for (NSInteger i = 0; i < n; i++) {
            // The outer wall runs counter-clockwise, so outward is to the right of travel.
            simd_float2 tangent = simd_normalize(p[MIN(i + 1, n - 1)] - p[MAX(i - 1, 0)]);
            simd_float2 away = simd_make_float2(tangent.y, -tangent.x);
            PBBezierLineTo(path, CGPointMake(p[i].x + away.x * outer.radius, p[i].y + away.y * outer.radius));
        }
        PBBezierLineTo(path, CGPointMake(p[n - 1].x - outer.radius, -margin + 0.01));
        [path closePath];
    }
#if TARGET_OS_IPHONE
    path.usesEvenOddFillRule = YES;
#else
    path.windingRule = NSWindingRuleEvenOdd;
#endif
    const float height = 0.11f;
    SCNGeometry *frame = [PBGeometry prismWithPath:path height:height chamfer:0.0f];
    SCNMaterial *rail = [self tileMaterial:@"side_rail" metalness:0.0 roughness:0.6];
    rail.shaderModifiers = @{ SCNShaderModifierEntryPointGeometry:
        @"float4 pbWorld = scn_node.modelTransform * _geometry.position;\n"
        @"_geometry.texcoords[0] = pbWorld.xz * 3.0;\n",
        SCNShaderModifierEntryPointFragment: kPBHDRGuard };
    frame.firstMaterial = rail;
    [_root addChildNode:[self prismNodeWithGeometry:frame height:height baseHeight:0.0f]];
}

- (void)buildWalls {
    SCNMaterial *wallMaterial = [self tileMaterial:@"wall_top" metalness:0.0 roughness:0.5];
    SCNMaterial *railMaterial = [self metal];
    SCNMaterial *rubberMaterial = [self rubber];
    SCNMaterial *plasticMaterial = [self tileMaterial:@"wall_top" metalness:0.0 roughness:0.4];

    for (PBWallDef *wall in _table.walls) {
        const simd_float2 *p = wall.points.points;
        NSInteger n = wall.points.count;
        switch (wall.style) {
            case PBWallStyleNone:
                break;
            case PBWallStyleWall:
            case PBWallStyleRail: {
                float halfWidth = MAX(wall.radius, 0.004f);
                SCNGeometry *geometry = [PBGeometry wallAlongPoints:p count:n closed:wall.closed halfWidth:halfWidth height:wall.height tableSize:_size];
                [self addNodeWithGeometry:geometry material:wall.style == PBWallStyleRail ? railMaterial : wallMaterial];
                break;
            }
            case PBWallStyleRubber: {
                NSMutableData *points = [NSMutableData data];
                for (NSInteger i = 0; i < n; i++) {
                    SCNVector3 v = [self at:p[i] height:wall.height * 0.5f];
                    [points appendBytes:&v length:sizeof(v)];
                }
                SCNGeometry *geometry = [PBGeometry tubeAlongPoints:points.bytes count:n radius:wall.radius sides:10];
                [self addNodeWithGeometry:geometry material:rubberMaterial];
                for (NSInteger end = 0; end < 2; end++) {
                    [self addPostAt:p[end == 0 ? 0 : n - 1] radius:wall.radius height:wall.height metal:railMaterial rubber:rubberMaterial];
                }
                break;
            }
            case PBWallStylePlastic: {
                PBBezierPath *path = [PBGeometry pathFromPoints:p count:n];
                SCNGeometry *geometry = [PBGeometry prismWithPath:path height:wall.height chamfer:0.002f];
                SCNMaterial *art = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:@"plastic"] metalness:0.0 roughness:0.35];
                geometry.materials = @[ art, plasticMaterial, plasticMaterial, art, plasticMaterial ];
                [_root addChildNode:[self prismNodeWithGeometry:geometry height:wall.height baseHeight:0.0f]];
                break;
            }
        }
    }
}

- (void)addPostAt:(simd_float2)position radius:(float)radius height:(float)height metal:(SCNMaterial *)metal rubber:(SCNMaterial *)rubber {
    SCNCylinder *stem = [SCNCylinder cylinderWithRadius:radius * 0.55f height:height];
    stem.radialSegmentCount = 16;
    SCNNode *stemNode = [self addNodeWithGeometry:stem material:metal];
    stemNode.position = [self at:position height:height * 0.5f];

    SCNTorus *ring = [SCNTorus torusWithRingRadius:radius * 0.72f pipeRadius:radius * 0.34f];
    ring.ringSegmentCount = 24;
    ring.pipeSegmentCount = 10;
    SCNNode *ringNode = [self addNodeWithGeometry:ring material:rubber];
    ringNode.position = [self at:position height:height * 0.6f];

    SCNSphere *cap = [SCNSphere sphereWithRadius:radius * 0.62f];
    cap.segmentCount = 16;
    SCNNode *capNode = [self addNodeWithGeometry:cap material:metal];
    capNode.position = [self at:position height:height];
    capNode.scale = SCNVector3Make(1, 0.5f, 1);
}

- (void)buildPosts {
    SCNMaterial *metal = [self metal];
    SCNMaterial *rubber = [self rubber];
    for (PBSpotDef *post in _table.posts) {
        [self addPostAt:post.position radius:post.radius height:0.06f metal:metal rubber:rubber];
    }
}

- (void)buildPlastics {
    SCNMaterial *art = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:@"slingshot"] metalness:0.0 roughness:0.3];
    art.transparency = _skin.plasticOpacity;
    art.doubleSided = YES;
    art.diffuse.wrapS = SCNWrapModeClamp;
    art.diffuse.wrapT = SCNWrapModeClamp;
    SCNMaterial *edge = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:@"slingshot"] metalness:0.0 roughness:0.1];
    edge.transparency = _skin.plasticOpacity * 0.8f;

    const float thickness = 0.006f;
    for (PBPlasticDef *plastic in _table.plastics) {
        PBBezierPath *path = [PBGeometry pathFromPoints:plastic.points.points count:plastic.points.count];
        SCNGeometry *geometry = [PBGeometry prismWithPath:path height:thickness chamfer:0.0015f];
        geometry.materials = @[ art, art, edge, art, art ];
        SCNNode *node = [self prismNodeWithGeometry:geometry height:thickness baseHeight:plastic.height];
        [_root addChildNode:node];
    }
}

#pragma mark - Bumpers, slings, flippers

- (void)buildBumpers {
    _bumperCaps = [NSMutableArray array];
    SCNMaterial *metal = [self metal];
    CGImageRef capImage = [_skin imageForSlot:@"bumper_cap"];

    for (PBSpotDef *bumper in _table.bumpers) {
        float r = bumper.radius;
        simd_float2 skirt[] = { {r * 1.08f, 0.0f}, {r * 1.08f, 0.006f}, {r * 0.82f, 0.01f}, {r * 0.78f, 0.05f} };
        SCNGeometry *base = [PBGeometry latheWithProfile:skirt count:4 segments:40];
        [self addNodeWithGeometry:base material:metal].position = [self at:bumper.position height:0.0f];

        simd_float2 capProfile[] = { {r, 0.048f}, {r, 0.06f}, {r * 0.86f, 0.074f}, {r * 0.4f, 0.082f}, {0.0001f, 0.084f} };
        SCNGeometry *cap = [PBGeometry latheWithProfile:capProfile count:5 segments:40];
        SCNMaterial *capMaterial = [self pbrWithDiffuse:(__bridge id)capImage metalness:0.0 roughness:0.35];
        capMaterial.emission.contents = (__bridge id)capImage;
        capMaterial.emission.intensity = 0.0;
        [_bumperCaps addObject:capMaterial];
        [self addNodeWithGeometry:cap material:capMaterial].position = [self at:bumper.position height:0.0f];
    }
}

- (void)buildSlingshots {
    _slingBands = [NSMutableArray array];
    SCNMaterial *rubber = [self rubber];
    for (PBEdgeDef *sling in _table.slingshots) {
        simd_float2 mid = (sling.a + sling.b) * 0.5f;
        SCNVector3 points[2] = { [self at:sling.a - mid height:0.0f], [self at:sling.b - mid height:0.0f] };
        // Offsets from the band's midpoint: strip the table-centring out of them.
        SCNVector3 centre = [self at:simd_make_float2(0, 0) height:0.0f];
        for (int i = 0; i < 2; i++) { points[i].x -= centre.x; points[i].z -= centre.z; }
        SCNGeometry *tube = [PBGeometry tubeAlongPoints:points count:2 radius:0.008f sides:10];
        SCNNode *band = [self addNodeWithGeometry:tube material:rubber];
        band.position = [self at:mid height:0.03f];
        [_slingBands addObject:band];
    }
}

- (void)buildFlippers {
    _flipperNodes = [NSMutableArray array];
    SCNMaterial *bat = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:@"flipper"] metalness:0.0 roughness:0.45];
    bat.diffuse.wrapS = SCNWrapModeClamp;
    bat.diffuse.wrapT = SCNWrapModeClamp;
    SCNMaterial *side = [self pbrWithDiffuse:[self color:simd_make_float3(0.85f, 0.85f, 0.88f)] metalness:0.0 roughness:0.35];
    SCNMaterial *metal = [self metal];
    SCNMaterial *rubberBand = [self pbrWithDiffuse:[self color:simd_make_float3(0.75f, 0.05f, 0.08f)] metalness:0.0 roughness:0.55];

    const float height = 0.038f;
    for (PBFlipperDef *def in _table.flippers) {
        SCNNode *pivot = [SCNNode node];
        pivot.position = [self at:def.pivot height:0.0f];
        pivot.eulerAngles = SCNVector3Make(0, def.restAngle, 0);
        [_root addChildNode:pivot];

        SCNGeometry *geometry = [PBGeometry flipperWithLength:def.length baseRadius:def.baseRadius tipRadius:def.tipRadius height:height];
        geometry.materials = @[ bat, side, side, bat, side ];
        SCNNode *body = [SCNNode nodeWithGeometry:geometry];
        body.eulerAngles = SCNVector3Make(-(float)M_PI_2, 0, 0);
        body.position = SCNVector3Make(0, height * 0.5f + 0.003f, 0);
        [pivot addChildNode:body];

        // The rubber sleeve: a band around the bat's outline.
        float rb = def.baseRadius, rt = def.tipRadius, L = def.length;
        float tilt = asinf((rb - rt) / L);
        NSMutableData *loop = [NSMutableData data];
        void (^addPoint)(float, float) = ^(float x, float y) {
            SCNVector3 v = SCNVector3Make(x, height * 0.42f, -y);
            [loop appendBytes:&v length:sizeof(v)];
        };
        for (int i = 0; i <= 12; i++) {
            float angle = (float)M_PI_2 - tilt + ((float)M_PI + 2.0f * tilt) * (float)i / 12.0f;
            addPoint(cosf(angle) * rb, sinf(angle) * rb);
        }
        for (int i = 0; i <= 12; i++) {
            float angle = -(float)M_PI_2 + tilt + ((float)M_PI - 2.0f * tilt) * (float)i / 12.0f;
            addPoint(L + cosf(angle) * rt, sinf(angle) * rt);
        }
        addPoint(cosf((float)M_PI_2 - tilt) * rb, sinf((float)M_PI_2 - tilt) * rb);
        SCNGeometry *band = [PBGeometry tubeAlongPoints:loop.bytes count:(NSInteger)(loop.length / sizeof(SCNVector3)) radius:0.0042f sides:8];
        band.firstMaterial = rubberBand;
        [pivot addChildNode:[SCNNode nodeWithGeometry:band]];

        SCNCylinder *shaft = [SCNCylinder cylinderWithRadius:def.baseRadius * 0.45f height:0.012f];
        shaft.firstMaterial = metal;
        SCNNode *shaftNode = [SCNNode nodeWithGeometry:shaft];
        shaftNode.position = SCNVector3Make(0, height + 0.006f, 0);
        [pivot addChildNode:shaftNode];

        [_flipperNodes addObject:pivot];
    }
}

#pragma mark - Targets, spinners, gates

/// Upright rectangular part spanning a table edge. Its origin is the edge's midpoint at floor level.
- (SCNNode *)addEdgePartFrom:(simd_float2)a to:(simd_float2)b thickness:(float)thickness height:(float)height material:(SCNMaterial *)material {
    float width = simd_distance(a, b);
    SCNBox *box = [SCNBox boxWithWidth:width height:height length:thickness chamferRadius:0.0015];
    box.firstMaterial = material;
    SCNNode *pivot = [SCNNode node];
    pivot.position = [self at:(a + b) * 0.5f height:0.0f];
    pivot.eulerAngles = SCNVector3Make(0, atan2f(b.y - a.y, b.x - a.x), 0);
    SCNNode *boxNode = [SCNNode nodeWithGeometry:box];
    boxNode.position = SCNVector3Make(0, height * 0.5f, 0);
    [pivot addChildNode:boxNode];
    [_root addChildNode:pivot];
    return pivot;
}

- (void)buildTargets {
    SCNMaterial *drop = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:@"drop_target"] metalness:0.0 roughness:0.3];
    SCNMaterial *standup = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:@"standup"] metalness:0.0 roughness:0.3];

    _dropNodes = [NSMutableArray array];
    for (PBEdgeDef *def in _table.dropTargets) {
        simd_float2 inset = simd_normalize(def.b - def.a) * 0.0015f;
        [_dropNodes addObject:[self addEdgePartFrom:def.a + inset to:def.b - inset thickness:0.012f height:0.05f material:drop]];
    }

    _standupNodes = [NSMutableArray array];
    SCNMaterial *metal = [self metal];
    for (PBEdgeDef *def in _table.standups) {
        [_standupNodes addObject:[self addEdgePartFrom:def.a to:def.b thickness:0.012f height:0.05f material:standup]];
    }

    // Kickback plungers are visible at the bottom of their lanes.
    for (PBSpotDef *kick in _table.kickbacks) {
        SCNCylinder *head = [SCNCylinder cylinderWithRadius:0.016f height:0.02f];
        SCNNode *node = [self addNodeWithGeometry:head material:metal];
        node.position = [self at:kick.position - simd_make_float2(0.0f, 0.035f) height:0.01f];
    }
}

- (void)buildSpinnersAndGates {
    SCNMaterial *metal = [self metal];
    SCNMaterial *plate = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:@"spinner"] metalness:0.3 roughness:0.3];

    _spinnerPlates = [NSMutableArray array];
    const float axleHeight = 0.05f;
    for (PBEdgeDef *def in _table.spinners) {
        float width = simd_distance(def.a, def.b);
        SCNNode *pivot = [SCNNode node];
        pivot.position = [self at:(def.a + def.b) * 0.5f height:axleHeight];
        pivot.eulerAngles = SCNVector3Make(0, atan2f(def.b.y - def.a.y, def.b.x - def.a.x), 0);
        [_root addChildNode:pivot];

        SCNCylinder *axle = [SCNCylinder cylinderWithRadius:0.002f height:width];
        axle.firstMaterial = metal;
        SCNNode *axleNode = [SCNNode nodeWithGeometry:axle];
        axleNode.eulerAngles = SCNVector3Make(0, 0, (float)M_PI_2);
        [pivot addChildNode:axleNode];

        SCNBox *box = [SCNBox boxWithWidth:width * 0.86f height:0.003 length:0.05 chamferRadius:0.0];
        box.firstMaterial = plate;
        SCNNode *plateNode = [SCNNode nodeWithGeometry:box];
        [pivot addChildNode:plateNode];
        [_spinnerPlates addObject:plateNode];
    }

    _gatePlates = [NSMutableArray array];
    for (PBEdgeDef *def in _table.gates) {
        float width = simd_distance(def.a, def.b);
        SCNNode *pivot = [SCNNode node];
        pivot.position = [self at:(def.a + def.b) * 0.5f height:0.05f];
        pivot.eulerAngles = SCNVector3Make(0, atan2f(def.b.y - def.a.y, def.b.x - def.a.x), 0);
        [_root addChildNode:pivot];
        SCNCylinder *rod = [SCNCylinder cylinderWithRadius:0.0028f height:width];
        rod.firstMaterial = metal;
        SCNNode *rodNode = [SCNNode nodeWithGeometry:rod];
        rodNode.eulerAngles = SCNVector3Make(0, 0, (float)M_PI_2);
        [pivot addChildNode:rodNode];
        SCNCylinder *wire = [SCNCylinder cylinderWithRadius:0.0018f height:width * 0.96f];
        wire.firstMaterial = metal;
        SCNNode *wireNode = [SCNNode nodeWithGeometry:wire];
        wireNode.eulerAngles = SCNVector3Make(0, 0, (float)M_PI_2);
        wireNode.position = SCNVector3Make(0, -0.03f, 0);
        SCNNode *swing = [SCNNode node];
        [swing addChildNode:wireNode];
        [pivot addChildNode:swing];
        [_gatePlates addObject:swing];
    }
}

#pragma mark - Ramps

- (void)buildRamps {
    SCNMaterial *metal = [self metal];
    for (PBRampDef *ramp in _table.ramps) {
        NSInteger count = ramp.pointCount;
        const simd_float3 *points = ramp.pointData.bytes;
        NSInteger plasticEnd = MIN(ramp.plasticUntil, count - 1);

        // Plastic section: see-through, tinted by the skin's ramp art.
        SCNGeometry *plastic = [PBGeometry rampFromPoints:points count:plasticEnd + 1 width:ramp.width sideHeight:0.022f tableSize:_size];
        SCNMaterial *material = [SCNMaterial material];
        material.lightingModelName = SCNLightingModelBlinn;
        material.diffuse.contents = (__bridge id)[_skin imageForSlot:@"ramp"];
        material.diffuse.wrapS = SCNWrapModeRepeat;
        material.diffuse.wrapT = SCNWrapModeRepeat;
        material.specular.contents = [self color:simd_make_float3(0.5f, 0.5f, 0.5f)];
        material.shininess = 60.0;
        material.transparency = 0.55;
        material.doubleSided = YES;
        material.writesToDepthBuffer = NO;
        SCNNode *plasticNode = [self addNodeWithGeometry:plastic material:material];
        plasticNode.castsShadow = YES;

        // Metal lip where the ball enters.
        simd_float2 mouthDir = simd_normalize(ramp.mouthB - ramp.mouthA);
        simd_float2 lipA = ramp.mouthA - mouthDir * 0.004f, lipB = ramp.mouthB + mouthDir * 0.004f;
        SCNVector3 lip[2] = { [self at:lipA height:0.002f], [self at:lipB height:0.002f] };
        [self addNodeWithGeometry:[PBGeometry tubeAlongPoints:lip count:2 radius:0.004f sides:8] material:metal];

        // Habitrail: two wire rails over the rest of the path, with hoops to tie them.
        NSInteger wireCount = count - plasticEnd;
        float half = ramp.width * 0.42f;
        NSMutableData *left = [NSMutableData dataWithLength:(NSUInteger)wireCount * sizeof(SCNVector3)];
        NSMutableData *right = [NSMutableData dataWithLength:(NSUInteger)wireCount * sizeof(SCNVector3)];
        SCNVector3 *leftPoints = left.mutableBytes, *rightPoints = right.mutableBytes;
        for (NSInteger i = 0; i < wireCount; i++) {
            NSInteger index = plasticEnd + i;
            simd_float3 p = points[index];
            simd_float3 prev = points[MAX(index - 1, 0)], next = points[MIN(index + 1, count - 1)];
            simd_float2 tangent = simd_normalize(next.xy - prev.xy);
            simd_float2 normal = simd_make_float2(-tangent.y, tangent.x);
            leftPoints[i] = [self at:p.xy + normal * half height:p.z + 0.004f];
            rightPoints[i] = [self at:p.xy - normal * half height:p.z + 0.004f];
        }
        [self addNodeWithGeometry:[PBGeometry tubeAlongPoints:leftPoints count:wireCount radius:0.0034f sides:8] material:metal];
        [self addNodeWithGeometry:[PBGeometry tubeAlongPoints:rightPoints count:wireCount radius:0.0034f sides:8] material:metal];

        // Support posts down to the playfield, every so often along the whole ramp.
        for (NSInteger i = 12; i < count - 2; i += 12) {
            simd_float3 p = points[i];
            if (p.z < 0.05f) continue;
            SCNCylinder *post = [SCNCylinder cylinderWithRadius:0.0035f height:p.z];
            post.radialSegmentCount = 10;
            simd_float3 next = points[i + 1], prev = points[i - 1];
            simd_float2 tangent = simd_normalize(next.xy - prev.xy);
            simd_float2 normal = simd_make_float2(-tangent.y, tangent.x);
            for (int s = -1; s <= 1; s += 2) {
                SCNNode *node = [self addNodeWithGeometry:[post copy] material:metal];
                node.position = [self at:p.xy + normal * (ramp.width * 0.52f * s) height:p.z * 0.5f];
            }
        }
    }
}

#pragma mark - Lamps and flashers

- (SCNMaterial *)litMaterialForIcon:(NSInteger)icon color:(NSString *)colorName {
    NSString *key = [NSString stringWithFormat:@"%ld/%@", (long)icon, colorName];
    SCNMaterial *material = _litMaterials[key];
    if (material) return material;
    CGImageRef image = [PBPlayfieldPainter newLitLampWithIcon:[_skin insertIcon:icon] color:[_skin lampColor:colorName]];
    material = [self additiveMaterial:image intensity:2.4];
    CGImageRelease(image);
    _litMaterials[key] = material;
    return material;
}

- (void)buildLamps {
    _lamps = [NSMutableArray array];
    for (PBLampDef *def in _table.lamps) {
        SCNNode *node = [self spriteOfSize:def.size * 2.0f * 2.4f material:[self litMaterialForIcon:def.icon color:def.color]];
        node.position = [self at:def.position height:0.0015f];
        node.opacity = 0;
        node.hidden = YES;
        [_root addChildNode:node];
        PBLampView *lamp = [PBLampView new];
        lamp.node = node;
        [_lamps addObject:lamp];
    }
}

- (void)buildFlashers {
    _flashers = [NSMutableArray array];
    const float domeHeight = 0.13f;
    SCNMaterial *metal = [self metal];
    for (PBSpotDef *def in _table.flashers) {
        simd_float3 color = [_skin lampColor:def.color ?: @"white"];

        simd_float2 profile[] = { {0.03f, 0.0f}, {0.03f, 0.012f}, {0.024f, 0.03f}, {0.012f, 0.042f}, {0.0001f, 0.046f} };
        SCNGeometry *domeGeometry = [PBGeometry latheWithProfile:profile count:5 segments:24];
        SCNMaterial *dome = [self pbrWithDiffuse:[self color:color * 0.5f] metalness:0.0 roughness:0.12];
        dome.emission.contents = [self color:color];
        dome.emission.intensity = 0.08;
        dome.transparency = 0.9;
        SCNNode *domeNode = [self addNodeWithGeometry:domeGeometry material:dome];
        domeNode.position = [self at:def.position height:domeHeight];

        SCNCylinder *foot = [SCNCylinder cylinderWithRadius:0.034f height:0.008f];
        [self addNodeWithGeometry:foot material:metal].position = [self at:def.position height:domeHeight];

        CGImageRef glowImage = [PBPlayfieldPainter newGlowWithColor:color];
        SCNMaterial *glowMaterial = [self additiveMaterial:glowImage intensity:2.2];
        glowMaterial.readsFromDepthBuffer = NO;
        CGImageRelease(glowImage);
        SCNNode *glow = [self spriteOfSize:0.62f material:glowMaterial];
        glow.position = [self at:def.position height:domeHeight + 0.05f];
        glow.opacity = 0;
        glow.hidden = YES;
        glow.renderingOrder = 50;
        [_root addChildNode:glow];

        PBFlasherView *view = [PBFlasherView new];
        view.identifier = def.identifier;
        view.dome = dome;
        view.glow = glow;
        view.light = [self addEffectLightAt:def.position height:0.28f color:color range:1.15f];
        [_flashers addObject:view];
    }
}

#pragma mark - Plunger, apron, balls

- (void)buildPlunger {
    PBPlungerDef *def = _table.plunger;
    SCNMaterial *metal = [self metal];
    SCNNode *rod = [SCNNode node];
    _plungerRodBase = def.position.y;
    rod.position = [self at:def.position height:0.024f];
    [_root addChildNode:rod];

    SCNCylinder *head = [SCNCylinder cylinderWithRadius:def.width * 0.42f height:0.012f];
    head.firstMaterial = [self rubber];
    SCNNode *headNode = [SCNNode nodeWithGeometry:head];
    headNode.eulerAngles = SCNVector3Make((float)M_PI_2, 0, 0);
    headNode.position = SCNVector3Make(0, 0, 0.006f);
    [rod addChildNode:headNode];

    SCNCylinder *shaft = [SCNCylinder cylinderWithRadius:0.006f height:0.2f];
    shaft.firstMaterial = metal;
    SCNNode *shaftNode = [SCNNode nodeWithGeometry:shaft];
    shaftNode.eulerAngles = SCNVector3Make((float)M_PI_2, 0, 0);
    shaftNode.position = SCNVector3Make(0, 0, 0.1f);
    [rod addChildNode:shaftNode];
    _plungerRod = rod;
}

- (void)buildApron {
    float y = _table.apronY;
    float height = _table.apronHeight;
    float laneEdge = _table.plunger.position.x - _table.plunger.width * 0.72f;
    const float margin = 0.6f;
    // Stops short of the shooter lane, with a low shoulder under the plunger.
    simd_float2 outline[] = {
        { -margin, -margin }, { 1.0f + margin, -margin }, { 1.0f + margin, _table.drainY - 0.01f },
        { laneEdge, _table.drainY - 0.01f }, { laneEdge, y }, { -margin, y },
    };
    PBBezierPath *path = [PBGeometry pathFromPoints:outline count:6];
    SCNGeometry *plate = [PBGeometry prismWithPath:path height:height chamfer:0.004f];
    SCNMaterial *art = [SCNMaterial material];
    art.lightingModelName = SCNLightingModelLambert;
    art.diffuse.contents = (__bridge id)_playfieldImage;
    art.diffuse.wrapS = SCNWrapModeClamp;
    art.diffuse.wrapT = SCNWrapModeClamp;
    art.shaderModifiers = @{ SCNShaderModifierEntryPointGeometry: PBWorldUVModifier(_size) };
    SCNMaterial *edge = [self metal];
    plate.materials = @[ art, edge, edge, edge, edge ];
    [_root addChildNode:[self prismNodeWithGeometry:plate height:height baseHeight:0.0f]];

    // Display in a bezel, slightly proud of the apron.
    simd_float4 rect = _table.dmdRect;
    simd_float2 centre = simd_make_float2(rect.x + rect.z * 0.5f, rect.y + rect.w * 0.5f);
    SCNBox *bezel = [SCNBox boxWithWidth:rect.z + 0.05f height:0.008 length:rect.w + 0.034f chamferRadius:0.003];
    bezel.firstMaterial = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:@"dmd_bezel"] metalness:0.3 roughness:0.3];
    SCNNode *bezelNode = [self addNodeWithGeometry:bezel material:nil];
    bezelNode.position = [self at:centre height:height + 0.003f];

    _dmd = [[PBDotMatrix alloc] initWithWidth:rect.z height:rect.w color:_skin.dmdColor];
    _dmd.node.position = [self at:centre height:height + 0.0085f];
    _dmd.node.castsShadow = NO;
    [_root addChildNode:_dmd.node];
}

- (void)buildBalls {
    _ballNodes = [NSMutableArray array];
    SCNMaterial *chrome = [SCNMaterial material];
    chrome.lightingModelName = SCNLightingModelPhysicallyBased;
    chrome.diffuse.contents = [self color:simd_make_float3(0.93f, 0.93f, 0.96f)];
    chrome.metalness.contents = @1.0;
    chrome.roughness.contents = @0.12;
    chrome.shaderModifiers = @{ SCNShaderModifierEntryPointFragment: PBBallReflectionModifier(_size) };
    SCNMaterialProperty *reflection = [SCNMaterialProperty materialPropertyWithContents:(__bridge id)_playfieldImage];
    reflection.mipFilter = SCNFilterModeLinear;
    [chrome setValue:reflection forKey:@"pbPlayfield"];

    for (NSInteger i = 0; i < 8; i++) {
        SCNSphere *sphere = [SCNSphere sphereWithRadius:_table.ballRadius];
        sphere.segmentCount = 40;
        sphere.firstMaterial = chrome;
        SCNNode *node = [SCNNode nodeWithGeometry:sphere];
        node.hidden = YES;
        [_root addChildNode:node];
        [_ballNodes addObject:node];
    }
}

#pragma mark - Per-frame

- (void)syncWithGame:(PBGame *)game elapsed:(double)elapsed {
    _clock += elapsed;
    PBPhysicsWorld *world = game.world;
    float dt = (float)elapsed;

    const PBBall *balls = world.balls;
    for (NSInteger i = 0; i < world.ballCapacity && i < (NSInteger)_ballNodes.count; i++) {
        SCNNode *node = _ballNodes[(NSUInteger)i];
        BOOL live = balls[i].state != PBBallInactive;
        node.hidden = !live;
        if (!live) continue;
        node.position = [self at:balls[i].position height:balls[i].z];
        // Table space (x, y, up) to scene (x, up, -y).
        simd_quatf q = balls[i].orientation;
        node.simdOrientation = simd_quaternion(q.vector.x, q.vector.z, -q.vector.y, q.vector.w);
    }

    for (NSUInteger i = 0; i < _flipperNodes.count; i++) {
        _flipperNodes[i].eulerAngles = SCNVector3Make(0, [world flipperAngle:(NSInteger)i], 0);
    }
    for (NSUInteger i = 0; i < _dropNodes.count; i++) {
        SCNVector3 position = _dropNodes[i].position;
        position.y = -[world dropTargetDrop:(NSInteger)i] * 0.056f;
        _dropNodes[i].position = position;
    }
    for (NSUInteger i = 0; i < _spinnerPlates.count; i++) {
        _spinnerPlates[i].eulerAngles = SCNVector3Make([world spinnerAngle:(NSInteger)i], 0, 0);
    }
    for (NSUInteger i = 0; i < _gatePlates.count; i++) {
        _gatePlates[i].eulerAngles = SCNVector3Make([world gateAngle:(NSInteger)i] * 1.1f, 0, 0);
    }

    float strongestBumper = 0;
    for (NSUInteger i = 0; i < _bumperCaps.count; i++) {
        float flash = expf(-[world bumperFlash:(NSInteger)i] * 9.0f);
        strongestBumper = MAX(strongestBumper, flash);
        _bumperCaps[i].emission.intensity = 0.06 + flash * 1.5;
    }
    _bumperLight.intensity = strongestBumper * 220.0f;

    for (NSUInteger i = 0; i < _slingBands.count; i++) {
        float t = [world slingFlash:(NSInteger)i];
        float kick = expf(-t * 18.0f);
        _slingBands[i].scale = SCNVector3Make(1.0f, 1.0f + kick * 0.6f, 1.0f);
        _slingLights[i].intensity = kick * 70.0f;
    }

    float pull = world.plungerPull;
    SCNVector3 rodPosition = _plungerRod.position;
    rodPosition.z = [self at:simd_make_float2(0, _plungerRodBase - pull * _table.plunger.travel) height:0].z;
    _plungerRod.position = rodPosition;

    [self updateLampsWithGame:game dt:dt];
    [self updateFlashersWithDt:dt];
    [self updateCameraWithGame:game dt:dt];

    PBRuleEngine *rules = game.rules;
    [_dmd showTop:rules.displayTop bottom:rules.displayBottom large:rules.displayIsMessage];
}

- (void)updateLampsWithGame:(PBGame *)game dt:(float)dt {
    PBRuleEngine *rules = game.rules;
    BOOL attract = rules.phase == PBGamePhaseAttract || rules.phase == PBGamePhaseGameOver;
    double slow = fmod(_clock, 0.8) < 0.4 ? 1.0 : 0.0;
    double fast = fmod(_clock, 0.22) < 0.11 ? 1.0 : 0.0;
    NSArray<PBLampDef *> *defs = _table.lamps;

    for (NSUInteger i = 0; i < _lamps.count; i++) {
        PBLampView *lamp = _lamps[i];
        float target;
        if (attract) {
            // A soft wave rolling up the table.
            float phase = defs[i].position.y * 3.2f - (float)_clock * 2.6f + defs[i].position.x * 1.4f;
            target = powf(0.5f + 0.5f * sinf(phase), 3.0f);
        } else {
            switch ([rules modeForLamp:(NSInteger)i]) {
                case PBLampOn: target = 1.0f; break;
                case PBLampBlink: target = (float)slow; break;
                case PBLampFastBlink: target = (float)fast; break;
                default: target = 0.0f; break;
            }
        }
        // Filament behaviour: quick on, slower off.
        float rate = target > lamp.intensity ? 26.0f : 11.0f;
        lamp.intensity += (target - lamp.intensity) * MIN(1.0f, rate * dt);
        BOOL visible = lamp.intensity > 0.01f;
        lamp.node.hidden = !visible;
        if (visible) lamp.node.opacity = lamp.intensity;
    }
}

- (void)updateFlashersWithDt:(float)dt {
    for (PBFlasherView *flasher in _flashers) {
        flasher.level = MAX(0.0f, flasher.level - dt * 3.2f);
        float level = flasher.level * flasher.level;
        flasher.light.intensity = level * 650.0f;
        flasher.dome.emission.intensity = 0.08 + level * 5.0;
        BOOL visible = level > 0.01f;
        flasher.glow.hidden = !visible;
        if (visible) flasher.glow.opacity = level;
    }
}

- (void)updateCameraWithGame:(PBGame *)game dt:(float)dt {
    simd_float2 nudge = game.lastNudge;
    _shake = MAX(0.0f, _shake - dt * 3.5f);
    float shakeOffset = 0;
    if (_shake > 0.001f) {
        _shakeSeed = _shakeSeed * 1664525u + 1013904223u;
        shakeOffset = ((float)(_shakeSeed >> 16 & 0xFF) / 127.5f - 1.0f) * _shake * 0.006f;
    }
    _cameraNode.position = SCNVector3Make(-nudge.x * 0.01f + shakeOffset, _baseCameraHeight, nudge.y * 0.01f - shakeOffset * 0.6f);
}

#pragma mark - PBGameObserver

- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {
    switch (event->kind) {
        case PBEventBumper: _shake = MAX(_shake, 0.5f); break;
        case PBEventKickback:
        case PBEventPlungerRelease: _shake = MAX(_shake, 0.8f); break;
        case PBEventDrain: _shake = MAX(_shake, 0.3f); break;
        default: break;
    }
}

- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier {
    for (PBFlasherView *flasher in _flashers) {
        if ([flasher.identifier isEqualToString:flasherIdentifier]) flasher.level = 1.0f;
    }
}

- (void)game:(PBGame *)game fanfare:(NSString *)name {
    if ([name isEqualToString:@"multiball"] || [name isEqualToString:@"jackpot"] || [name isEqualToString:@"extraBall"]) {
        for (PBFlasherView *flasher in _flashers) flasher.level = 1.0f;
        _shake = 1.0f;
    }
}

@end
