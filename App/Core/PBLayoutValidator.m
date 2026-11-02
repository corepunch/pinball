//
//  PBLayoutValidator.m
//

#import "PBLayoutValidator.h"

const float PBTableCameraFOV = 70.0f;
const float PBTableCameraBand = 0.35f;
const float PBTablePhoneAspect = 2.17f;

float PBTableVisibleHeight(simd_float2 size, simd_float2 padding) {
    return MAX(size.y + padding.y + PBTableCameraBand, (size.x + 2.0f * padding.x) * PBTablePhoneAspect);
}

simd_float2 PBTableProject(simd_float2 size, simd_float2 padding, simd_float2 p, float height) {
    float visible = PBTableVisibleHeight(size, padding);
    float distance = visible / (2.0f * tanf(PBTableCameraFOV * 0.5f * (float)M_PI / 180.0f));
    simd_float2 centre = simd_make_float2(size.x * 0.5f, visible * 0.5f - padding.y);
    return centre + (p - centre) * (distance / MAX(distance - height, 0.01f));
}
const float PBBumperFootprintScale = 1.08f;
const float PBLampFootprintScale = 1.12f;
const float PBPostFootprintScale = 1.05f;

// Footprints are a little larger than colliders, so a passable gap can measure under a ball's width.
static const float kPassableFraction = 0.82f;
// A flipper seats against the end of its guide rail, and the tilt can lift it this far over.
static const float kFlipperSeat = 0.0035f;

typedef struct { simd_float2 a, b; float radius; BOOL onFloor; } PBCapsule;

typedef NS_ENUM(NSInteger, PBPartRole) {
    PBPartStructure,  // Walls, posts, slings, targets, gates: may be built onto each other.
    PBPartBumper,
    PBPartFlipper,
    PBPartInsert,     // Lamps, saucers, rollovers: art and hardware set into the playfield.
    PBPartPlate,      // A playfield plate that inserts may sit on, like the magnet.
    PBPartPlastic,    // Raised on posts above walls, so it may cover structure only.
    PBPartRamp,
    PBPartDecor,
};

@interface PBLayoutIssue ()
@property (nonatomic) PBLayoutIssueKind kind;
@property (nonatomic, copy) NSString *first;
@property (nonatomic, copy, nullable) NSString *second;
@property (nonatomic) float amount;
@property (nonatomic) simd_float2 location;
@end
@implementation PBLayoutIssue
- (NSString *)description {
    static NSString *const names[] = { @"overlaps", @"leaves a narrow gap to", @"is out of bounds" };
    return [NSString stringWithFormat:@"%@ %@ %@ by %.3f near (%.3f, %.3f)", self.first, names[self.kind],
            self.second ?: @"", self.amount, self.location.x, self.location.y];
}
@end

@interface PBPart : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic) PBPartRole role;
@property (nonatomic) NSMutableData *capsules;
@property (nonatomic, nullable) NSData *outline;  // Filled polygon, packed simd_float2.
@property (nonatomic) BOOL solid;                 // Stops a ball on the playfield layer.
@property (nonatomic) BOOL rampMounted;           // Part of a ramp's entrance.
@property (nonatomic) BOOL mayRunUnderApron;
@property (nonatomic) BOOL unseen;
@property (nonatomic) NSInteger group;
@end
@implementation PBPart
- (NSInteger)count { return (NSInteger)(self.capsules.length / sizeof(PBCapsule)); }
- (const PBCapsule *)items { return self.capsules.bytes; }
@end

static simd_float2 PBClosest(simd_float2 p, simd_float2 a, simd_float2 b) {
    simd_float2 ab = b - a;
    float lengthSquared = simd_length_squared(ab);
    if (lengthSquared < 1e-10f) return a;
    return a + ab * simd_clamp(simd_dot(p - a, ab) / lengthSquared, 0.0f, 1.0f);
}

static BOOL PBSegmentsIntersect(simd_float2 a, simd_float2 b, simd_float2 c, simd_float2 d, simd_float2 *where) {
    simd_float2 r = b - a, s = d - c;
    float denominator = r.x * s.y - r.y * s.x;
    if (fabsf(denominator) < 1e-9f) return NO;
    float t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator;
    float u = ((c.x - a.x) * r.y - (c.y - a.y) * r.x) / denominator;
    if (t < 0 || t > 1 || u < 0 || u > 1) return NO;
    if (where) *where = a + r * t;
    return YES;
}

/// Closest approach between the centrelines of two capsules.
static float PBCenterlineDistance(PBCapsule x, PBCapsule y, simd_float2 *where) {
    simd_float2 crossing;
    if (PBSegmentsIntersect(x.a, x.b, y.a, y.b, &crossing)) { *where = crossing; return 0; }
    float best = FLT_MAX;
    simd_float2 candidates[4][2] = {
        { x.a, PBClosest(x.a, y.a, y.b) }, { x.b, PBClosest(x.b, y.a, y.b) },
        { y.a, PBClosest(y.a, x.a, x.b) }, { y.b, PBClosest(y.b, x.a, x.b) },
    };
    for (int i = 0; i < 4; i++) {
        float distance = simd_distance(candidates[i][0], candidates[i][1]);
        if (distance < best) { best = distance; *where = (candidates[i][0] + candidates[i][1]) * 0.5f; }
    }
    return best;
}

static BOOL PBPointInOutline(simd_float2 p, NSData *outline) {
    const simd_float2 *v = outline.bytes;
    NSInteger n = (NSInteger)(outline.length / sizeof(simd_float2));
    BOOL inside = NO;
    for (NSInteger i = 0, j = n - 1; i < n; j = i++) {
        if ((v[i].y > p.y) != (v[j].y > p.y) && p.x < (v[j].x - v[i].x) * (p.y - v[i].y) / (v[j].y - v[i].y) + v[i].x) inside = !inside;
    }
    return inside;
}

/// One capsule built onto another: the end of one sits on the other's centreline.
static BOOL PBCapsulesAttach(PBCapsule x, PBCapsule y) {
    float reach = x.radius + y.radius + 0.003f;
    return simd_distance(x.a, PBClosest(x.a, y.a, y.b)) <= reach
        || simd_distance(x.b, PBClosest(x.b, y.a, y.b)) <= reach
        || simd_distance(y.a, PBClosest(y.a, x.a, x.b)) <= reach
        || simd_distance(y.b, PBClosest(y.b, x.a, x.b)) <= reach;
}

@implementation PBLayoutValidator {
    PBTableDefinition *_table;
    NSMutableArray<PBPart *> *_parts;
}

+ (NSArray<PBLayoutIssue *> *)issuesForTable:(PBTableDefinition *)table {
    PBLayoutValidator *validator = [self new];
    validator->_table = table;
    validator->_parts = [NSMutableArray array];
    [validator collectParts];
    [validator groupAttachedStructure];
    NSMutableArray *issues = [NSMutableArray array];
    [validator checkBounds:issues];
    [validator checkPairs:issues];
    return issues;
}

#pragma mark - Footprints

/// Where a point at this height lands on the playfield, as the phone sees it.
- (simd_float2)project:(simd_float2)p height:(float)height {
    return PBTableProject(_table.size, _table.padding, p, height);
}

- (PBPart *)addPart:(NSString *)identifier role:(PBPartRole)role {
    PBPart *part = [PBPart new];
    part.identifier = identifier;
    part.role = role;
    part.capsules = [NSMutableData data];
    [_parts addObject:part];
    return part;
}

- (void)addCapsuleTo:(PBPart *)part from:(simd_float2)a to:(simd_float2)b radius:(float)radius height:(float)height {
    PBCapsule capsule = { [self project:a height:height], [self project:b height:height], radius, height <= 0 };
    [part.capsules appendBytes:&capsule length:sizeof(capsule)];
}

/// An upright part shows both its foot and its top, which parallax shifts apart.
- (void)addUprightTo:(PBPart *)part from:(simd_float2)a to:(simd_float2)b radius:(float)radius height:(float)height {
    [self addCapsuleTo:part from:a to:b radius:radius height:0];
    if (height > 0) [self addCapsuleTo:part from:a to:b radius:radius height:height];
}

- (void)collectParts {
    PBTableDefinition *t = _table;

    for (PBWallDef *wall in t.walls) {
        if (wall.layers & PBLayerDeck) continue;  // On the second level, above everything here.
        PBPart *part = [self addPart:wall.identifier role:PBPartStructure];
        // Collides but is never seen: parts can be built onto it, and nothing can overlap it.
        part.unseen = wall.style == PBWallStyleNone;
        part.solid = (wall.layers & PBLayerPlayfield) != 0;
        part.rampMounted = (wall.layers & PBLayerRamp) != 0 || wall.isDeck;  // A ramp climbs over the deck's edge.
        part.mayRunUnderApron = YES;
        const simd_float2 *p = wall.points.points;
        NSInteger n = wall.points.count, segments = wall.closed ? n : n - 1;
        // Drawn as a thin line inside the collider, which is what must stay clear.
        float drawn = wall.radius;
        for (NSInteger i = 0; i < segments; i++) {
            [self addUprightTo:part from:p[i] to:p[(i + 1) % n] radius:drawn height:wall.height];
        }
        if (wall.closed && wall.style == PBWallStylePlastic) {
            part.outline = [NSData dataWithBytes:p length:(NSUInteger)n * sizeof(simd_float2)];
        }
    }
    for (PBSpotDef *post in t.posts) {
        PBPart *part = [self addPart:post.identifier role:PBPartStructure];
        part.solid = YES;
        [self addUprightTo:part from:post.position to:post.position radius:post.radius * PBPostFootprintScale height:0.06f];
    }
    for (PBSpotDef *bumper in t.bumpers) {
        PBPart *part = [self addPart:bumper.identifier role:PBPartBumper];
        part.solid = YES;
        [self addUprightTo:part from:bumper.position to:bumper.position radius:bumper.radius * PBBumperFootprintScale height:bumper.radius * 1.42f];
    }
    for (PBEdgeDef *sling in t.slingshots) {
        PBPart *part = [self addPart:sling.identifier role:PBPartStructure];
        part.solid = YES;
        [self addUprightTo:part from:sling.a to:sling.b radius:0.008f height:0.04f];
    }
    for (PBFlipperDef *flipper in t.flippers) {
        if (flipper.layers & PBLayerDeck) continue;
        // The whole swept area stays clear, or the flipper would pass over its neighbours.
        PBPart *part = [self addPart:flipper.identifier role:PBPartFlipper];
        for (int i = 0; i <= 6; i++) {
            float angle = flipper.restAngle + (flipper.activeAngle - flipper.restAngle) * (float)i / 6.0f;
            simd_float2 tip = flipper.pivot + simd_make_float2(cosf(angle), sinf(angle)) * flipper.length;
            [self addUprightTo:part from:flipper.pivot to:tip radius:flipper.baseRadius height:0.038f];
        }
    }
    void (^edges)(NSArray<PBEdgeDef *> *, float, float, BOOL) = ^(NSArray<PBEdgeDef *> *list, float radius, float height, BOOL solid) {
        for (PBEdgeDef *edge in list) {
            if (edge.layers & PBLayerDeck) continue;
            PBPart *part = [self addPart:edge.identifier role:PBPartStructure];
            part.solid = solid;
            part.mayRunUnderApron = !solid;  // Gates and spinners span their lane, right up to the edge.
            [self addUprightTo:part from:edge.a to:edge.b radius:radius height:height];
        }
    };
    // Drop targets and gates move or let the ball through, so they make no gap of their own.
    edges(t.dropTargets, 0.008f, 0.05f, NO);
    edges(t.standups, 0.012f, 0.05f, YES);
    edges(t.spinners, 0.008f, 0.07f, NO);
    edges(t.gates, 0.004f, 0.05f, NO);

    for (PBLampDef *lamp in t.lamps) {
        PBPart *part = [self addPart:lamp.identifier role:PBPartInsert];
        [self addCapsuleTo:part from:lamp.position to:lamp.position radius:lamp.size * PBLampFootprintScale height:0];
    }
    for (PBSpotDef *saucer in t.saucers) {
        if (saucer.layers & PBLayerDeck) continue;
        PBPart *part = [self addPart:saucer.identifier role:PBPartInsert];
        [self addCapsuleTo:part from:saucer.position to:saucer.position radius:saucer.radius * 1.15f + 0.003f height:0];
    }
    for (PBSpotDef *rollover in t.rollovers) {
        PBPart *part = [self addPart:rollover.identifier role:PBPartInsert];
        simd_float2 reach = simd_make_float2(0, rollover.radius * 0.7f);
        [self addCapsuleTo:part from:rollover.position - reach to:rollover.position + reach radius:0.003f height:0];
    }
    for (PBSpotDef *magnet in t.magnets) {
        PBPart *part = [self addPart:magnet.identifier role:PBPartPlate];
        [self addCapsuleTo:part from:magnet.position to:magnet.position radius:0.054f height:0];
    }
    for (PBSpotDef *kick in t.kickbacks) {
        PBPart *part = [self addPart:kick.identifier role:PBPartInsert];
        simd_float2 head = kick.position - simd_make_float2(0.0f, 0.035f);
        [self addCapsuleTo:part from:head to:head radius:0.016f height:0.02f];
    }
    for (PBSpotDef *flasher in t.flashers) {
        PBPart *part = [self addPart:flasher.identifier role:PBPartDecor];
        [self addCapsuleTo:part from:flasher.position to:flasher.position radius:0.036f height:0.17f];
    }
    for (PBPlasticDef *plastic in t.plastics) {
        PBPart *part = [self addPart:plastic.identifier role:PBPartPlastic];
        const simd_float2 *p = plastic.points.points;
        NSInteger n = plastic.points.count;
        NSMutableData *outline = [NSMutableData dataWithLength:(NSUInteger)n * sizeof(simd_float2)];
        simd_float2 *projected = outline.mutableBytes;
        for (NSInteger i = 0; i < n; i++) {
            [self addCapsuleTo:part from:p[i] to:p[(i + 1) % n] radius:0.003f height:plastic.height];
            projected[i] = [self project:p[i] height:plastic.height];
        }
        part.outline = outline;
    }
    for (PBDecorDef *decor in t.decor) {
        PBPart *part = [self addPart:decor.identifier role:PBPartDecor];
        float cs = cosf(decor.angle), sn = sinf(decor.angle);
        simd_float2 reach = simd_make_float2(cs, sn) * decor.extent;
        // Decor lies flat on the plane it is mounted to, so its own base height applies.
        [self addCapsuleTo:part from:decor.position - reach to:decor.position + reach radius:decor.radius height:decor.base + decor.height];
    }
    for (PBRampDef *ramp in t.ramps) {
        PBPart *part = [self addPart:ramp.identifier role:PBPartRamp];
        float half = ramp.width * 0.5f + ramp.railWidth;
        // The ramp ends are cut square: leave the capsule's round caps out of its footprint.
        float length = 0;
        for (NSInteger i = 1; i < ramp.pointCount; i++) length += simd_distance([ramp pointAtIndex:i].xy, [ramp pointAtIndex:i - 1].xy);
        float along = 0;
        for (NSInteger i = 0; i + 1 < ramp.pointCount; i++) {
            simd_float3 a = [ramp pointAtIndex:i], b = [ramp pointAtIndex:i + 1];
            float step = simd_distance(a.xy, b.xy);
            float midpoint = along + step * 0.5f;
            along += step;
            if (midpoint < half * 0.75f || midpoint > length - half * 0.75f) continue;
            // The rims stand above the floor and are what the player sees.
            float entry = MAX(0, 1 - midpoint / MAX(ramp.transitionLength, .001f));
            float exit = MAX(0, 1 - (length - midpoint) / MAX(ramp.transitionLength, .001f));
            float width = half * (1 + (ramp.entranceFlare - 1) * entry * entry * (3 - 2 * entry)
                                   + (ramp.exitFlare - 1) * exit * exit * (3 - 2 * exit));
            PBCapsule capsule = { [self project:a.xy height:a.z + ramp.wallHeight], [self project:b.xy height:b.z + ramp.wallHeight], width, NO };
            [part.capsules appendBytes:&capsule length:sizeof(capsule)];
        }
    }
}

/// Parts built onto each other count as one structure when measuring the gaps between solids.
- (void)groupAttachedStructure {
    NSInteger n = (NSInteger)_parts.count;
    for (NSInteger i = 0; i < n; i++) _parts[(NSUInteger)i].group = i;
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSInteger i = 0; i < n; i++) {
            for (NSInteger j = i + 1; j < n; j++) {
                PBPart *x = _parts[(NSUInteger)i], *y = _parts[(NSUInteger)j];
                if (x.role != PBPartStructure || y.role != PBPartStructure || x.group == y.group) continue;
                simd_float2 where;
                if ([self surfaceDistance:x :y where:&where] < 0.002f) {
                    NSInteger low = MIN(x.group, y.group), high = MAX(x.group, y.group);
                    for (PBPart *part in _parts) if (part.group == high) part.group = low;
                    changed = YES;
                }
            }
        }
    }
}

#pragma mark - Checks

- (float)surfaceDistance:(PBPart *)x :(PBPart *)y where:(simd_float2 *)where {
    float best = FLT_MAX;
    for (NSInteger i = 0; i < x.count; i++) {
        for (NSInteger j = 0; j < y.count; j++) {
            simd_float2 point;
            float gap = PBCenterlineDistance(x.items[i], y.items[j], &point) - x.items[i].radius - y.items[j].radius;
            if (gap < best) { best = gap; *where = point; }
        }
    }
    return best;
}

/// A ball rolls on the floor, so whether it fits through is measured there, not through the camera.
- (float)floorDistance:(PBPart *)x :(PBPart *)y where:(simd_float2 *)where {
    float best = FLT_MAX;
    for (NSInteger i = 0; i < x.count; i++) {
        for (NSInteger j = 0; j < y.count; j++) {
            if (!x.items[i].onFloor || !y.items[j].onFloor) continue;
            simd_float2 point;
            float gap = PBCenterlineDistance(x.items[i], y.items[j], &point) - x.items[i].radius - y.items[j].radius;
            if (gap < best) { best = gap; *where = point; }
        }
    }
    return best;
}

- (BOOL)part:(PBPart *)x holdsPart:(PBPart *)y {
    if (!x.outline) return NO;
    for (NSInteger j = 0; j < y.count; j++) {
        if (PBPointInOutline(y.items[j].a, x.outline) || PBPointInOutline(y.items[j].b, x.outline)) return YES;
    }
    return NO;
}

/// Every place the two overlap is explained by one being built onto the other.
- (BOOL)partsAttach:(PBPart *)x :(PBPart *)y {
    for (NSInteger i = 0; i < x.count; i++) {
        for (NSInteger j = 0; j < y.count; j++) {
            simd_float2 point;
            float gap = PBCenterlineDistance(x.items[i], y.items[j], &point) - x.items[i].radius - y.items[j].radius;
            if (gap < 0 && !PBCapsulesAttach(x.items[i], y.items[j])) return NO;
        }
    }
    return YES;
}

- (BOOL)mayOverlap:(PBPart *)x :(PBPart *)y {
    PBPartRole a = x.role, b = y.role;
    if (a == PBPartStructure && b == PBPartStructure) return [self partsAttach:x :y];
    if ((a == PBPartFlipper && b == PBPartStructure) || (b == PBPartFlipper && a == PBPartStructure)) {
        simd_float2 where;
        return [self surfaceDistance:x :y where:&where] > -kFlipperSeat;
    }
    // A ramp starts between its entrance walls, and is carried over everything else.
    if ((a == PBPartRamp && y.rampMounted) || (b == PBPartRamp && x.rampMounted)) return YES;
    // Plastics are screwed to the walls and posts beneath them.
    if ((a == PBPartPlastic && b == PBPartStructure) || (b == PBPartPlastic && a == PBPartStructure)) return YES;
    // An insert can be set into a plate, if it lies wholly inside it.
    for (int order = 0; order < 2; order++) {
        PBPart *plate = order ? y : x, *other = order ? x : y;
        if (plate.role == PBPartPlate && other.role == PBPartInsert && other.count == 1) {
            PBCapsule lens = other.items[0], base = plate.items[0];
            if (simd_distance(lens.a, base.a) + lens.radius <= base.radius) return YES;
        }
    }
    return NO;
}

- (void)checkPairs:(NSMutableArray<PBLayoutIssue *> *)issues {
    float ball = _table.ballRadius * 2.0f;
    for (NSUInteger i = 0; i < _parts.count; i++) {
        for (NSUInteger j = i + 1; j < _parts.count; j++) {
            PBPart *x = _parts[i], *y = _parts[j];
            if (x.unseen || y.unseen) continue;
            simd_float2 where = 0;
            float gap = [self surfaceDistance:x :y where:&where];
            BOOL held = [self part:x holdsPart:y] || [self part:y holdsPart:x];
            if ((gap < 0 || held) && ![self mayOverlap:x :y]) {
                [self report:issues kind:PBLayoutIssueOverlap first:x second:y amount:held ? MAX(-gap, 0.001f) : -gap at:where];
            } else if (x.solid && y.solid && x.group != y.group) {
                float floorGap = [self floorDistance:x :y where:&where];
                if (floorGap >= 0 && floorGap < ball * kPassableFraction) {
                    [self report:issues kind:PBLayoutIssueNarrowGap first:x second:y amount:ball * kPassableFraction - floorGap at:where];
                }
            }
        }
    }
}

- (void)checkBounds:(NSMutableArray<PBLayoutIssue *> *)issues {
    simd_float2 size = _table.size;
    for (PBPart *part in _parts) {
        // Walls and the parts bolted to them are the table's own edge, and run under the apron.
        if (part.mayRunUnderApron) continue;
        for (NSInteger i = 0; i < part.count; i++) {
            PBCapsule c = part.items[i];
            simd_float2 low = simd_min(c.a, c.b) - c.radius, high = simd_max(c.a, c.b) + c.radius;
            // The phone shows a band past the table's far end, where the readouts sit.
            float top = MAX(size.y, PBTableVisibleHeight(size, _table.padding) - _table.padding.y);
            float over = MAX(MAX(MAX(-low.x, high.x - size.x), high.y - top), _table.apronY - low.y);
            if (over > 0) {
                [self report:issues kind:PBLayoutIssueOutOfBounds first:part second:nil amount:over at:(c.a + c.b) * 0.5f];
                break;
            }
        }
    }
}

- (void)report:(NSMutableArray<PBLayoutIssue *> *)issues kind:(PBLayoutIssueKind)kind first:(PBPart *)first
        second:(nullable PBPart *)second amount:(float)amount at:(simd_float2)where {
    PBLayoutIssue *issue = [PBLayoutIssue new];
    issue.kind = kind;
    issue.first = first.identifier;
    issue.second = second.identifier;
    issue.amount = amount;
    issue.location = where;
    [issues addObject:issue];
}

@end
