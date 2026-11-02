//
//  PBTableDefinition.m
//

#import "PBTableDefinition.h"

static inline float PBRadians(float degrees) { return degrees * (float)M_PI / 180.0f; }

static simd_float2 PBVec2(id value) {
    NSArray *array = value;
    return simd_make_float2([array[0] floatValue], [array[1] floatValue]);
}

@implementation PBPointList {
    NSMutableData *_storage;
}
- (instancetype)initWithCount:(NSInteger)count {
    if ((self = [super init])) {
        _count = count;
        _storage = [NSMutableData dataWithLength:(NSUInteger)count * sizeof(simd_float2)];
    }
    return self;
}
- (const simd_float2 *)points { return _storage.bytes; }
- (simd_float2 *)mutablePoints { return _storage.mutableBytes; }
@end

@implementation PBElementDef @end
@implementation PBWallDef @end
@implementation PBSpotDef @end
@implementation PBEdgeDef @end
@implementation PBFlipperDef @end
@implementation PBLampDef @end
@implementation PBPlasticDef @end
@implementation PBDecorDef @end
@implementation PBPlungerDef @end
@implementation PBRuleGroupDef @end

@implementation PBRampDef
- (NSInteger)pointCount { return (NSInteger)(self.pointData.length / sizeof(simd_float3)); }
- (simd_float3)pointAtIndex:(NSInteger)index { return ((const simd_float3 *)self.pointData.bytes)[index]; }
@end

@implementation PBRulesDef
- (NSInteger)scoreFor:(NSString *)key { return self.scores[key].integerValue; }
@end

#pragma mark - Parsing

/// Expands a JSON path, where each entry is [x, y] or {"arc": [cx, cy, r, startDeg, endDeg, segments]}.
static PBPointList *PBParsePath(NSArray *entries) {
    NSMutableData *points = [NSMutableData data];
    for (id entry in entries) {
        if ([entry isKindOfClass:[NSDictionary class]]) {
            NSArray *arc = entry[@"arc"];
            simd_float2 center = simd_make_float2([arc[0] floatValue], [arc[1] floatValue]);
            float radius = [arc[2] floatValue];
            float start = PBRadians([arc[3] floatValue]);
            float end = PBRadians([arc[4] floatValue]);
            NSInteger segments = [arc[5] integerValue];
            for (NSInteger i = 0; i <= segments; i++) {
                float angle = start + (end - start) * (float)i / (float)segments;
                simd_float2 point = center + radius * simd_make_float2(cosf(angle), sinf(angle));
                [points appendBytes:&point length:sizeof(point)];
            }
        } else {
            simd_float2 point = PBVec2(entry);
            [points appendBytes:&point length:sizeof(point)];
        }
    }
    NSInteger count = (NSInteger)(points.length / sizeof(simd_float2));
    PBPointList *list = [[PBPointList alloc] initWithCount:count];
    memcpy(list.mutablePoints, points.bytes, points.length);
    return list;
}

static PBLayerMask PBParseLayers(NSArray<NSString *> *names) {
    if (names.count == 0) return PBLayerPlayfield;
    PBLayerMask mask = 0;
    for (NSString *name in names) {
        if ([name isEqualToString:@"playfield"]) mask |= PBLayerPlayfield;
        if ([name isEqualToString:@"ramp"]) mask |= PBLayerRamp;
        if ([name isEqualToString:@"captive"]) mask |= PBLayerCaptive;
    }
    return mask;
}

static PBWallStyle PBParseWallStyle(NSString *name) {
    if ([name isEqualToString:@"wall"]) return PBWallStyleWall;
    if ([name isEqualToString:@"rail"]) return PBWallStyleRail;
    if ([name isEqualToString:@"rubber"]) return PBWallStyleRubber;
    if ([name isEqualToString:@"plastic"]) return PBWallStylePlastic;
    return PBWallStyleNone;
}

static PBSpotDef *PBParseSpot(NSDictionary *json) {
    PBSpotDef *spot = [PBSpotDef new];
    spot.identifier = json[@"id"];
    spot.position = simd_make_float2([json[@"x"] floatValue], [json[@"y"] floatValue]);
    spot.radius = [json[@"r"] floatValue];
    spot.hasPlate = json[@"plate"] ? [json[@"plate"] boolValue] : YES;
    spot.speed = [(json[@"speed"] ?: json[@"ejectSpeed"] ?: json[@"flingSpeed"]) floatValue];
    spot.captureSpeed = [json[@"captureSpeed"] floatValue];
    spot.holdSeconds = [json[@"holdSeconds"] floatValue];
    spot.color = json[@"color"];
    spot.model = json[@"model"];
    if (json[@"ejectDirection"]) spot.direction = simd_normalize(PBVec2(json[@"ejectDirection"]));
    return spot;
}

static PBEdgeDef *PBParseEdge(NSDictionary *json) {
    PBEdgeDef *edge = [PBEdgeDef new];
    edge.identifier = json[@"id"];
    edge.a = PBVec2(json[@"a"]);
    edge.b = PBVec2(json[@"b"]);
    if (json[@"passDirection"]) edge.passDirection = PBVec2(json[@"passDirection"]);
    edge.vari = [json[@"vari"] boolValue];
    return edge;
}

static const NSInteger kRampSubdivisions = 6;

/// Catmull-Rom through the authored points. Physics and meshes share the same curve,
/// and kinks would otherwise bleed the ball's speed at every joint.
static NSData *PBSmoothRampPath(NSArray<NSArray *> *authored) {
    NSInteger count = (NSInteger)authored.count;
    simd_float3 (^at)(NSInteger) = ^simd_float3(NSInteger index) {
        NSArray *p = authored[(NSUInteger)MAX(0, MIN(index, count - 1))];
        return simd_make_float3([p[0] floatValue], [p[1] floatValue], [p[2] floatValue]);
    };
    NSMutableData *data = [NSMutableData data];
    for (NSInteger i = 0; i + 1 < count; i++) {
        simd_float3 p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
        for (NSInteger step = 0; step < kRampSubdivisions; step++) {
            float t = (float)step / (float)kRampSubdivisions;
            simd_float3 point = 0.5f * ((2.0f * p1) + (p2 - p0) * t + (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * t * t
                                        + (3.0f * p1 - p0 - 3.0f * p2 + p3) * t * t * t);
            [data appendBytes:&point length:sizeof(point)];
        }
    }
    simd_float3 last = at(count - 1);
    [data appendBytes:&last length:sizeof(last)];
    return data;
}

static NSArray *PBMap(NSArray *input, id (^transform)(id)) {
    NSMutableArray *output = [NSMutableArray arrayWithCapacity:input.count];
    for (id item in input) [output addObject:transform(item)];
    return output;
}

@implementation PBTableDefinition

- (nullable instancetype)initWithJSONData:(NSData *)data error:(NSError **)error {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    if ((self = [super init])) {
        _identifier = json[@"id"];
        _name = json[@"name"];
        _defaultSkin = json[@"defaultSkin"];
        _size = PBVec2(json[@"size"]);

        NSDictionary *physics = json[@"physics"];
        _gravity = [physics[@"gravity"] floatValue];
        _rampGravity = [physics[@"rampGravity"] floatValue];
        _ballRadius = [physics[@"ballRadius"] floatValue];
        _drainY = [physics[@"drainY"] floatValue];
        _plungerSpeed = [physics[@"plungerSpeed"] floatValue];

        NSDictionary *apron = json[@"apron"];
        _apronY = [apron[@"y"] floatValue];

        NSDictionary *plunger = json[@"plunger"];
        _plunger = [PBPlungerDef new];
        _plunger.position = simd_make_float2([plunger[@"x"] floatValue], [plunger[@"y"] floatValue]);
        _plunger.width = [plunger[@"width"] floatValue];
        _plunger.travel = [plunger[@"travel"] floatValue];

        _walls = PBMap(json[@"walls"], ^id(NSDictionary *item) {
            PBWallDef *wall = [PBWallDef new];
            wall.identifier = item[@"id"];
            wall.style = PBParseWallStyle(item[@"style"]);
            wall.height = [item[@"height"] floatValue];
            wall.radius = [item[@"radius"] floatValue];
            wall.closed = [item[@"closed"] boolValue];
            wall.layers = PBParseLayers(item[@"layers"]);
            wall.points = PBParsePath(item[@"points"]);
            return wall;
        });
        id (^spots)(id) = ^id(NSDictionary *item) { return PBParseSpot(item); };
        id (^edges)(id) = ^id(NSDictionary *item) { return PBParseEdge(item); };
        _posts = PBMap(json[@"posts"], spots);
        _bumpers = PBMap(json[@"bumpers"], spots);
        _rollovers = PBMap(json[@"rollovers"], spots);
        _saucers = PBMap(json[@"saucers"], spots);
        _kickbacks = PBMap(json[@"kickbacks"], spots);
        _stoppers = PBMap(json[@"stoppers"], spots);
        _magnets = PBMap(json[@"magnets"], spots);
        _captiveBalls = PBMap(json[@"captiveBalls"], spots);
        _flashers = PBMap(json[@"flashers"], spots);
        _slingshots = PBMap(json[@"slingshots"], edges);
        _dropTargets = PBMap(json[@"dropTargets"], edges);
        _standups = PBMap(json[@"standups"], edges);
        _spinners = PBMap(json[@"spinners"], edges);
        _gates = PBMap(json[@"gates"], edges);

        _flippers = PBMap(json[@"flippers"], ^id(NSDictionary *item) {
            PBFlipperDef *flipper = [PBFlipperDef new];
            flipper.identifier = item[@"id"];
            flipper.isLeft = [item[@"side"] isEqualToString:@"left"];
            flipper.pivot = PBVec2(item[@"pivot"]);
            flipper.length = [item[@"length"] floatValue];
            flipper.baseRadius = [item[@"baseRadius"] floatValue];
            flipper.tipRadius = [item[@"tipRadius"] floatValue];
            flipper.restAngle = PBRadians([item[@"restAngle"] floatValue]);
            flipper.activeAngle = PBRadians([item[@"activeAngle"] floatValue]);
            return flipper;
        });
        _ramps = PBMap(json[@"ramps"], ^id(NSDictionary *item) {
            PBRampDef *ramp = [PBRampDef new];
            ramp.identifier = item[@"id"];
            ramp.model = item[@"model"];
            ramp.width = [item[@"width"] floatValue];
            NSDictionary *authoring = item[@"authoring"];
            ramp.wallHeight = [authoring[@"wall_height"] ?: @0.055f floatValue];
            ramp.railWidth = [authoring[@"rail_width"] ?: @0.008f floatValue];
            float flare = [authoring[@"flare"] ?: @1.18f floatValue];
            ramp.entranceFlare = [authoring[@"entrance"] isEqualToString:@"FLARED"] ? flare : 1;
            ramp.exitFlare = [authoring[@"exit"] isEqualToString:@"FLARED"] ? flare : 1;
            ramp.transitionLength = [authoring[@"end_length"] ?: @0.055f floatValue];
            ramp.supportColumns = authoring[@"columns"] ?: @[];
            ramp.supportRadius = [authoring[@"support_radius"] ?: @0.004f floatValue];
            ramp.supportBase = [authoring[@"base_height"] floatValue];
            ramp.mouthA = PBVec2(item[@"mouth"][0]);
            ramp.mouthB = PBVec2(item[@"mouth"][1]);
            ramp.plasticUntil = [item[@"plasticUntil"] integerValue];
            if ([authoring[@"path_sampled"] boolValue]) {
                NSMutableData *path = [NSMutableData data];
                for (NSArray *p in item[@"points"]) {
                    simd_float3 v = simd_make_float3([p[0] floatValue], [p[1] floatValue], [p[2] floatValue]);
                    [path appendBytes:&v length:sizeof(v)];
                }
                ramp.pointData = path;
            } else {
                ramp.pointData = PBSmoothRampPath(item[@"points"]);
                ramp.plasticUntil *= kRampSubdivisions;
            }
            return ramp;
        });
        _lamps = PBMap(json[@"lamps"], ^id(NSDictionary *item) {
            PBLampDef *lamp = [PBLampDef new];
            lamp.identifier = item[@"id"];
            lamp.position = simd_make_float2([item[@"x"] floatValue], [item[@"y"] floatValue]);
            lamp.size = [item[@"size"] floatValue];
            lamp.color = item[@"color"];
            lamp.icon = [item[@"icon"] integerValue];
            lamp.bind = item[@"bind"];
            lamp.isArrow = [item[@"shape"] isEqualToString:@"arrow"];
            lamp.angle = PBRadians([item[@"angle"] floatValue]);
            return lamp;
        });
        _plastics = PBMap(json[@"plastics"], ^id(NSDictionary *item) {
            PBPlasticDef *plastic = [PBPlasticDef new];
            plastic.identifier = item[@"id"];
            plastic.height = [item[@"height"] floatValue];
            plastic.points = PBParsePath(item[@"points"]);
            return plastic;
        });
        _decor = PBMap(json[@"decor"] ?: @[], ^id(NSDictionary *item) {
            PBDecorDef *decor = [PBDecorDef new];
            decor.identifier = item[@"id"];
            decor.model = item[@"model"];
            decor.position = simd_make_float2([item[@"x"] floatValue], [item[@"y"] floatValue]);
            decor.size = [item[@"size"] floatValue];
            decor.angle = PBRadians([item[@"angle"] floatValue]);
            decor.base = [item[@"base"] floatValue];
            decor.height = [item[@"height"] floatValue];
            float aspect = item[@"aspect"] ? [item[@"aspect"] floatValue] : 1.0f;  // Half width over half length.
            decor.radius = decor.size * aspect;
            decor.extent = decor.size * (1.0f - aspect);
            return decor;
        });

        NSDictionary *rules = json[@"rules"];
        _rules = [PBRulesDef new];
        _rules.balls = [rules[@"balls"] integerValue];
        _rules.ballSaveSeconds = [rules[@"ballSaveSeconds"] doubleValue];
        _rules.locksForMultiball = [rules[@"locksForMultiball"] integerValue];
        _rules.multiballBalls = [rules[@"multiballBalls"] integerValue];
        _rules.skillShotSeconds = [rules[@"skillShotSeconds"] doubleValue];
        _rules.tiltWarnings = [rules[@"tiltWarnings"] integerValue];
        _rules.rampsForExtraBall = [rules[@"rampsForExtraBall"] integerValue];
        _rules.scores = rules[@"scores"];
        _rules.skillShotTarget = rules[@"skillShotTarget"] ?: @"";
        _rules.wizard = [rules[@"wizard"] boolValue];
        _rules.groups = PBMap(rules[@"groups"], ^id(NSDictionary *item) {
            PBRuleGroupDef *group = [PBRuleGroupDef new];
            group.identifier = item[@"id"];
            group.members = item[@"members"];
            group.lamps = item[@"lamps"];
            group.rotateWithFlippers = [item[@"rotateWithFlippers"] boolValue];
            group.completeScore = [item[@"completeScore"] integerValue];
            group.actions = item[@"actions"];
            group.message = item[@"message"] ?: @"";
            return group;
        });
    }
    return self;
}

+ (nullable instancetype)tableNamed:(NSString *)identifier bundle:(NSBundle *)bundle error:(NSError **)error {
    NSURL *url = [bundle URLForResource:identifier withExtension:@"json" subdirectory:@"GameData/Tables"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url options:0 error:error] : nil;
    return data ? [[self alloc] initWithJSONData:data error:error] : nil;
}

+ (NSArray<NSString *> *)availableTablesInBundle:(NSBundle *)bundle {
    NSArray<NSURL *> *urls = [bundle URLsForResourcesWithExtension:@"json" subdirectory:@"GameData/Tables"];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *url in urls) [names addObject:url.URLByDeletingPathExtension.lastPathComponent];
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

@end
