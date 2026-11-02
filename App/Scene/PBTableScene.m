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

/// Glowing parts light what is around them, and put a rim on it. SceneKit lights are too costly for
/// every lamp and take no rim, so the sources go to the shader as one block, brightest first.
enum { kPBGlowSources = 16 };  // Also spelled out in the shader below.
typedef struct {
    simd_float4 position[kPBGlowSources];  // World position, then range.
    simd_float4 color[kPBGlowSources];     // Colour by strength. Alpha is zero after the last source.
} PBGlowBlock;

static NSString *const kPBGlowDeclaration = @"struct PBGlowBlock { float4 position[16]; float4 color[16]; };\n";

/// Sums the sources into pbGlowLit. The base term lets a dark surface still show a pool of light.
static NSString *PBGlowBody(float base) {
    return [NSString stringWithFormat:
            @"float3 pbGlowN = normalize((scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz);\n"
            @"float3 pbGlowV = normalize((scn_frame.inverseViewTransform * float4(_surface.view, 0.0)).xyz);\n"
            @"float3 pbGlowP = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;\n"
            @"float3 pbGlowLit = float3(0.0);\n"
            @"float3 pbGlowAlbedo = min(_surface.diffuse.rgb, float3(1.0));\n"
            @"float pbGlowFacing = pow(1.0 - saturate(dot(pbGlowN, pbGlowV)), 2.5);\n"
            @"for (int pbI = 0; pbI < 16; pbI++) {\n"
            @"  float4 pbTint = pbGlow.color[pbI];\n"
            @"  if (pbTint.a <= 0.0) break;\n"
            @"  float3 pbToLight = pbGlow.position[pbI].xyz - pbGlowP;\n"
            @"  float pbDistance = length(pbToLight);\n"
            @"  float pbFade = saturate(1.0 - pbDistance / pbGlow.position[pbI].w);\n"
            @"  if (pbFade <= 0.0) continue;\n"
            @"  pbFade *= pbFade;\n"
            @"  float pbFacing = dot(pbGlowN, pbToLight / max(pbDistance, 0.001));\n"
            @"  float pbWrap = saturate(pbFacing * 0.75 + 0.25);\n"
            @"  float pbRim = pbGlowFacing * saturate(pbFacing + 0.6);\n"
            @"  pbGlowLit += pbTint.rgb * pbFade * (pbWrap * (pbGlowAlbedo + %f) + pbRim * 2.0);\n"
            @"}\n", base];
}

static NSString *PBGlowModifier(void) {
    return [NSString stringWithFormat:@"#pragma declaration\n%@#pragma arguments\nPBGlowBlock pbGlow;\n#pragma body\n%@_output.color.rgb += pbGlowLit;\n%@",
            kPBGlowDeclaration, PBGlowBody(0.05f), kPBHDRGuard];
}

static const NSUInteger kPBNotReflected = 1u << 3;

/// SCNFloor ignores overridden texcoords, so the floor samples its art by world position
/// in a surface modifier instead.
static NSString *PBFloorSurfaceModifier(simd_float2 size) {
    return [NSString stringWithFormat:
            @"#pragma declaration\n%@"
            @"#pragma arguments\n"
            @"texture2d<float> pbPlayfield;\n"
            @"PBGlowBlock pbGlow;\n"
            @"#pragma body\n"
            @"constexpr sampler pbSampler(coord::normalized, address::mirrored_repeat, filter::linear, mip_filter::linear, max_anisotropy(8));\n"
            @"float3 pbP = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;\n"
            @"float2 pbUV = float2(pbP.x / %f + 0.5, pbP.z / %f + 0.5);\n"
            // The tilted board leaves a band above its far end: the art carries on there, dimmed.
            @"_surface.diffuse = pbPlayfield.sample(pbSampler, pbUV);\n"
            @"_surface.diffuse.rgb *= 1.0 - 0.92 * saturate(-pbUV.y / 0.06);\n"
            // In the surface stage: a fragment modifier on SCNFloor loses its planar reflection.
            @"%@_surface.emission.rgb += pbGlowLit;\n", kPBGlowDeclaration, size.x, size.y, PBGlowBody(0.14f)];
}

/// The tops of the solid walls and floors show the board's art beneath them, lifted by the skin's
/// wall colour so they stand out from it. Their sides stay plain, to read as an edge.
static NSString *PBShellSurfaceModifier(simd_float2 size) {
    return [NSString stringWithFormat:
            @"#pragma arguments\n"
            @"texture2d<float> pbPlayfield;\n"
            @"#pragma body\n"
            @"constexpr sampler pbSampler(coord::normalized, address::mirrored_repeat, filter::linear, mip_filter::linear, max_anisotropy(8));\n"
            @"float3 pbP = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;\n"
            @"float3 pbN = (scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz;\n"
            @"float3 pbArt = pbPlayfield.sample(pbSampler, float2(pbP.x / %f + 0.5, pbP.z / %f + 0.5)).rgb;\n"
            @"_surface.diffuse.rgb = mix(_surface.diffuse.rgb, pbArt * 2.8 + _surface.diffuse.rgb * 0.8, smoothstep(0.5, 0.9, pbN.y));\n", size.x, size.y];
}

/// A MatCap: the look of polished metal is read from a captured sphere by the surface's facing
/// alone. The normal turns with the room as the phone tilts, so the highlights slide across the parts.
static NSString *const kPBMatcapModifier =
    @"#pragma arguments\n"
    @"texture2d<float> pbMatcap;\n"
    @"float4x4 pbRoom;\n"
    @"float pbBlur;\n"
    @"float pbGloss;\n"
    @"float pbSatin;\n"
    @"float pbGain;\n"
    @"#pragma body\n"
    @"constexpr sampler pbSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);\n"
    @"float3 pbN = (scn_frame.inverseViewTransform * float4(normalize(_surface.normal), 0.0)).xyz;\n"
    @"pbN = (pbRoom * float4(pbN, 0.0)).xyz;\n"
    @"pbN = normalize((scn_frame.viewTransform * float4(pbN, 0.0)).xyz);\n"
    @"float2 pbUV = float2(pbN.x, -pbN.y) * 0.492 + 0.5;\n"
    // Deep shadows and clipped peaks: a metal's highlights go past its own colour, toward white,
    // and over 1 they feed the bloom.
    @"float3 pbRoomColor = pbMatcap.sample(pbSampler, pbUV, bias(pbBlur)).rgb;\n"
    @"float pbLight = dot(pbRoomColor, float3(0.2126, 0.7152, 0.0722));\n"
    @"float pbCap = smoothstep(0.04, 0.86, pbLight) * (0.5 + 0.5 * pbGloss);\n"
    @"float3 pbHue = pbRoomColor / max(pbLight, 0.02);\n"
    @"float3 pbTint = _surface.diffuse.rgb;\n"
    @"float3 pbMetal = pbTint * pbHue * (0.06 + 1.1 * pbCap) + mix(pbTint * pbHue, float3(1.0), 0.45) * 1.4 * pbGloss * pow(pbCap, 5.0);\n"
    @"_surface.diffuse.rgb = mix(pbMetal, pbTint * (0.85 + 0.30 * pbLight) + pbMetal * 0.16, pbSatin) * pbGain;\n";

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

/// HDR levels for a bumper: the bulb always burns past the bloom threshold; the star idles under it.
static const float kPBBulbGlow = 2.4f;
static const float kPBStarIdleGlow = 0.35f;
static const float kPBStarFlashEnd = 0.12f;

@interface PBBumperView : NSObject
@property (nonatomic, strong) SCNNode *cap;
@property (nonatomic, strong) SCNMaterial *idle;
@property (nonatomic, strong) SCNMaterial *lit;
@property (nonatomic, strong) SCNMaterial *bulb;
@property (nonatomic) BOOL illuminated;
@property (nonatomic) float capScale;
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
    NSMutableArray<SCNMaterial *> *_matcapMaterials;
    SCNMaterial *_accentMaterial, *_metalMaterial;
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
    NSArray<SCNMaterial *> *_slingLenses;
    NSMutableArray<SCNNode *> *_stopperNodes;
    NSMutableArray<SCNMaterial *> *_standupLenses;
    NSMutableArray<SCNMaterial *> *_glowMaterials;
    NSData *_glowBlock;
    NSMutableDictionary<NSString *, SCNMaterial *> *_litMaterials;

    NSArray *_rampChaseStates;
    NSMutableArray<SCNMaterial *> *_rampChaseMaterials;
    NSInteger _rampChasePhase;
    SCNMaterial *_guideGlowMaterial;

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
    // MatCap supplies the room reflection; Blinn also receives local coloured lamps and shadows.
    material.lightingModelName = SCNLightingModelBlinn;
    material.diffuse.contents = [self color:color];
    material.specular.contents = [self color:simd_make_float3(0.18f, 0.18f, 0.18f)];
    material.shininess = 64;
    material.shaderModifiers = @{ SCNShaderModifierEntryPointSurface: kPBMatcapModifier,
                                  SCNShaderModifierEntryPointFragment: kPBHDRGuard };
    NSURL *url = [_skin.resourceBundle URLForResource:[@"matcap-" stringByAppendingString:name] withExtension:@"png" subdirectory:@"GameData/Materials"];
    NSAssert(url, @"Missing MatCap %@", name);
    SCNMaterialProperty *capture = [SCNMaterialProperty materialPropertyWithContents:url];
    capture.mipFilter = SCNFilterModeLinear;
    [material setValue:capture forKey:@"pbMatcap"];
    [material setValue:[NSValue valueWithSCNMatrix4:SCNMatrix4Identity] forKey:@"pbRoom"];
    [material setValue:@0.0f forKey:@"pbBlur"];
    [material setValue:@1.0f forKey:@"pbGloss"];
    [material setValue:@0.0f forKey:@"pbSatin"];
    [material setValue:@1.0f forKey:@"pbGain"];
    if (!_matcapMaterials) _matcapMaterials = [NSMutableArray array];
    [_matcapMaterials addObject:material];
    return material;
}

/// Lets a material receive light from the glowing parts around it.
- (void)receiveGlow:(SCNMaterial *)material {
    if (!_glowMaterials) _glowMaterials = [NSMutableArray array];
    if ([_glowMaterials containsObject:material]) return;
    NSMutableDictionary *modifiers = [material.shaderModifiers mutableCopy] ?: [NSMutableDictionary dictionary];
    modifiers[SCNShaderModifierEntryPointFragment] = PBGlowModifier();
    material.shaderModifiers = modifiers;
    PBGlowBlock none = {0};
    [material setValue:[NSData dataWithBytes:&none length:sizeof(none)] forKey:@"pbGlow"];
    [_glowMaterials addObject:material];
}

// One shared material each, so a tilt updates only a handful of materials per frame.
- (SCNMaterial *)accentMetal {
    if (!_accentMaterial) {
        _accentMaterial = [self matcapNamed:_skin.hardwareMatcap color:_skin.accentColor];
        // Satin, so rails and brackets stay bright gold wherever the room is dark.
        [_accentMaterial setValue:@0.5f forKey:@"pbSatin"];
        [_accentMaterial setValue:@1.32f forKey:@"pbGain"];
    }
    return _accentMaterial;
}

- (SCNMaterial *)metal {
    if (!_metalMaterial) {
        _metalMaterial = [self matcapNamed:_skin.hardwareMatcap color:_skin.metalColor];
        [_metalMaterial setValue:@0.35f forKey:@"pbSatin"];
        [_metalMaterial setValue:@1.2f forKey:@"pbGain"];
    }
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

/// Models carry semantic material names (roles) so a single mesh kit serves every skin.
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
        slingLens.emission.intensity = 0.15;
        CGImageRelease(lensImage);
        // Dark glass, as an unlit lamp is, until the ball hits it.
        SCNMaterial *targetLens = [slingLens copy];
        targetLens.name = @"target_lens";
        targetLens.diffuse.intensity = 0.16;
        // Matte: a gloss highlight from the key light would read as lit.
        targetLens.lightingModelName = SCNLightingModelLambert;
        targetLens.emission.intensity = 0;
        // One each, as a hit lights only the bouncer that was hit.
        _slingLenses = @[ [slingLens copy], [slingLens copy] ];
        CGImageRef amberImage = [PBPlayfieldPainter newLensWithColor:[_skin lampColor:@"amber"]];
        SCNMaterial *amberLens = [self pbrWithDiffuse:(__bridge id)amberImage metalness:0 roughness:0.16];
        amberLens.emission.contents = (__bridge id)amberImage;
        amberLens.emission.intensity = 0.3;
        CGImageRelease(amberImage);
        // The dark enamel bed sits under a full-length deck of authored chevron tiles.
        SCNMaterial *rampFloor = [self matcapNamed:_skin.rampMatcap color:_skin.rampGlassColor * 0.90f];
        rampFloor.name = @"ramp_floor";
        [rampFloor setValue:@(_skin.rampBlur) forKey:@"pbBlur"];
        [rampFloor setValue:@(_skin.rampGloss) forKey:@"pbGloss"];
        [rampFloor setValue:@1.0f forKey:@"pbSatin"];
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
        simd_float3 wallColor = _skin.shellColor;
        SCNMaterial *shell = [SCNMaterial material];
        shell.lightingModelName = SCNLightingModelBlinn;
        shell.diffuse.contents = [self color:wallColor];
        shell.specular.contents = [self color:simd_make_float3(.13f, .15f, .18f)];
        shell.shininess = 28;
        shell.shaderModifiers = @{ SCNShaderModifierEntryPointSurface: PBShellSurfaceModifier(_size) };
        SCNMaterialProperty *shellArt = [SCNMaterialProperty materialPropertyWithContents:(__bridge id)_playfieldImage];
        shellArt.mipFilter = SCNFilterModeLinear;
        [shell setValue:shellArt forKey:@"pbPlayfield"];
        // Upright inward faces need their own light-responsive finish: grazing-angle MatCaps
        // made them almost black against the dark arrow deck from the actual game camera.
        SCNMaterial *liner = [SCNMaterial material];
        liner.name = @"channel_liner";
        liner.lightingModelName = SCNLightingModelBlinn;
        liner.diffuse.contents = [self color:simd_make_float3(.29f, .35f, .40f)];
        liner.specular.contents = [self color:simd_make_float3(.38f, .42f, .46f)];
        liner.shininess = 44;
        liner.shaderModifiers = @{ SCNShaderModifierEntryPointFragment: kPBHDRGuard };
        SCNMaterial *aluminum = [liner copy];
        aluminum.name = @"channel_aluminum";
        aluminum.diffuse.contents = [self color:simd_make_float3(.66f, .71f, .75f)];
        aluminum.specular.contents = [self color:simd_make_float3(.38f, .42f, .46f)];
        aluminum.shininess = 52;
        // Matte: a flat plate facing the camera turns blotchy under a MatCap's reflections.
        SCNMaterial *plateFrame = [SCNMaterial material];
        plateFrame.name = @"plate_frame";
        plateFrame.lightingModelName = SCNLightingModelLambert;
        plateFrame.diffuse.contents = [self color:simd_make_float3(.74f, .75f, .78f)];
        // Brushed aluminum: its streaks run along the ramp, and tint the room it reflects.
        SCNMaterial *floor = [self matcapNamed:@"studio" color:simd_make_float3(.52f, .57f, .61f)];
        floor.name = @"channel_floor";
        floor.diffuse.contents = [_skin.resourceBundle URLForResource:@"brushed-aluminum" withExtension:@"png" subdirectory:@"GameData/Materials"];
        floor.diffuse.wrapS = SCNWrapModeRepeat;
        floor.diffuse.wrapT = SCNWrapModeClamp;
        floor.diffuse.mipFilter = SCNFilterModeLinear;
        floor.diffuse.maxAnisotropy = 8;
        [floor setValue:@0.7f forKey:@"pbSatin"];
        [floor setValue:@1.5f forKey:@"pbGain"];
        [floor setValue:@1.2f forKey:@"pbBlur"];
        [floor setValue:@0.45f forKey:@"pbGloss"];
        floor.shininess = 48;
        // The entrance's floor is the same brushed metal in the skin's gold, leading onto the aluminum.
        SCNMaterial *entry = [self matcapNamed:@"studio" color:simd_make_float3(.52f, .57f, .61f)];
        entry.name = @"channel_entry";
        entry.diffuse.contents = floor.diffuse.contents;
        entry.diffuse.wrapS = SCNWrapModeRepeat;
        entry.diffuse.wrapT = SCNWrapModeClamp;
        entry.diffuse.mipFilter = SCNFilterModeLinear;
        entry.diffuse.maxAnisotropy = 8;
        entry.multiply.contents = [self color:_skin.accentColor * simd_make_float3(1.0f, .92f, .8f)];
        [entry setValue:@0.7f forKey:@"pbSatin"];
        [entry setValue:@1.2f forKey:@"pbBlur"];
        [entry setValue:@0.45f forKey:@"pbGloss"];
        [entry setValue:@1.5f forKey:@"pbGain"];
        // The ramp's outer walls are solid colour under the gold rail, and the camera sees them.
        SCNMaterial *channelShell = [liner copy];
        channelShell.name = @"channel_shell";
        channelShell.diffuse.contents = [self color:wallColor];
        channelShell.specular.contents = [self color:simd_make_float3(.3f, .3f, .3f)];
        SCNMaterial *channelArrow = [slingLens copy];
        channelArrow.name = @"channel_arrow";
        _guideGlowMaterial = [amber copy];
        _guideGlowMaterial.diffuse.intensity = 1.25;
        // The laser-cut covers: one flat matte colour, lit by the room, so cut edges read as a board.
        SCNMaterial *cover = [SCNMaterial material];
        cover.name = @"cover";
        cover.lightingModelName = SCNLightingModelBlinn;
        cover.diffuse.contents = [self color:_skin.coverColor];
        cover.specular.contents = [self color:simd_make_float3(.12f, .12f, .12f)];
        cover.shininess = 0.2;
        _modelMaterials = @{
            @"metal": [self metal], @"accent": [self accentMetal], @"rubber": [self rubber],
            @"dark": dark, @"channel_liner": liner, @"plate_frame": plateFrame, @"channel_floor": floor, @"channel_entry": entry, @"channel_aluminum": aluminum,
            @"channel_shell": channelShell, @"channel_arrow": channelArrow,
            @"cabinet_shell": shell, @"guide_glow": _guideGlowMaterial, @"cover": cover,
            @"glow_amber": amber, @"jewel": jewel, @"skirt_lamp": skirtLamp, @"black_rubber": [self blackRubber], @"amber_lens": amberLens, @"sling_lens": slingLens, @"sling_lens_0": _slingLenses[0], @"sling_lens_1": _slingLenses[1], @"target_lens": targetLens, @"ramp_floor": rampFloor, @"enamel": enamel,
            @"cap_art": [self printedMaterial:@"bumper_cap"],
            @"lens": lens,
            @"glow": glow, @"wall_art": wallArt, @"block_art": blockArt, @"flipper_art": bat,
            @"target_art": [self printedMaterial:@"drop_target"],
        };
        for (NSString *role in @[ @"metal", @"accent", @"rubber", @"dark", @"channel_liner", @"channel_floor", @"channel_entry", @"channel_aluminum", @"channel_shell",
                                  @"cabinet_shell", @"black_rubber", @"enamel", @"flipper_art", @"cover" ]) {
            [self receiveGlow:_modelMaterials[role]];
        }
        if ([_skin hasImageForSlot:@"ramp_chase_off"]) {
            NSMutableArray *states = [NSMutableArray array];
            for (NSString *slot in @[ @"ramp_chase_off", @"ramp_chase_1", @"ramp_chase_2", @"ramp_chase_3", @"ramp_chase_4" ]) {
                [states addObject:(__bridge id)[_skin imageForSlot:slot]];
            }
            _rampChaseStates = states;
            _rampChaseMaterials = [NSMutableArray array];
            _rampChasePhase = -1;
            NSMutableDictionary *mapped = [_modelMaterials mutableCopy];
            for (NSInteger group = 0; group < 4; group++) {
                SCNMaterial *deck = [SCNMaterial material];
                deck.name = [NSString stringWithFormat:@"ramp_step_%ld", (long)group];
                deck.lightingModelName = SCNLightingModelBlinn;
                deck.diffuse.contents = deck.emission.contents = states[0];
                deck.emission.intensity = .24;
                deck.specular.contents = [self color:simd_make_float3(.12f, .12f, .12f)];
                deck.shininess = 40;
                deck.diffuse.wrapS = deck.diffuse.wrapT = SCNWrapModeClamp;
                deck.diffuse.maxAnisotropy = 8;
                deck.shaderModifiers = @{ SCNShaderModifierEntryPointFragment: kPBHDRGuard };
                mapped[deck.name] = deck;
                [_rampChaseMaterials addObject:deck];
            }
            _modelMaterials = mapped;
            [self updateRampChase];
        }
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

- (void)addCommonModel:(NSString *)suffix {
    SCNNode *model = [_models nodeNamed:[@"common-" stringByAppendingString:suffix]];
    if (!model) return;
    [self skinModel:model overrides:@{}];
    [_root addChildNode:model];
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
    // Low against the key: a shadow shows only as dark as the ambient light leaves it, and shows the parts' height.
    ambient.intensity = 240.0f * _skin.ambient;
    ambient.color = [self color:simd_make_float3(0.92f, 0.92f, 1.0f)];
    SCNNode *ambientNode = [SCNNode node];
    ambientNode.light = ambient;
    [_root addChildNode:ambientNode];

    SCNLight *key = [SCNLight light];
    key.type = SCNLightTypeSpot;
    key.intensity = _skin.keyIntensity * 0.72f;
    key.color = [self color:_skin.keyColor];
    key.spotInnerAngle = 50;
    key.spotOuterAngle = 86;
    key.attenuationStartDistance = 0;
    key.attenuationEndDistance = 0;
    key.castsShadow = YES;
    key.shadowMapSize = CGSizeMake(2048, 2048);
    key.shadowSampleCount = 8;
    key.shadowRadius = 1.8;
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
                                                 color:[_skin lampColor:@"bumper"] range:0.38f]];
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
    simd_float2 padding = _table.padding;
    // A phone sees the table's width plus its padding, with the bottom padding under the flippers.
    // A much squarer screen sees the whole table instead, framed by the cabinet.
    CGFloat visibleHeight = heightOverWidth >= 1.9 ? ((CGFloat)_size.x + 2 * padding.x) * heightOverWidth : span + 2 * padding.y * cos(tilt);
    _camera.orthographicScale = visibleHeight * 0.5;
    CGFloat aim = -(visibleHeight - span) * 0.5 / cos(tilt) + padding.y;
    const CGFloat distance = 6.0;
    _baseCameraPosition = SCNVector3Make(0, distance * cos(tilt), aim + distance * sin(tilt));
    _cameraNode.position = _baseCameraPosition;
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
    floor.reflectionCategoryBitMask = ~(NSUInteger)kPBNotReflected;

    // Lambert, not PBR: with the camera straight above, a specular highlight from the
    // overhead light would burn out the middle of the art. Gloss comes from the reflections.
    SCNMaterial *material = [SCNMaterial material];
    material.lightingModelName = SCNLightingModelLambert;
    material.diffuse.contents = [self color:simd_make_float3(1.0f, 1.0f, 1.0f)];
    material.shaderModifiers = @{ SCNShaderModifierEntryPointSurface: PBFloorSurfaceModifier(_size) };
    PBGlowBlock noGlow = {0};
    [material setValue:[NSData dataWithBytes:&noGlow length:sizeof(noGlow)] forKey:@"pbGlow"];
    if (!_glowMaterials) _glowMaterials = [NSMutableArray array];
    [_glowMaterials addObject:material];
    SCNMaterialProperty *art = [SCNMaterialProperty materialPropertyWithContents:(__bridge id)_playfieldImage];
    art.mipFilter = SCNFilterModeLinear;
    [material setValue:art forKey:@"pbPlayfield"];
    floor.firstMaterial = material;
    [self addNodeWithGeometry:floor material:nil];
}

- (void)buildCabinet {
    // The phone's own edge is the table's edge. This frame stands just outside the view, and
    // only shows on a screen of different proportions, in place of stretched playfield art.
    // Its far side stands well back: the tilted camera sees past the board's far end on a phone.
    const float margin = 0.6f;
    const float far = _size.y + 0.75f;
    // Past the padding, which the table's cover fills.
    const float inset = _table.padding.x + 0.1f;
    simd_float2 outline[] = {
        { -margin, -margin }, { -inset, -margin }, { -inset, far }, { _size.x + inset, far }, { _size.x + inset, -margin },
        { _size.x + margin, -margin }, { _size.x + margin, far + margin }, { -margin, far + margin },
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
    // Parts every table has are shared models; a table's own may be none at all.
    [self addCommonModel:@"walls"];
    [self addCommonModel:@"cover"];
    [self addTableModel:@"cover"];
    [self addCommonModel:@"plastics"];
    [self addTableModel:@"walls"];
    // The plastics model carries raised housings as well as the free-floating plastics.
    [self addTableModel:@"plastics"];
    BOOL plated = [_models nodeNamed:@"common-walls"] != nil;
    BOOL housed = [_models nodeNamed:@"common-plastics"] != nil;
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

- (void)addHoleAt:(simd_float2)position radius:(float)radius height:(float)height {
    SCNCylinder *hole = [SCNCylinder cylinderWithRadius:radius height:0.001f];
    hole.radialSegmentCount = 40;
    SCNMaterial *black = [SCNMaterial material];
    black.lightingModelName = SCNLightingModelConstant;
    black.diffuse.contents = [self color:simd_make_float3(0.0f, 0.0f, 0.0f)];
    [self addNodeWithGeometry:hole material:black].position = [self at:position height:height + 0.001f];
}

- (void)buildPlayfieldHardware {
    SCNMaterial *trim = [self accentMetal];
    for (PBSpotDef *rollover in _table.rollovers) {
        if (!rollover.hasPlate) continue;
        SCNNode *plate = [self addModel:@"rollover-plate" at:rollover.position height:0.0005f scale:0.03f];
        // Too flat to shade: no shadow, and no mirror image in the polished playfield beside it.
        plate.castsShadow = NO;
        plate.categoryBitMask = kPBNotReflected;
        [plate enumerateChildNodesUsingBlock:^(SCNNode *child, BOOL *stop) {
            child.castsShadow = NO;
            child.categoryBitMask = kPBNotReflected;
        }];
    }
    for (PBSpotDef *saucer in _table.saucers) {
        SCNTorus *lip = [SCNTorus torusWithRingRadius:saucer.radius * 1.12f pipeRadius:0.003f];
        lip.ringSegmentCount = 48;
        lip.pipeSegmentCount = 8;
        float height = saucer.layers & PBLayerDeck ? _table.deckHeight : 0.0f;
        [self addNodeWithGeometry:lip material:trim].position = [self at:saucer.position height:height + 0.003f];
        if (saucer.layers & PBLayerDeck) [self addHoleAt:saucer.position radius:saucer.radius * 1.12f height:height];
        if (saucer.hasExit) {
            // Where the ball comes back up.
            SCNTorus *mouth = [SCNTorus torusWithRingRadius:_table.ballRadius * 1.1f pipeRadius:0.003f];
            mouth.ringSegmentCount = 40;
            mouth.pipeSegmentCount = 8;
            [self addNodeWithGeometry:mouth material:trim].position = [self at:saucer.exit height:0.003f];
            [self addHoleAt:saucer.exit radius:_table.ballRadius * 1.1f height:0.0f];
        }
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
            // Only the triangles give off light: the cream between them stays paint. They rest a
            // deep red, and a hit turns them orange: any paler and they wash into the cream.
            CGImageRef capImage = [PBPlayfieldPainter newBumperCapWithBase:_skin.capBaseColor star:_skin.capStarColor * 0.7f];
            simd_float3 none = simd_make_float3(0.0f, 0.0f, 0.0f);
            CGImageRef starImage = [PBPlayfieldPainter newBumperCapWithBase:none star:_skin.capStarColor];
            CGImageRef hotImage = [PBPlayfieldPainter newBumperCapWithBase:none star:simd_mix(_skin.capStarColor, simd_make_float3(1.0f, 0.55f, 0.2f), 0.35f)];
            view.idle = [self printedMaterial:@"bumper_cap"];
            view.idle.diffuse.contents = (__bridge id)capImage;
            view.idle.diffuse.intensity = 1.35;
            view.idle.emission.contents = (__bridge id)starImage;
            view.idle.emission.intensity = kPBStarIdleGlow;
            view.lit = [view.idle copy];
            view.lit.emission.contents = (__bridge id)hotImage;
            CGImageRelease(capImage);
            CGImageRelease(starImage);
            CGImageRelease(hotImage);
            [self skinModel:modelBase overrides:@{}];
            // One each, as a hit flares only the bumper that was hit.
            view.bulb = [_modelMaterials[@"jewel"] copy];
            [self skinModel:modelCap overrides:@{ @"cap_art": view.idle, @"jewel": view.bulb }];
            modelBase.scale = modelCap.scale = SCNVector3Make(r, r, r);
            modelBase.position = modelCap.position = [self at:bumper.position height:0];
            modelCap.name = [@"bumper." stringByAppendingString:bumper.identifier];
            NSMutableArray *painted = [NSMutableArray array];
            [modelCap enumerateChildNodesUsingBlock:^(SCNNode *node, BOOL *stop) {
                if ([node.geometry.name isEqualToString:@"cap_art"]) [painted addObject:node.geometry];
            }];
            view.cap = modelCap;
            view.capScale = r;
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
        view.capScale = 1.0f;
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
    // The kit's bouncers are solid blocks, with no exposed band.
    if ([_models nodeNamed:@"bumper-base"]) return;
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
        pivot.position = [self at:def.pivot height:def.layers & PBLayerDeck ? _table.deckHeight : 0.0f];
        pivot.eulerAngles = SCNVector3Make(0, def.restAngle, 0);
        [_root addChildNode:pivot];
        [_flipperNodes addObject:pivot];

        SCNNode *model = [_models nodeNamed:@"common-flipper"];
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
    // A fixed depth: as deep as the collider, however long the target is.
    model.scale = SCNVector3Make(width, 0.05f, 0.07f);
    model.position = [self at:(a + b) * 0.5f height:0.0f];
    model.eulerAngles = SCNVector3Make(0, atan2f(b.y - a.y, b.x - a.x), 0);
    [_root addChildNode:model];
    return model;
}

/// A round target. Its lens is its own, to light on its own.
- (SCNNode *)addStandupFrom:(simd_float2)a to:(simd_float2)b height:(float)height {
    SCNNode *model = [_models nodeNamed:@"spot-target"];
    if (!model) return nil;
    [model enumerateChildNodesUsingBlock:^(SCNNode *child, BOOL *stop) { child.geometry = [child.geometry copy]; }];
    SCNMaterial *lens = [_modelMaterials[@"target_lens"] copy];
    [self skinModel:model overrides:@{ @"target_lens": lens }];
    [_standupLenses addObject:lens];
    float scale = simd_distance(a, b) * 0.5f + 0.003f;
    model.scale = SCNVector3Make(scale, scale, scale);
    model.position = [self at:(a + b) * 0.5f height:height];
    [_root addChildNode:model];
    return model;
}

- (void)buildTargets {
    _standupLenses = [NSMutableArray array];
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
        SCNNode *round = [self addStandupFrom:def.a to:def.b height:def.layers & PBLayerDeck ? _table.deckHeight : 0.0f];
        [_standupNodes addObject:round ?: [self addTargetFrom:def.a to:def.b art:standup]];
    }

    _stopperNodes = [NSMutableArray array];
    for (PBSpotDef *post in _table.stoppers) {
        SCNNode *node = [self addModel:@"post" at:post.position height:-0.06f scale:post.radius];
        if (node) [_stopperNodes addObject:node];
    }

    // Kickback plungers are visible at the bottom of their lanes.
    for (PBSpotDef *kick in _table.kickbacks) {
        if ([self addModel:@"stud" at:kick.position - simd_make_float2(0.0f, 0.035f) height:0 scale:0.018f]) continue;
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
    const float axleHeight = 0.062f;
    SCNMaterial *gold = [self accentMetal];
    for (PBEdgeDef *def in _table.spinners) {
        float width = simd_distance(def.a, def.b);
        float heading = atan2f(def.b.y - def.a.y, def.b.x - def.a.x);
        // Two stout posts carrying a broad framed plate on a real axle, like a cabinet's spinner.
        const simd_float2 ends[] = { def.a, def.b };
        for (int i = 0; i < 2; i++) {
            SCNBox *post = [SCNBox boxWithWidth:0.016 height:axleHeight + 0.008f length:0.016 chamferRadius:0.002];
            SCNNode *postNode = [self addNodeWithGeometry:post material:gold];
            postNode.position = [self at:ends[i] height:(axleHeight + 0.008f) * 0.5f];
            postNode.eulerAngles = SCNVector3Make(0, heading, 0);
        }
        SCNNode *pivot = [SCNNode node];
        pivot.position = [self at:(def.a + def.b) * 0.5f height:axleHeight];
        pivot.eulerAngles = SCNVector3Make(0, heading, 0);
        [_root addChildNode:pivot];

        SCNCylinder *axle = [SCNCylinder cylinderWithRadius:0.0045f height:width];
        axle.firstMaterial = gold;
        SCNNode *axleNode = [SCNNode nodeWithGeometry:axle];
        axleNode.eulerAngles = SCNVector3Make(0, 0, (float)M_PI_2);
        [pivot addChildNode:axleNode];

        SCNNode *plateNode = [SCNNode node];
        SCNBox *frame = [SCNBox boxWithWidth:width - 0.018f height:0.006 length:0.092 chamferRadius:0.002];
        frame.firstMaterial = gold;
        [plateNode addChildNode:[SCNNode nodeWithGeometry:frame]];
        SCNPlane *face = [SCNPlane planeWithWidth:width - 0.03f height:0.08];
        face.firstMaterial = plate;
        face.firstMaterial.doubleSided = YES;
        SCNNode *faceNode = [SCNNode nodeWithGeometry:face];
        faceNode.eulerAngles = SCNVector3Make(-(float)M_PI_2, 0, 0);
        faceNode.position = SCNVector3Make(0, 0.0034f, 0);
        [plateNode addChildNode:faceNode];
        [pivot addChildNode:plateNode];
        [_spinnerPlates addObject:plateNode];
    }

    // A thick bar: anything slimmer across the table breaks up into stray bright pixels.
    SCNMaterial *wireMetal = [self accentMetal];
    _gatePlates = [NSMutableArray array];
    for (PBEdgeDef *def in _table.gates) {
        float width = simd_distance(def.a, def.b);
        SCNNode *pivot = [SCNNode node];
        pivot.position = [self at:(def.a + def.b) * 0.5f height:0.05f];
        pivot.eulerAngles = SCNVector3Make(0, atan2f(def.b.y - def.a.y, def.b.x - def.a.x), 0);
        [_root addChildNode:pivot];
        SCNCapsule *wire = [SCNCapsule capsuleWithCapRadius:0.0075f height:width];
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

        NSString *asset = ramp.model ?: [NSString stringWithFormat:@"%@-%@", _table.identifier, ramp.identifier];
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
        // Lay the sprite flat, then turn it about the table's up axis, like its socket.
        if (def.isArrow) node.simdOrientation = simd_mul(simd_quaternion(def.angle, simd_make_float3(0, 1, 0)), simd_quaternion(-(float)M_PI_2, simd_make_float3(1, 0, 0)));
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
        SCNMaterial *dome = [self pbrWithDiffuse:[self color:color * 0.35f] metalness:0.0 roughness:0.12];
        dome.emission.contents = [self color:color];
        dome.emission.intensity = 0.056;
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

// Every fourth equidistant arrow shares a material. Four texture switches advance the whole chase.
// Each bright state is directly cropped from the authored atlas, never recoloured or synthesized.
- (void)updateRampChase {
    if (!_rampChaseMaterials.count) return;
    NSInteger phase = (NSInteger)floor((_clock + 1e-6) / .18) % 4;
    if (phase != _rampChasePhase) {
        for (NSInteger group = 0; group < 4; group++) {
            SCNMaterial *deck = _rampChaseMaterials[(NSUInteger)group];
            id art = _rampChaseStates[group == phase ? group + 1 : 0];
            deck.diffuse.contents = deck.emission.contents = art;
            deck.emission.intensity = group == phase ? 1.15 : .24;
        }
        _rampChasePhase = phase;
    }
    _guideGlowMaterial.diffuse.intensity = 1.0 + .35 * (0.5 + .5 * sin(_clock * 5));
}

#pragma mark - Per-frame

- (void)syncWithGame:(PBGame *)game elapsed:(double)elapsed {
    _clock += elapsed;
    [self updateRampChase];
    PBPhysicsWorld *world = game.world;
    float dt = (float)elapsed;

    const PBBall *balls = world.balls;
    for (NSInteger i = 0; i < world.ballCapacity && i < (NSInteger)_ballNodes.count; i++) {
        SCNNode *node = _ballNodes[(NSUInteger)i];
        BOOL live = balls[i].state != PBBallInactive && balls[i].state != PBBallInTransit;
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
        _bumperLights[i].intensity = 6.0f + flash * 150.0f;
        PBBumperView *bumper = _bumpers[i];
        BOOL illuminated = flash > kPBStarFlashEnd;
        // Starts from the idle glow as the flash ends, so the swap back doesn't pop.
        bumper.lit.emission.intensity = bumper.bulb ? kPBStarIdleGlow + (flash - kPBStarFlashEnd) * 2.5f : bumper.lit.emission.intensity;
        bumper.bulb.diffuse.intensity = kPBBulbGlow + flash * 2.5f;
        if (illuminated != bumper.illuminated) {
            // Use the two authored atlas states directly; never recolour the cap artwork.
            for (SCNGeometry *geometry in bumper.paintedGeometry) geometry.firstMaterial = illuminated ? bumper.lit : bumper.idle;
            bumper.illuminated = illuminated;
        }
        // Contracts as it fires: drawn in and pressed down, for the moment it is lit.
        float rest = bumper.capScale;
        bumper.cap.scale = SCNVector3Make(rest * (1.0f - 0.14f * flash), rest * (1.0f - 0.3f * flash), rest * (1.0f - 0.14f * flash));
        bumper.cap.position = [self at:_table.bumpers[i].position height:-0.002f * flash];
    }

    for (NSUInteger i = 0; i < _table.slingshots.count; i++) {
        float t = [world slingFlash:(NSInteger)i];
        float kick = expf(-t * 18.0f);
        if (i < _slingBands.count) _slingBands[i].scale = SCNVector3Make(1.0f, 1.0f + kick * 0.6f, 1.0f);
        _slingLights[i].intensity = kick * 70.0f;
        if (i < _slingLenses.count) _slingLenses[i].emission.intensity = 0.15 + expf(-t * 6.0f) * 1.8;
    }
    for (NSUInteger i = 0; i < _stopperNodes.count; i++) {
        // Rises through the board, and sinks back out of sight.
        float target = [world isStopperUp:(NSInteger)i] ? 0.0f : -0.06f;
        SCNVector3 at = _stopperNodes[i].position;
        at.y += (target - at.y) * MIN(1.0f, 12.0f * dt);
        _stopperNodes[i].position = at;
        _stopperNodes[i].hidden = at.y < -0.055f;
    }
    for (NSUInteger i = 0; i < _standupLenses.count; i++) {
        // Quick on, slower off, then a low glow while it stays made.
        float hit = expf(-[world standupFlash:(NSInteger)i] * 5.0f);
        float level = MAX(hit, [game.rules isMemberLit:_table.standups[i].identifier] ? 0.3f : 0.0f);
        _standupLenses[i].diffuse.intensity = 0.16 + level * 0.84;
        _standupLenses[i].emission.intensity = level * 1.5;
    }

    float pull = world.plungerPull;
    SCNVector3 rodPosition = _plungerRod.position;
    rodPosition.z = [self at:simd_make_float2(0, _plungerRodBase - pull * _table.plunger.travel) height:0].z;
    _plungerRod.position = rodPosition;

    [self updateLampsWithGame:game dt:dt];
    [self updateFlashersWithDt:dt];
    [self updateGlowWithWorld:world];
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
        flasher.dome.emission.intensity = 0.056 + level * 2.2;
        BOOL visible = level > 0.01f;
        flasher.glow.hidden = !visible;
        if (visible) flasher.glow.opacity = level;
    }
}

/// Gathers every glowing part this frame and hands the brightest to the shader.
- (void)updateGlowWithWorld:(PBPhysicsWorld *)world {
    typedef struct { simd_float4 position, color; float strength; } PBGlow;
    NSInteger capacity = (NSInteger)(_lamps.count + _bumpers.count + _table.slingshots.count + _flashers.count + _table.ramps.count * 2);
    PBGlow *glows = calloc((size_t)MAX(capacity, 1), sizeof(PBGlow));
    __block NSInteger count = 0;
    void (^add)(simd_float2, float, float, simd_float3, float) = ^(simd_float2 at, float height, float range, simd_float3 color, float strength) {
        if (strength < 0.02f || count >= capacity) return;
        SCNVector3 p = [self at:at height:height];
        glows[count++] = (PBGlow){ simd_make_float4(p.x, p.y, p.z, range), simd_make_float4(color * strength, 1), strength };
    };
    NSArray<PBLampDef *> *lamps = _table.lamps;
    for (NSUInteger i = 0; i < _lamps.count; i++) {
        add(lamps[i].position, 0.025f, MAX(0.17f, lamps[i].size * 6.0f), [_skin lampColor:lamps[i].color], _lamps[i].intensity * 1.5f);
    }
    for (NSUInteger i = 0; i < _bumpers.count; i++) {
        float flash = expf(-[world bumperFlash:(NSInteger)i] * 9.0f);
        PBSpotDef *bumper = _table.bumpers[i];
        add(bumper.position, bumper.radius * 1.9f, 0.36f, [_skin lampColor:@"bumper"], 0.85f + flash * 3.2f);
    }
    for (NSUInteger i = 0; i < _table.slingshots.count; i++) {
        float kick = expf(-[world slingFlash:(NSInteger)i] * 6.0f);
        PBEdgeDef *sling = _table.slingshots[i];
        add((sling.a + sling.b) * 0.5f, 0.03f, 0.26f, _skin.slingLensColor, 0.3f + kick * 2.6f);
    }
    for (NSUInteger i = 0; i < _table.standups.count; i++) {
        float hit = expf(-[world standupFlash:(NSInteger)i] * 5.0f);
        PBEdgeDef *standup = _table.standups[i];
        if (hit > 0.05f) add((standup.a + standup.b) * 0.5f, 0.05f, 0.2f, _skin.slingLensColor, hit * 1.6f);
    }
    // The lit arrows inlaid in each ramp's floor, near both of its ends.
    for (PBRampDef *ramp in _table.ramps) {
        for (int end = 0; end < 2; end++) {
            NSInteger step = (NSInteger)(ramp.pointCount * 0.075f);
            simd_float3 p = [ramp pointAtIndex:end ? ramp.pointCount - 1 - step : step];
            add(p.xy, p.z + 0.02f, 0.13f, _skin.slingLensColor, 0.7f);
        }
    }
    for (NSUInteger i = 0; i < _flashers.count; i++) {
        PBSpotDef *def = _table.flashers[i];
        float level = _flashers[i].level;
        add(def.position, 0.09f, 0.6f, [_skin lampColor:def.color ?: @"white"], level * level * 3.5f);
    }
    qsort_b(glows, (size_t)count, sizeof(PBGlow), ^int(const void *a, const void *b) {
        float left = ((const PBGlow *)a)->strength, right = ((const PBGlow *)b)->strength;
        return left < right ? 1 : left > right ? -1 : 0;
    });
    PBGlowBlock block = {0};
    for (NSInteger i = 0; i < MIN(count, (NSInteger)kPBGlowSources); i++) {
        block.position[i] = glows[i].position;
        block.color[i] = glows[i].color;
    }
    free(glows);
    if (_glowBlock.length == sizeof(block) && memcmp(_glowBlock.bytes, &block, sizeof(block)) == 0) return;
    _glowBlock = [NSData dataWithBytes:&block length:sizeof(block)];
    for (SCNMaterial *material in _glowMaterials) [material setValue:_glowBlock forKey:@"pbGlow"];
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

#pragma mark - Effects

- (SCNVector3)worldPointAt:(simd_float2)position height:(float)height {
    return [self at:position height:height];
}

- (simd_float3)impactColorForEvent:(PBEventKind)kind {
    switch (kind) {
        case PBEventBumper: return [_skin lampColor:@"bumper"];
        case PBEventSling: return _skin.slingLensColor;
        case PBEventStandup: return _skin.slingLensColor;
        case PBEventDropTarget: return [_skin lampColor:@"amber"];
        default: return _skin.accentColor;
    }
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
