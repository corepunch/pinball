//
//  PBTableScene.m
//

#import "PBTableScene.h"
#import "PBGeometry.h"
#import "PBPlayfieldPainter.h"
#import "PBModelLibrary.h"
#import "PBLayoutValidator.h"

static const float kLightingMaxTilt = 0.60f;  // Radians; keep the light above the table.
static const float kLightingResponse = 0.10f; // Seconds; suppress hand tremor without lag.

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

/// A MatCap: the look of polished metal is read from a captured sphere by the surface's facing
/// alone. The normal turns with the room as the phone tilts, so the highlights slide across the parts.
static NSString *const kPBMatcapModifier =
    @"#pragma arguments\n"
    @"texture2d<float> pbMatcap;\n"
    @"float4x4 pbRoom;\n"
    @"#pragma body\n"
    @"constexpr sampler pbSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);\n"
    @"float3 pbN = (scn_frame.inverseViewTransform * float4(normalize(_surface.normal), 0.0)).xyz;\n"
    @"pbN = (pbRoom * float4(pbN, 0.0)).xyz;\n"
    @"pbN = normalize((scn_frame.viewTransform * float4(pbN, 0.0)).xyz);\n"
    @"float2 pbUV = float2(pbN.x, -pbN.y) * 0.492 + 0.5;\n"
    // Deep shadows and clipped peaks: a metal's highlights go past its own colour, toward white,
    // and over 1 they feed the bloom.
    @"float3 pbRoomColor = pbMatcap.sample(pbSampler, pbUV).rgb;\n"
    @"float pbLight = dot(pbRoomColor, float3(0.2126, 0.7152, 0.0722));\n"
    @"float pbCap = smoothstep(0.04, 0.86, pbLight);\n"
    @"float3 pbHue = pbRoomColor / max(pbLight, 0.02);\n"
    @"float3 pbTint = _surface.diffuse.rgb;\n"
    @"_surface.diffuse.rgb = pbTint * pbHue * (0.06 + 1.1 * pbCap) + mix(pbTint * pbHue, float3(1.0), 0.45) * 1.4 * pow(pbCap, 5.0);\n";

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

@interface PBBumperView : NSObject
@property (nonatomic, strong) SCNNode *cap;
@property (nonatomic, strong) SCNMaterial *idle;
@property (nonatomic, strong) SCNMaterial *lit;
@property (nonatomic) BOOL illuminated;
@property (nonatomic, copy) NSArray<SCNGeometry *> *paintedGeometry;
@end
@implementation PBBumperView @end

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
    PBModelLibrary *_models;
    NSDictionary<NSString *, SCNMaterial *> *_modelMaterials;
    simd_float2 _size;
    CGImageRef _playfieldImage;
    SCNNode *_root;
    SCNCamera *_camera;
    SCNVector3 _baseCameraPosition;
    SCNNode *_borderNode;
    NSMutableArray<SCNMaterial *> *_matcapMaterials;
    SCNMaterial *_accentMaterial, *_metalMaterial;
    CGFloat _borderRadius, _borderTop, _screenTop;
    SCNNode *_lightingRig;
    simd_quatf _lightingRotation;
    BOOL _plasticsModelled;

    NSMutableArray<SCNNode *> *_ballNodes;
    NSMutableArray<SCNNode *> *_flipperNodes;
    NSMutableArray<SCNNode *> *_dropNodes;
    NSMutableArray<SCNNode *> *_spinnerPlates;
    NSMutableArray<SCNNode *> *_gatePlates;
    NSMutableArray<PBBumperView *> *_bumpers;
    NSMutableArray<SCNNode *> *_slingBands;
    NSMutableArray<SCNNode *> *_standupNodes;
    NSMutableArray<PBLampView *> *_lamps;
    NSMutableArray<PBFlasherView *> *_flashers;
    SCNNode *_plungerRod;
    float _plungerRodBase;
    NSMutableArray<SCNLight *> *_bumperLights;
    NSMutableArray<SCNLight *> *_slingLights;
    NSMutableDictionary<NSString *, SCNMaterial *> *_litMaterials;

    double _clock;
    float _shake;
    uint32_t _shakeSeed;
}

- (instancetype)initWithTable:(PBTableDefinition *)table skin:(PBSkin *)skin {
    if ((self = [super init])) {
        _table = table;
        _skin = skin;
        if (skin.modelKit.length) _models = [[PBModelLibrary alloc] initWithBundle:skin.resourceBundle kit:skin.modelKit];
        _size = table.size;
        _scene = [SCNScene scene];
        _root = _scene.rootNode;
        _shakeSeed = 0x12345;
        _lightingRotation = simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f);
        _litMaterials = [NSMutableDictionary dictionary];

        _playfieldImage = [PBPlayfieldPainter newPlayfieldForTable:table skin:skin];

        [self buildCameraAndLights];
        [self buildPlayfield];
        [self buildCabinet];
        [self buildWalls];
        [self buildPosts];
        [self buildPlastics];
        [self buildPlayfieldHardware];
        [self buildBumpers];
        [self buildSlingshots];
        [self buildFlippers];
        [self buildTargets];
        [self buildSpinnersAndGates];
        [self buildRamps];
        [self buildLamps];
        [self buildFlashers];
        [self buildDecor];
        [self buildPlunger];
        [self buildBalls];
        [self fitBorderToCornerRadius:0.154];
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
    material.diffuse.magnificationFilter = SCNFilterModeLinear;
    material.diffuse.minificationFilter = SCNFilterModeLinear;
    material.diffuse.mipFilter = SCNFilterModeLinear;
    material.diffuse.maxAnisotropy = 8;
    return material;
}

/// Printed enamel already carries authored highlights. A restrained clear coat keeps
/// its colours intact while the separate metal rims provide the stronger reflections.
- (SCNMaterial *)printedMaterial:(NSString *)slot {
    SCNMaterial *material = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:slot] metalness:0 roughness:0.5];
    material.lightingModelName = SCNLightingModelBlinn;
    material.specular.contents = [self color:simd_make_float3(0.06f, 0.06f, 0.06f)];
    material.shininess = 42;
    return material;
}

- (SCNMaterial *)matcapNamed:(NSString *)name color:(simd_float3)color {
    SCNMaterial *material = [SCNMaterial material];
    material.lightingModelName = SCNLightingModelConstant;
    material.diffuse.contents = [self color:color];
    material.shaderModifiers = @{ SCNShaderModifierEntryPointSurface: kPBMatcapModifier };
    NSURL *url = [_skin.resourceBundle URLForResource:[@"matcap-" stringByAppendingString:name] withExtension:@"png" subdirectory:@"GameData/Materials"];
    NSAssert(url, @"Missing MatCap %@", name);
    SCNMaterialProperty *capture = [SCNMaterialProperty materialPropertyWithContents:url];
    capture.mipFilter = SCNFilterModeLinear;
    [material setValue:capture forKey:@"pbMatcap"];
    [material setValue:[NSValue valueWithSCNMatrix4:SCNMatrix4Identity] forKey:@"pbRoom"];
    if (!_matcapMaterials) _matcapMaterials = [NSMutableArray array];
    [_matcapMaterials addObject:material];
    return material;
}

// One shared material each, so a tilt updates only a handful of materials per frame.
- (SCNMaterial *)accentMetal {
    if (!_accentMaterial) _accentMaterial = [self matcapNamed:_skin.hardwareMatcap color:_skin.accentColor];
    return _accentMaterial;
}

- (SCNMaterial *)metal {
    if (!_metalMaterial) _metalMaterial = [self matcapNamed:_skin.hardwareMatcap color:_skin.metalColor];
    return _metalMaterial;
}

- (SCNMaterial *)rubber {
    return [self pbrWithDiffuse:[self color:_skin.rubberColor] metalness:0.0 roughness:0.6];
}

- (SCNMaterial *)blackRubber {
    SCNMaterial *material = [SCNMaterial material];
    material.lightingModelName = SCNLightingModelBlinn;
    material.diffuse.contents = [self color:simd_make_float3(0.012f, 0.012f, 0.014f)];
    material.specular.contents = [self color:simd_make_float3(0.3f, 0.3f, 0.32f)];
    material.shininess = 34;
    return material;
}

- (SCNMaterial *)tileMaterial:(NSString *)slot metalness:(CGFloat)metalness roughness:(CGFloat)roughness {
    SCNMaterial *material = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:slot] metalness:metalness roughness:roughness];
    material.diffuse.wrapS = SCNWrapModeRepeat;
    material.diffuse.wrapT = SCNWrapModeRepeat;
    return material;
}

/// A clear moulded part: SceneKit draws it after the opaque table, without writing depth.
- (SCNMaterial *)clearMaterial:(simd_float3)color opacity:(CGFloat)opacity shininess:(CGFloat)shininess {
    SCNMaterial *material = [SCNMaterial material];
    material.lightingModelName = SCNLightingModelBlinn;
    material.diffuse.contents = [self color:color];
    material.specular.contents = [self color:simd_make_float3(0.9f, 0.9f, 0.9f)];
    material.shininess = shininess;
    material.transparency = opacity;
    material.writesToDepthBuffer = NO;
    material.doubleSided = YES;
    return material;
}

/// Blender exports semantic material names so a single mesh kit serves every skin.
- (void)skinModel:(SCNNode *)root overrides:(NSDictionary<NSString *, SCNMaterial *> *)overrides {
    if (!_modelMaterials) {
        SCNMaterial *glow = [SCNMaterial material];
        glow.lightingModelName = SCNLightingModelConstant;
        glow.diffuse.contents = [self color:[_skin lampColor:@"bumper"]];
        glow.diffuse.intensity = 1.6;
        // Lenses only add a highlight. Any diffuse would mist over the coloured insert below.
        SCNMaterial *lens = [self clearMaterial:simd_make_float3(0.0f, 0.0f, 0.0f) opacity:1.0 shininess:110];
        lens.blendMode = SCNBlendModeAdd;
        lens.specular.contents = [self color:simd_make_float3(0.55f, 0.55f, 0.55f)];
        // Lambert: from above, even a matte PBR surface mirrors the room and turns grey.
        SCNMaterial *dark = [SCNMaterial material];
        dark.lightingModelName = SCNLightingModelLambert;
        dark.diffuse.contents = [self color:simd_make_float3(0.018f, 0.024f, 0.032f)];
        SCNMaterial *wallArt = [self printedMaterial:@"wall_top"];
        wallArt.diffuse.wrapS = SCNWrapModeRepeat;
        wallArt.diffuse.wrapT = SCNWrapModeRepeat;
        SCNMaterial *blockArt = [self printedMaterial:@"plastic"];
        SCNMaterial *bat = [self printedMaterial:@"flipper"];
        // The kit's coloured parts look lit even with no lamp behind them, like the concept's.
        SCNMaterial *amber = [glow copy];
        amber.diffuse.contents = [self color:[_skin lampColor:@"amber"]];
        CGImageRef jewelImage = [PBPlayfieldPainter newJewelWithColor:[_skin lampColor:@"bumper"]];
        SCNMaterial *jewel = [SCNMaterial material];
        jewel.lightingModelName = SCNLightingModelConstant;
        jewel.diffuse.contents = (__bridge id)jewelImage;
        CGImageRelease(jewelImage);
        SCNMaterial *skirtLamp = [glow copy];
        skirtLamp.diffuse.contents = [self color:_skin.slingLensColor];
        CGImageRef lensImage = [PBPlayfieldPainter newLensWithColor:_skin.slingLensColor];
        SCNMaterial *slingLens = [self pbrWithDiffuse:(__bridge id)lensImage metalness:0 roughness:0.16];
        slingLens.emission.contents = (__bridge id)lensImage;
        slingLens.emission.intensity = 0.3;
        CGImageRelease(lensImage);
        CGImageRef amberImage = [PBPlayfieldPainter newLensWithColor:[_skin lampColor:@"amber"]];
        SCNMaterial *amberLens = [self pbrWithDiffuse:(__bridge id)amberImage metalness:0 roughness:0.16];
        amberLens.emission.contents = (__bridge id)amberImage;
        amberLens.emission.intensity = 0.3;
        CGImageRelease(amberImage);
        // Solid sheet metal unless the skin makes it glass.
        SCNMaterial *rampFloor = [self matcapNamed:_skin.rampMatcap color:_skin.rampGlassColor];
        if (_skin.rampOpacity < 1) {
            rampFloor.transparency = _skin.rampOpacity;
            rampFloor.writesToDepthBuffer = NO;
        }
        // Blinn, as metal facing up would mirror the room's lights straight into the camera.
        SCNMaterial *enamel = [SCNMaterial material];
        enamel.lightingModelName = SCNLightingModelBlinn;
        enamel.diffuse.contents = [self color:_skin.rubberColor * simd_make_float3(1.0f, 0.93f, 0.76f)];
        enamel.specular.contents = [self color:simd_make_float3(0.22f, 0.22f, 0.22f)];
        enamel.shininess = 60;
        bat.emission.contents = bat.diffuse.contents;
        bat.emission.intensity = 0.45;
        for (SCNMaterial *clamped in @[ blockArt, bat ]) {
            clamped.diffuse.wrapS = SCNWrapModeClamp;
            clamped.diffuse.wrapT = SCNWrapModeClamp;
        }
        _modelMaterials = @{
            @"metal": [self metal], @"accent": [self accentMetal], @"rubber": [self rubber],
            @"dark": dark,
            @"glow_amber": amber, @"jewel": jewel, @"skirt_lamp": skirtLamp, @"black_rubber": [self blackRubber], @"amber_lens": amberLens, @"sling_lens": slingLens, @"ramp_floor": rampFloor, @"enamel": enamel,
            @"cap_art": [self printedMaterial:@"bumper_cap"],
            @"lens": lens,
            @"glow": glow, @"wall_art": wallArt, @"block_art": blockArt, @"flipper_art": bat,
            @"target_art": [self printedMaterial:@"drop_target"],
        };
    }
    [root enumerateChildNodesUsingBlock:^(SCNNode *child, BOOL *stop) {
        if (!child.geometry) return;
        NSMutableArray *mapped = [NSMutableArray array];
        for (SCNMaterial *material in child.geometry.materials) {
            [mapped addObject:overrides[material.name] ?: self->_modelMaterials[material.name] ?: material];
            if ([material.name isEqualToString:@"cap_art"]) child.geometry.name = @"cap_art";
        }
        child.geometry.materials = mapped;
    }];
}

/// A kit part scaled and placed on the table, or nil when the skin has no such model.
- (SCNNode *)addModel:(NSString *)name at:(simd_float2)position height:(float)height scale:(float)scale {
    SCNNode *model = [_models nodeNamed:name];
    if (!model) return nil;
    [self skinModel:model overrides:@{}];
    model.scale = SCNVector3Make(scale, scale, scale);
    model.position = [self at:position height:height];
    [_root addChildNode:model];
    return model;
}

/// Table-specific meshes are authored in place, in table coordinates.
- (BOOL)addTableModel:(NSString *)suffix {
    SCNNode *model = [_models nodeNamed:[NSString stringWithFormat:@"%@-%@", _table.identifier, suffix]];
    if (!model) return NO;
    [self skinModel:model overrides:@{}];
    [_root addChildNode:model];
    return YES;
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
    _camera.usesOrthographicProjection = YES;
    _camera.zNear = 0.1;
    _camera.zFar = 20.0;
    _camera.wantsHDR = YES;
    _camera.wantsExposureAdaptation = NO;
    _camera.exposureOffset = 0.0;
    _camera.bloomIntensity = _skin.bloomIntensity;
    _camera.bloomThreshold = 1.55;
    _camera.bloomBlurRadius = 9.0;
    _camera.vignettingIntensity = 0.35;
    _camera.vignettingPower = 1.2;
    _camera.contrast = 0.3;
    _camera.saturation = 1.18;
    _camera.colorFringeStrength = 0.0;
    _camera.colorFringeIntensity = 0.0;
    // No screen-space ambient occlusion: it renders the whole frame black with this scene
    // in the simulator. PBPlayfieldPainter bakes contact shadows instead.

    _cameraNode = [SCNNode node];
    _cameraNode.camera = _camera;
    _cameraNode.eulerAngles = SCNVector3Make(-(float)M_PI_2 + PBTableCameraTilt * (float)M_PI / 180.0f, 0, 0);
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
    key.intensity = _skin.keyIntensity * 0.45f;
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
    keyNode.name = @"lighting.key";
    keyNode.light = key;
    // Off-axis, like a cabinet's lamps. Directly above, the mirror direction of every
    // up-facing surface would point into the overhead camera and wash the parts out.
    keyNode.position = SCNVector3Make(-2.2f, 2.9f, 1.4f);
    [keyNode lookAt:SCNVector3Make(0, 0, 0)];
    _lightingRig = [SCNNode node];
    _lightingRig.name = @"lighting.rig";
    [_lightingRig addChildNode:keyNode];
    [_root addChildNode:_lightingRig];

    _bumperLights = [NSMutableArray array];
    for (PBSpotDef *bumper in _table.bumpers) {
        [_bumperLights addObject:[self addEffectLightAt:bumper.position height:0.11f
                                                 color:[_skin lampColor:@"bumper"] range:0.28f]];
    }
    _slingLights = [NSMutableArray array];
    for (PBEdgeDef *sling in _table.slingshots) {
        [_slingLights addObject:[self addEffectLightAt:(sling.a + sling.b) * 0.5f height:0.14f color:simd_make_float3(1.0f, 0.9f, 0.8f) range:0.5f]];
    }
}

/// The room stays stationary as the phone turns, so move it by the inverse attitude.
/// All node/material mutations happen on the render thread, never in a motion callback.
- (void)updateLightingForAttitude:(simd_quatf)attitude elapsed:(double)elapsed {
    float lengthSquared = simd_length_squared(attitude.vector);
    if (!isfinite(lengthSquared) || lengthSquared < 1e-6f || !isfinite(elapsed)) return;
    attitude = simd_normalize(attitude);
    if (attitude.vector.w < 0) attitude.vector = -attitude.vector;
    // Device x/y/z -> table x/-z/y. Quaternion axes transform in the same basis.
    simd_quatf target = simd_inverse(simd_quaternion(attitude.vector.x, attitude.vector.z, -attitude.vector.y, attitude.vector.w));
    float angle = 2.0f * acosf(MIN(1.0f, target.vector.w));
    if (angle > kLightingMaxTilt) target = simd_slerp(simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f), target, kLightingMaxTilt / angle);
    float blend = 1.0f - expf(-(float)MIN(MAX(elapsed, 0), 0.1) / kLightingResponse);
    _lightingRotation = simd_normalize(simd_slerp(_lightingRotation, target, blend));
    _lightingRig.simdOrientation = _lightingRotation;
    NSValue *room = [NSValue valueWithSCNMatrix4:SCNMatrix4FromMat4(simd_matrix4x4(simd_inverse(_lightingRotation)))];
    for (SCNMaterial *material in _matcapMaterials) [material setValue:room forKey:@"pbRoom"];
    // Rotate the existing reflection map; no image regeneration or probe rebaking per frame.
    _scene.lightingEnvironment.contentsTransform = SCNMatrix4FromMat4(simd_matrix4x4(_lightingRotation));
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
    CGFloat tilt = PBTableCameraTilt * M_PI / 180.0;
    CGFloat span = (CGFloat)_size.y * cos(tilt);
    // A phone sees exactly the table's width, with the flippers on its bottom edge. A much
    // squarer screen sees the whole table instead, framed by the cabinet.
    CGFloat visibleHeight = heightOverWidth >= 1.9 ? (CGFloat)_size.x * heightOverWidth : span;
    _camera.orthographicScale = visibleHeight * 0.5;
    CGFloat aim = -(visibleHeight - span) * 0.5 / cos(tilt);
    _screenTop = visibleHeight / cos(tilt);
    const CGFloat distance = 6.0;
    _baseCameraPosition = SCNVector3Make(0, distance * cos(tilt), aim + distance * sin(tilt));
    _cameraNode.position = _baseCameraPosition;
}

- (void)fitBorderToCornerRadius:(CGFloat)radius {
    if (_borderNode && fabs(radius - _borderRadius) < 1e-4 && fabs(_screenTop - _borderTop) < 1e-4) return;
    _borderRadius = radius;
    _borderTop = _screenTop;
    [_borderNode removeFromParentNode];
    _borderNode = [SCNNode node];
    _borderNode.name = @"cabinet.rail";
    [_root addChildNode:_borderNode];
    // A circle on screen is an ellipse on the tilted table, with its height stretched.
    float stretch = 1.0f / cosf(PBTableCameraTilt * (float)M_PI / 180.0f);
    float lift = tanf(PBTableCameraTilt * (float)M_PI / 180.0f);
    NSData *(^path)(float, float) = ^NSData *(float inset, float height) {
        // Measured on screen, then lowered by what its height lifts it on the tilted view.
        float top = (float)self->_screenTop - inset * stretch - height * lift;
        float corner = MAX((float)radius - inset, 0.0f);
        float x0 = inset, x1 = self->_size.x - inset;
        NSMutableData *points = [NSMutableData data];
        void (^add)(float, float) = ^(float x, float y) {
            SCNVector3 point = [self at:simd_make_float2(x, y) height:height];
            [points appendBytes:&point length:sizeof(point)];
        };
        for (int i = 0; i <= 24; i++) {
            float a = (float)M_PI_2 * (float)i / 24.0f;
            add(x1 - corner + corner * cosf(a), top - corner * stretch + corner * stretch * sinf(a));
        }
        for (int i = 0; i <= 24; i++) {
            float a = (float)M_PI_2 + (float)M_PI_2 * (float)i / 24.0f;
            add(x0 + corner + corner * cosf(a), top - corner * stretch + corner * stretch * sinf(a));
        }
        return points;
    };
    NSData *rail = path(0.0034f, 0.004f);
    SCNNode *body = [SCNNode nodeWithGeometry:[PBGeometry tubeAlongPoints:rail.bytes count:(NSInteger)(rail.length / sizeof(SCNVector3)) radius:0.0026f sides:10]];
    body.geometry.firstMaterial = [self accentMetal];
    [_borderNode addChildNode:body];
}

#pragma mark - Static table

- (void)buildPlayfield {
    // SCNFloor gives true planar reflections of everything above it: the polished
    // clear-coat look, with ball and bumpers mirrored in the playfield.
    SCNFloor *floor = [SCNFloor floor];
    floor.width = _size.x * 2.0f;
    floor.length = _size.y * 2.0f;
    floor.reflectivity = _skin.playfieldReflectivity;
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
    // The phone's own edge is the table's edge. This frame stands just outside the view, and
    // only shows on a screen of different proportions, in place of stretched playfield art.
    const float margin = 0.6f;
    simd_float2 outline[] = {
        { -margin, -margin }, { 0, -margin }, { 0, _size.y }, { _size.x, _size.y }, { _size.x, -margin },
        { _size.x + margin, -margin }, { _size.x + margin, _size.y + margin }, { -margin, _size.y + margin },
    };
    const float height = 0.11f;
    SCNGeometry *frame = [PBGeometry prismWithPoints:outline count:8 height:height chamfer:0.0f];
    SCNMaterial *rail = [self tileMaterial:@"side_rail" metalness:0.0 roughness:0.8];
    rail.lightingModelName = SCNLightingModelLambert;
    rail.diffuse.intensity = 0.62;
    rail.shaderModifiers = @{ SCNShaderModifierEntryPointGeometry:
        @"float4 pbWorld = scn_node.modelTransform * _geometry.position;\n"
        @"_geometry.texcoords[0] = pbWorld.xz * 3.0;\n",
        SCNShaderModifierEntryPointFragment: kPBHDRGuard };
    frame.firstMaterial = rail;
    SCNNode *node = [self prismNodeWithGeometry:frame height:height baseHeight:0.0f];
    node.castsShadow = NO;  // It would throw a band of shadow across the playfield.
    [_root addChildNode:node];
}

- (void)buildWalls {
    SCNMaterial *wallMaterial = [self tileMaterial:@"wall_top" metalness:0.0 roughness:0.5];
    SCNMaterial *railMaterial = [self metal];
    SCNMaterial *trimMaterial = [self accentMetal];
    SCNMaterial *rubberMaterial = [self rubber];
    SCNMaterial *plasticMaterial = [self tileMaterial:@"wall_top" metalness:0.0 roughness:0.4];
    BOOL plated = [self addTableModel:@"walls"];
    // The plastics model carries raised housings as well as the free-floating plastics.
    BOOL housed = [self addTableModel:@"plastics"];
    _plasticsModelled = housed;

    for (PBWallDef *wall in _table.walls) {
        const simd_float2 *p = wall.points.points;
        NSInteger n = wall.points.count;
        switch (wall.style) {
            case PBWallStyleNone:
                break;
            case PBWallStyleWall:
            case PBWallStyleRail: {
                if (plated) break;
                float halfWidth = MAX(wall.radius, 0.004f);
                SCNGeometry *geometry = [PBGeometry wallAlongPoints:p count:n closed:wall.closed halfWidth:halfWidth height:wall.height tableSize:_size];
                [self addNodeWithGeometry:geometry material:wall.style == PBWallStyleRail ? railMaterial : wallMaterial];
                if (wall.style == PBWallStyleWall) {
                    NSMutableData *edge = [NSMutableData data];
                    for (NSInteger i = 0; i < n + (wall.closed ? 1 : 0); i++) {
                        SCNVector3 v = [self at:p[i % n] height:wall.height + 0.001f];
                        [edge appendBytes:&v length:sizeof(v)];
                    }
                    [self addNodeWithGeometry:[PBGeometry tubeAlongPoints:edge.bytes count:edge.length / sizeof(SCNVector3)
                                                                 radius:0.0012f sides:6] material:trimMaterial];
                }
                break;
            }
            case PBWallStyleRubber: {
                if (plated) break;
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
                if (housed) break;
                SCNGeometry *geometry = [PBGeometry prismWithPoints:p count:n height:wall.height chamfer:0.002f];
                SCNMaterial *art = [self printedMaterial:@"plastic"];
                geometry.materials = @[ art, plasticMaterial, plasticMaterial, art, plasticMaterial ];
                [_root addChildNode:[self prismNodeWithGeometry:geometry height:wall.height baseHeight:0.0f]];
                break;
            }
        }
    }
}

- (void)addPostAt:(simd_float2)position radius:(float)radius height:(float)height metal:(SCNMaterial *)metal rubber:(SCNMaterial *)rubber {
    if ([self addModel:@"post" at:position height:0 scale:radius]) return;
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
        if (post.model && [self addModel:post.model at:post.position height:0 scale:post.radius]) continue;
        [self addPostAt:post.position radius:post.radius height:0.06f metal:metal rubber:rubber];
    }
}

- (void)addScrewAt:(simd_float2)position height:(float)height radius:(float)radius {
    SCNCylinder *head = [SCNCylinder cylinderWithRadius:radius height:0.0018f];
    head.radialSegmentCount = 16;
    [self addNodeWithGeometry:head material:[self metal]].position = [self at:position height:height];
    SCNBox *slot = [SCNBox boxWithWidth:radius * 1.35f height:0.0003f length:radius * 0.22f chamferRadius:0];
    SCNMaterial *dark = [self pbrWithDiffuse:[self color:simd_make_float3(0.025f, 0.03f, 0.04f)] metalness:0 roughness:0.7];
    SCNNode *groove = [self addNodeWithGeometry:slot material:dark];
    groove.position = [self at:position height:height + 0.001f];
    groove.eulerAngles = SCNVector3Make(0, 0.6f, 0);
}

- (void)buildPlayfieldHardware {
    SCNMaterial *trim = [self accentMetal];
    for (PBSpotDef *saucer in _table.saucers) {
        SCNTorus *lip = [SCNTorus torusWithRingRadius:saucer.radius * 1.12f pipeRadius:0.003f];
        lip.ringSegmentCount = 48;
        lip.pipeSegmentCount = 8;
        [self addNodeWithGeometry:lip material:trim].position = [self at:saucer.position height:0.003f];
    }
}

- (void)buildPlastics {
    if (_plasticsModelled) return;
    SCNMaterial *art = [self printedMaterial:@"slingshot"];
    art.transparency = _skin.plasticOpacity;
    art.doubleSided = YES;
    art.diffuse.wrapS = SCNWrapModeClamp;
    art.diffuse.wrapT = SCNWrapModeClamp;
    SCNMaterial *edge = [self pbrWithDiffuse:(__bridge id)[_skin imageForSlot:@"slingshot"] metalness:0.0 roughness:0.1];
    edge.transparency = _skin.plasticOpacity * 0.8f;

    const float thickness = 0.006f;
    for (PBPlasticDef *plastic in _table.plastics) {
        SCNGeometry *geometry = [PBGeometry prismWithPoints:plastic.points.points count:plastic.points.count
                                                   height:thickness chamfer:0.0015f];
        geometry.materials = @[ art, art, edge, art, art ];
        SCNNode *node = [self prismNodeWithGeometry:geometry height:thickness baseHeight:plastic.height];
        [_root addChildNode:node];

        const simd_float2 *points = plastic.points.points;
        NSInteger count = plastic.points.count;
        simd_float2 centre = simd_make_float2(0, 0);
        for (NSInteger i = 0; i < count; i++) centre += points[i];
        centre /= (float)count;
        NSMutableData *rim = [NSMutableData data];
        for (NSInteger i = 0; i <= count; i++) {
            SCNVector3 v = [self at:points[i % count] height:plastic.height + thickness];
            [rim appendBytes:&v length:sizeof(v)];
        }
        [self addNodeWithGeometry:[PBGeometry tubeAlongPoints:rim.bytes count:count + 1 radius:0.0012f sides:6]
                        material:[self accentMetal]];
        for (NSInteger i = 0; i < count; i += MAX(1, count / 3)) {
            simd_float2 delta = centre - points[i];
            float distance = simd_length(delta);
            simd_float2 pos = points[i] + delta * MIN(0.22f, 0.012f / MAX(distance, 0.001f));
            [self addScrewAt:pos height:plastic.height + thickness + 0.001f radius:0.0033f];
        }
    }
}

#pragma mark - Bumpers, slings, flippers

- (void)buildBumpers {
    _bumpers = [NSMutableArray array];
    SCNMaterial *metal = [self metal];
    SCNMaterial *accent = [self accentMetal];
    SCNMaterial *rubber = [self rubber];
    BOOL authoredHit = [_skin hasImageForSlot:@"bumper_cap_lit"];
    CGImageRef hitImage = authoredHit ? [_skin imageForSlot:@"bumper_cap_lit"] : [_skin imageForSlot:@"bumper_cap"];

    for (PBSpotDef *bumper in _table.bumpers) {
        float r = bumper.radius;
        SCNNode *modelBase = [_models nodeNamed:@"bumper-base"];
        SCNNode *modelCap = [_models nodeNamed:@"bumper-cap"];
        if (modelBase && modelCap) {
            PBBumperView *view = [PBBumperView new];
            CGImageRef capImage = [PBPlayfieldPainter newBumperCapWithBase:_skin.capBaseColor star:_skin.capStarColor];
            view.idle = [self printedMaterial:@"bumper_cap"];
            view.idle.diffuse.contents = (__bridge id)capImage;
            view.idle.emission.contents = (__bridge id)capImage;
            view.idle.emission.intensity = 0.3;
            view.lit = [view.idle copy];
            view.lit.emission.contents = (__bridge id)capImage;
            view.lit.emission.intensity = 0.6;
            CGImageRelease(capImage);
            [self skinModel:modelBase overrides:@{}];
            [self skinModel:modelCap overrides:@{ @"cap_art": view.idle }];
            modelBase.scale = modelCap.scale = SCNVector3Make(r, r, r);
            modelBase.position = modelCap.position = [self at:bumper.position height:0];
            modelCap.name = [@"bumper." stringByAppendingString:bumper.identifier];
            NSMutableArray *painted = [NSMutableArray array];
            [modelCap enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
                if ([node.geometry.name isEqualToString:@"cap_art"]) [painted addObject:node.geometry];
            }];
            view.cap = modelCap;
            view.paintedGeometry = painted;
            [_root addChildNode:modelBase];
            [_root addChildNode:modelCap];
            [_bumpers addObject:view];
            continue;
        }
        simd_float2 skirt[] = { {r * 1.08f, 0.002f}, {r * 1.08f, 0.009f}, {r * 0.87f, 0.016f},
                               {r * 0.76f, 0.025f}, {r * 0.76f, 0.049f} };
        SCNGeometry *base = [PBGeometry latheWithProfile:skirt count:5 segments:64];
        [self addNodeWithGeometry:base material:metal].position = [self at:bumper.position height:0];
        SCNTorus *cushion = [SCNTorus torusWithRingRadius:r * 0.94f pipeRadius:0.004f];
        cushion.ringSegmentCount = 48;
        cushion.pipeSegmentCount = 10;
        [self addNodeWithGeometry:cushion material:rubber].position = [self at:bumper.position height:0.014f];

        simd_float2 capProfile[] = { {r, 0.046f}, {r, 0.057f}, {r * 0.94f, 0.063f},
                                    {r * 0.70f, 0.067f}, {r * 0.28f, 0.070f}, {0.0001f, 0.071f} };
        SCNGeometry *cap = [PBGeometry latheWithProfile:capProfile count:6 segments:64];
        PBBumperView *view = [PBBumperView new];
        view.idle = [self printedMaterial:@"bumper_cap"];
        view.lit = [view.idle copy];
        view.lit.diffuse.contents = (__bridge id)hitImage;
        view.lit.emission.contents = (__bridge id)hitImage;
        view.lit.emission.intensity = authoredHit ? 0.22 : 0.7;
        view.cap = [self addNodeWithGeometry:cap material:view.idle];
        view.cap.name = [@"bumper." stringByAppendingString:bumper.identifier];
        view.cap.position = [self at:bumper.position height:0];
        view.paintedGeometry = @[cap];
        [_bumpers addObject:view];

        SCNTorus *rim = [SCNTorus torusWithRingRadius:r * 0.985f pipeRadius:0.0018f];
        rim.ringSegmentCount = 64;
        rim.pipeSegmentCount = 8;
        rim.firstMaterial = accent;
        SCNNode *rimNode = [SCNNode nodeWithGeometry:rim];
        rimNode.position = SCNVector3Make(0, 0.059f, 0);
        [view.cap addChildNode:rimNode];
    }
}

- (void)buildSlingshots {
    _slingBands = [NSMutableArray array];
    SCNMaterial *rubber = [self blackRubber];
    for (PBEdgeDef *sling in _table.slingshots) {
        simd_float2 mid = (sling.a + sling.b) * 0.5f;
        SCNVector3 points[2] = { [self at:sling.a - mid height:0.0f], [self at:sling.b - mid height:0.0f] };
        // Offsets from the band's midpoint: strip the table-centring out of them.
        SCNVector3 centre = [self at:simd_make_float2(0, 0) height:0.0f];
        for (int i = 0; i < 2; i++) { points[i].x -= centre.x; points[i].z -= centre.z; }
        SCNGeometry *tube = [PBGeometry tubeAlongPoints:points count:2 radius:0.0052f sides:10];
        SCNNode *band = [self addNodeWithGeometry:tube material:rubber];
        band.position = [self at:mid height:0.012f];
        [_slingBands addObject:band];
    }
}

- (void)buildFlippers {
    _flipperNodes = [NSMutableArray array];
    SCNMaterial *bat = [self printedMaterial:@"flipper"];
    bat.diffuse.wrapS = SCNWrapModeClamp;
    bat.diffuse.wrapT = SCNWrapModeClamp;
    SCNMaterial *side = [self pbrWithDiffuse:[self color:simd_make_float3(0.85f, 0.85f, 0.88f)] metalness:0.0 roughness:0.35];
    SCNMaterial *metal = [self metal];
    SCNMaterial *rubberBand = [self pbrWithDiffuse:[self color:_skin.flipperRubberColor] metalness:0.0 roughness:0.55];

    const float height = 0.038f;
    for (PBFlipperDef *def in _table.flippers) {
        SCNNode *pivot = [SCNNode node];
        pivot.position = [self at:def.pivot height:0.0f];
        pivot.eulerAngles = SCNVector3Make(0, def.restAngle, 0);
        [_root addChildNode:pivot];
        [_flipperNodes addObject:pivot];

        SCNNode *model = [_models nodeNamed:[_table.identifier stringByAppendingString:@"-flipper"]];
        if (model) {
            [self skinModel:model overrides:@{}];
            model.scale = SCNVector3Make(def.length, def.length, def.length);
            [pivot addChildNode:model];
            continue;
        }

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

/// The art goes on a broad top, since the overhead camera never sees a target's face.
- (SCNNode *)addTargetFrom:(simd_float2)a to:(simd_float2)b art:(SCNMaterial *)art {
    SCNNode *model = [_models nodeNamed:@"target"];
    if (!model) return [self addEdgePartFrom:a to:b thickness:0.012f height:0.05f material:art];
    [self skinModel:model overrides:@{ @"target_art": art }];
    float width = simd_distance(a, b);
    model.scale = SCNVector3Make(width, 0.05f, width);
    model.position = [self at:(a + b) * 0.5f height:0.0f];
    model.eulerAngles = SCNVector3Make(0, atan2f(b.y - a.y, b.x - a.x), 0);
    [_root addChildNode:model];
    return model;
}

- (void)buildTargets {
    SCNMaterial *drop = [self printedMaterial:@"drop_target"];
    SCNMaterial *standup = [self printedMaterial:@"standup"];

    _dropNodes = [NSMutableArray array];
    for (PBEdgeDef *def in _table.dropTargets) {
        simd_float2 inset = simd_normalize(def.b - def.a) * 0.0015f;
        [_dropNodes addObject:[self addTargetFrom:def.a + inset to:def.b - inset art:drop]];
    }

    _standupNodes = [NSMutableArray array];
    SCNMaterial *metal = [self metal];
    for (PBEdgeDef *def in _table.standups) {
        [_standupNodes addObject:[self addTargetFrom:def.a to:def.b art:standup]];
    }

    // Kickback plungers are visible at the bottom of their lanes.
    for (PBSpotDef *kick in _table.kickbacks) {
        if ([self addModel:@"stud" at:kick.position - simd_make_float2(0.0f, 0.035f) height:0 scale:0.012f]) continue;
        SCNCylinder *head = [SCNCylinder cylinderWithRadius:0.016f height:0.02f];
        // Dull steel: its flat top faces the camera, and polished metal would flare.
        SCNNode *node = [self addNodeWithGeometry:head material:[self pbrWithDiffuse:[self color:_skin.metalColor * 0.35f] metalness:0.6 roughness:0.6]];
        node.position = [self at:kick.position - simd_make_float2(0.0f, 0.035f) height:0.01f];
    }
}

- (void)buildSpinnersAndGates {
    SCNMaterial *metal = [self metal];
    SCNMaterial *plate = [self printedMaterial:@"spinner"];

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

    // Slim and dull: a polished rod across the table reads as a stray bright line.
    SCNMaterial *wireMetal = [self pbrWithDiffuse:[self color:_skin.accentColor * 0.6f] metalness:0.7 roughness:0.55];
    _gatePlates = [NSMutableArray array];
    for (PBEdgeDef *def in _table.gates) {
        float width = simd_distance(def.a, def.b);
        SCNNode *pivot = [SCNNode node];
        pivot.position = [self at:(def.a + def.b) * 0.5f height:0.05f];
        pivot.eulerAngles = SCNVector3Make(0, atan2f(def.b.y - def.a.y, def.b.x - def.a.x), 0);
        [_root addChildNode:pivot];
        SCNCylinder *rod = [SCNCylinder cylinderWithRadius:0.0016f height:width];
        rod.firstMaterial = wireMetal;
        SCNNode *rodNode = [SCNNode nodeWithGeometry:rod];
        rodNode.eulerAngles = SCNVector3Make(0, 0, (float)M_PI_2);
        [pivot addChildNode:rodNode];
        SCNCylinder *wire = [SCNCylinder cylinderWithRadius:0.0011f height:width * 0.96f];
        wire.firstMaterial = wireMetal;
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

        NSString *asset = [NSString stringWithFormat:@"%@-%@", _table.identifier, ramp.identifier];
        SCNNode *channel = [_models nodeNamed:asset];
        if (channel) {
            [self skinModel:channel overrides:@{}];
            [_root addChildNode:channel];
        } else {
            // Plastic section: see-through, tinted by the skin's ramp art.
            SCNGeometry *plastic = [PBGeometry rampFromPoints:points count:plasticEnd + 1 width:ramp.width sideHeight:0.022f tableSize:_size];
            SCNMaterial *material = [SCNMaterial material];
            material.lightingModelName = SCNLightingModelBlinn;
            material.diffuse.contents = (__bridge id)[_skin imageForSlot:@"ramp"];
            material.diffuse.wrapS = SCNWrapModeRepeat;
            material.diffuse.wrapT = SCNWrapModeRepeat;
            material.specular.contents = [self color:simd_make_float3(0.5f, 0.5f, 0.5f)];
            material.shininess = 60.0;
            material.transparency = _skin.rampOpacity;
            material.doubleSided = YES;
            material.writesToDepthBuffer = NO;
            SCNNode *plasticNode = [self addNodeWithGeometry:plastic material:material];
            plasticNode.castsShadow = YES;
            for (int side = -1; side <= 1; side += 2) {
                NSMutableData *edge = [NSMutableData data];
                for (NSInteger i = 0; i <= plasticEnd; i++) {
                    simd_float2 tangent = simd_normalize(points[MIN(i + 1, count - 1)].xy - points[MAX(i - 1, 0)].xy);
                    simd_float2 normal = simd_make_float2(-tangent.y, tangent.x);
                    SCNVector3 v = [self at:points[i].xy + normal * (ramp.width * 0.5f * side) height:points[i].z + 0.022f];
                    [edge appendBytes:&v length:sizeof(v)];
                }
                [self addNodeWithGeometry:[PBGeometry tubeAlongPoints:edge.bytes count:plasticEnd + 1 radius:0.0017f sides:8]
                                material:[self accentMetal]];
            }

        }

        // The model carries its own flanges, clamps and supports.
        if (channel) continue;

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
        // A ramp may be plastic all the way, leaving no wire section to draw.
        if (wireCount >= 2) {
            [self addNodeWithGeometry:[PBGeometry tubeAlongPoints:leftPoints count:wireCount radius:0.0034f sides:8] material:metal];
            [self addNodeWithGeometry:[PBGeometry tubeAlongPoints:rightPoints count:wireCount radius:0.0034f sides:8] material:metal];
        }
        for (NSInteger i = 4; i < wireCount; i += 8) {
            SCNVector3 mid = SCNVector3Make((leftPoints[i].x + rightPoints[i].x) * 0.5f,
                                          leftPoints[i].y + 0.009f, (leftPoints[i].z + rightPoints[i].z) * 0.5f);
            SCNVector3 hoop[] = { leftPoints[i], mid, rightPoints[i] };
            [self addNodeWithGeometry:[PBGeometry tubeAlongPoints:hoop count:3 radius:0.0017f sides:6] material:metal];
        }

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

- (SCNMaterial *)litMaterialForArrowWithColor:(NSString *)colorName {
    NSString *key = [@"arrow/" stringByAppendingString:colorName];
    SCNMaterial *material = _litMaterials[key];
    if (material) return material;
    CGImageRef image = [PBPlayfieldPainter newLitArrowWithColor:[_skin lampColor:colorName]];
    material = [self additiveMaterial:image intensity:2.4];
    CGImageRelease(image);
    _litMaterials[key] = material;
    return material;
}

- (void)buildLamps {
    _lamps = [NSMutableArray array];
    SCNMaterial *rimMaterial = [self accentMetal];
    for (PBLampDef *def in _table.lamps) {
        SCNNode *socket = [self addModel:def.isArrow ? @"insert-arrow" : @"insert-bezel" at:def.position height:0 scale:def.size];
        if (socket) {
            socket.eulerAngles = SCNVector3Make(0, def.angle, 0);
        } else {
            SCNTorus *rim = [SCNTorus torusWithRingRadius:def.size + 0.0013f pipeRadius:0.0009f];
            rim.ringSegmentCount = 32;
            rim.pipeSegmentCount = 6;
            [self addNodeWithGeometry:rim material:rimMaterial].position = [self at:def.position height:0.0008f];
        }
        SCNMaterial *litMaterial = def.isArrow ? [self litMaterialForArrowWithColor:def.color] : [self litMaterialForIcon:def.icon color:def.color];
        SCNNode *node = [self spriteOfSize:def.size * 2.0f * 2.4f material:litMaterial];
        node.position = [self at:def.position height:0.0015f];
        // The sprite lies flat, so its own z runs along the table's up axis.
        if (def.isArrow) node.eulerAngles = SCNVector3Make(-(float)M_PI_2, def.angle, 0);
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
    const float domeHeight = _models ? 0.11f : 0.13f;
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

        if (![self addModel:@"flasher-cage" at:def.position height:domeHeight scale:0.034f]) {
            SCNCylinder *foot = [SCNCylinder cylinderWithRadius:0.034f height:0.008f];
            [self addNodeWithGeometry:foot material:metal].position = [self at:def.position height:domeHeight];
        }

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

#pragma mark - Decor

- (void)buildDecor {
    for (PBDecorDef *decor in _table.decor) {
        SCNNode *model = [_models nodeNamed:decor.model];
        if (!model) continue;
        [self skinModel:model overrides:@{}];
        model.scale = SCNVector3Make(decor.size, decor.size, decor.size);
        model.position = [self at:decor.position height:decor.base];
        model.eulerAngles = SCNVector3Make(0, decor.angle, 0);
        [_root addChildNode:model];
    }
}

#pragma mark - Plunger, balls

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

    for (NSUInteger i = 0; i < _bumpers.count; i++) {
        float flash = expf(-[world bumperFlash:(NSInteger)i] * 9.0f);
        _bumperLights[i].intensity = flash * 28.0f;
        PBBumperView *bumper = _bumpers[i];
        BOOL illuminated = flash > 0.12f;
        if (illuminated != bumper.illuminated) {
            // Use the two authored atlas states directly; never recolour the cap artwork.
            for (SCNGeometry *geometry in bumper.paintedGeometry) geometry.firstMaterial = illuminated ? bumper.lit : bumper.idle;
            bumper.illuminated = illuminated;
        }
        bumper.cap.position = [self at:_table.bumpers[i].position height:-0.002f * flash];
    }

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
        flasher.light.intensity = level * 160.0f;
        flasher.dome.emission.intensity = 0.08 + level * 2.2;
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
    _cameraNode.position = SCNVector3Make(_baseCameraPosition.x - nudge.x * 0.01f + shakeOffset, _baseCameraPosition.y,
                                         _baseCameraPosition.z + nudge.y * 0.01f - shakeOffset * 0.6f);
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
