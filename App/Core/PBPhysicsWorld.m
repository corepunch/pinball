//
//  PBPhysicsWorld.m
//

#import "PBPhysicsWorld.h"

static const double kStepDuration = 1.0 / 960.0;
static const double kMaxCatchUp = 0.05;
static const float kMaxBallSpeed = 7.0f;
static const float kRollingDrag = 0.045f;
static const NSInteger kMaxBalls = 8;
static const float kCellSize = 0.05f;
static const NSInteger kMaxEvents = 256;
// Ignore only the tiny impulses from gravity pressing a resting ball into a surface.
static const float kMinBounceImpact = 0.02f;

static const float kFlipperAcceleration = 900.0f;
static const float kFlipperMaxSpeed = 30.0f;
static const float kFlipperReturnSpeed = 18.0f;
static const float kFlipperMovingBounce = 0.42f;
static const float kFlipperRestBounce = 0.18f;

static const float kBumperSpeed = 2.6f;
static const float kSlingSpeed = 2.5f;
static const float kSlingThreshold = 0.25f;
static const float kActiveCooldown = 0.07f;
static const float kStuckSeconds = 3.5f;

typedef NS_ENUM(uint8_t, PBColliderKind) {
    PBColliderStatic,
    PBColliderBumper,
    PBColliderSling,
    PBColliderDrop,
    PBColliderStandup,
    PBColliderGate,
};

typedef struct {
    simd_float2 a, b;
    float radius;
    float bounce;
    uint32_t layers;
    int16_t element;
    PBColliderKind kind;
    BOOL enabled;
    simd_float2 passDirection;
} PBCollider;

typedef struct {
    simd_float2 pivot;
    float angle, velocity;
    float rest, active;
    float length, baseRadius, tipRadius;
    float direction;   // +1 if rising means increasing angle.
    BOOL pressed, isLeft;
} PBFlipperState;

typedef struct {
    simd_float2 a, b;
    float angle, velocity;
    float nextScoreAngle;
} PBSpinnerState;

typedef struct {
    float length;
    NSInteger count;
    simd_float3 *points;
    float *distances;
    simd_float2 mouthA, mouthB;
} PBRampState;

typedef struct {
    simd_float2 position;
    float radius, speed, holdSeconds;
    simd_float2 direction;
    float captureSpeed;
    BOOL armed;
} PBSpotState;

static inline simd_float2 PBClosestOnSegment(simd_float2 p, simd_float2 a, simd_float2 b, float *outT) {
    simd_float2 ab = b - a;
    float denom = simd_dot(ab, ab);
    float t = denom > 1e-9f ? simd_clamp(simd_dot(p - a, ab) / denom, 0.0f, 1.0f) : 0.0f;
    if (outT) *outT = t;
    return a + ab * t;
}

/// Signed-area crossing test used by mouths and spinners.
static inline BOOL PBSegmentsCross(simd_float2 p0, simd_float2 p1, simd_float2 a, simd_float2 b) {
    simd_float2 r = p1 - p0, s = b - a;
    float denom = r.x * s.y - r.y * s.x;
    if (fabsf(denom) < 1e-9f) return NO;
    simd_float2 d = a - p0;
    float t = (d.x * s.y - d.y * s.x) / denom;
    float u = (d.x * r.y - d.y * r.x) / denom;
    return t >= 0.0f && t <= 1.0f && u >= 0.0f && u <= 1.0f;
}

@implementation PBPhysicsWorld {
    PBBall _balls[kMaxBalls];
    double _accumulator;

    PBCollider *_colliders;
    NSInteger _colliderCount;
    NSInteger _dropColliderBase;
    float *_activeCooldown;   // Per collider.

    NSInteger _gridWidth, _gridHeight;
    NSInteger *_cellStart;    // gridWidth * gridHeight + 1 offsets into _cellItems.
    int32_t *_cellItems;

    PBFlipperState *_flippers;
    NSInteger _flipperCount;
    BOOL _flippersEnabled;

    PBSpinnerState *_spinners;
    NSInteger _spinnerCount;

    PBRampState *_ramps;
    NSInteger _rampCount;

    PBSpotState *_saucers, *_kickbacks, *_magnets, *_rollovers;
    NSInteger _saucerCount, _kickbackCount, _magnetCount, _rolloverCount;
    uint8_t *_rolloverInside;  // ball * rollover.

    float *_dropDrop;          // 0 up ... 1 down, for animation.
    float *_bumperFlash;
    float *_slingFlash;
    float *_gateAngles;

    PBEvent _events[kMaxEvents];
    NSInteger _eventCount;

    float _plungerPull;
    BOOL _plungerHeld;
    float _plungerY;
    float _ballRadius;
    float _gravity;
    float _rampGravity;
    float _drainY;
    float _plungerSpeed;
    simd_float2 _plungerSpot;
    float _plungerWidth;
    float _plungerTravel;
    uint32_t _random;
}

- (instancetype)initWithTable:(PBTableDefinition *)table {
    if ((self = [super init])) {
        _table = table;
        _ballRadius = table.ballRadius;
        _gravity = table.gravity;
        _rampGravity = table.rampGravity;
        _drainY = table.drainY;
        _plungerSpeed = table.plungerSpeed;
        _plungerSpot = table.plunger.position;
        _plungerWidth = table.plunger.width;
        _plungerTravel = table.plunger.travel;
        _plungerY = _plungerSpot.y;
        _flippersEnabled = YES;
        _random = 0x9E3779B9u;
        for (NSInteger i = 0; i < kMaxBalls; i++) {
            _balls[i].state = PBBallInactive;
            _balls[i].orientation = simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f);
            _balls[i].ramp = -1;
        }
        [self buildColliders];
        [self buildGrid];
        [self buildMovingParts];
        [self spawnCaptiveBalls];
    }
    return self;
}

- (void)dealloc {
    free(_colliders); free(_activeCooldown); free(_cellStart); free(_cellItems);
    free(_flippers); free(_spinners);
    for (NSInteger i = 0; i < _rampCount; i++) { free(_ramps[i].points); free(_ramps[i].distances); }
    free(_ramps); free(_saucers); free(_kickbacks); free(_magnets); free(_rollovers);
    free(_rolloverInside); free(_dropDrop); free(_bumperFlash); free(_slingFlash); free(_gateAngles);
}

- (NSInteger)ballCapacity { return kMaxBalls; }
- (float)plungerPull { return _plungerPull; }
- (const PBBall *)balls { return _balls; }

#pragma mark - Setup

- (void)buildColliders {
    PBTableDefinition *t = _table;
    NSInteger capacity = 64;
    for (PBWallDef *wall in t.walls) capacity += wall.points.count + 1;
    for (PBRampDef *ramp in t.ramps) capacity += ramp.pointCount * 2 + 2;
    capacity += (NSInteger)(t.posts.count + t.bumpers.count + t.slingshots.count + t.dropTargets.count + t.standups.count + t.gates.count);
    _colliders = calloc((size_t)capacity, sizeof(PBCollider));
    _activeCooldown = calloc((size_t)capacity, sizeof(float));

    __block NSInteger n = 0;
    void (^add)(simd_float2, simd_float2, float, float, uint32_t, PBColliderKind, NSInteger) =
    ^(simd_float2 a, simd_float2 b, float radius, float bounce, uint32_t layers, PBColliderKind kind, NSInteger element) {
        PBCollider *c = &self->_colliders[n++];
        c->a = a; c->b = b; c->radius = radius; c->bounce = bounce; c->layers = layers;
        c->kind = kind; c->element = (int16_t)element; c->enabled = YES;
    };

    for (PBWallDef *wall in t.walls) {
        float bounce = wall.style == PBWallStyleRubber ? 0.72f : (wall.style == PBWallStyleRail ? 0.32f : 0.42f);
        const simd_float2 *p = wall.points.points;
        for (NSInteger i = 0; i + 1 < wall.points.count; i++) add(p[i], p[i + 1], wall.radius, bounce, (uint32_t)wall.layers, PBColliderStatic, -1);
        if (wall.closed) add(p[wall.points.count - 1], p[0], wall.radius, bounce, (uint32_t)wall.layers, PBColliderStatic, -1);
    }
    for (PBSpotDef *post in t.posts) add(post.position, post.position, post.radius, 0.72f, PBLayerPlayfield, PBColliderStatic, -1);

    [t.bumpers enumerateObjectsUsingBlock:^(PBSpotDef *b, NSUInteger i, BOOL *stop) {
        add(b.position, b.position, b.radius, 0.3f, PBLayerPlayfield, PBColliderBumper, (NSInteger)i);
    }];
    [t.slingshots enumerateObjectsUsingBlock:^(PBEdgeDef *s, NSUInteger i, BOOL *stop) {
        add(s.a, s.b, 0.008f, 0.6f, PBLayerPlayfield, PBColliderSling, (NSInteger)i);
    }];
    _dropColliderBase = n;
    [t.dropTargets enumerateObjectsUsingBlock:^(PBEdgeDef *d, NSUInteger i, BOOL *stop) {
        add(d.a, d.b, 0.006f, 0.3f, PBLayerPlayfield, PBColliderDrop, (NSInteger)i);
    }];
    [t.standups enumerateObjectsUsingBlock:^(PBEdgeDef *s, NSUInteger i, BOOL *stop) {
        add(s.a, s.b, 0.005f, 0.4f, PBLayerPlayfield | PBLayerCaptive, PBColliderStandup, (NSInteger)i);
    }];
    [t.gates enumerateObjectsUsingBlock:^(PBEdgeDef *g, NSUInteger i, BOOL *stop) {
        add(g.a, g.b, 0.004f, 0.2f, PBLayerPlayfield, PBColliderGate, (NSInteger)i);
        self->_colliders[n - 1].passDirection = g.passDirection;
    }];

    // Side rails for each ramp, offset from its centreline; only balls on the ramp feel them.
    for (PBRampDef *ramp in t.ramps) {
        NSInteger count = ramp.pointCount;
        simd_float2 previousL = 0, previousR = 0;
        for (NSInteger i = 0; i < count; i++) {
            simd_float3 p = [ramp pointAtIndex:i];
            simd_float3 prev = [ramp pointAtIndex:MAX(i - 1, 0)];
            simd_float3 next = [ramp pointAtIndex:MIN(i + 1, count - 1)];
            simd_float2 tangent = simd_normalize(next.xy - prev.xy);
            simd_float2 normal = simd_make_float2(-tangent.y, tangent.x);
            simd_float2 left = p.xy + normal * ramp.width * 0.5f;
            simd_float2 right = p.xy - normal * ramp.width * 0.5f;
            if (i > 0) {
                add(previousL, left, 0.004f, 0.3f, PBLayerRamp, PBColliderStatic, -1);
                add(previousR, right, 0.004f, 0.3f, PBLayerRamp, PBColliderStatic, -1);
            }
            previousL = left; previousR = right;
        }
    }
    _colliderCount = n;
}

- (void)buildGrid {
    _gridWidth = (NSInteger)ceilf(_table.size.x / kCellSize) + 1;
    _gridHeight = (NSInteger)ceilf(_table.size.y / kCellSize) + 1;
    NSInteger cells = _gridWidth * _gridHeight;
    NSInteger *counts = calloc((size_t)cells + 1, sizeof(NSInteger));

    void (^visit)(BOOL) = ^(BOOL fill) {
        for (NSInteger i = 0; i < self->_colliderCount; i++) {
            PBCollider *c = &self->_colliders[i];
            float reach = c->radius + self->_ballRadius + 0.012f;
            NSInteger x0 = MAX(0, (NSInteger)floorf((MIN(c->a.x, c->b.x) - reach) / kCellSize));
            NSInteger x1 = MIN(self->_gridWidth - 1, (NSInteger)floorf((MAX(c->a.x, c->b.x) + reach) / kCellSize));
            NSInteger y0 = MAX(0, (NSInteger)floorf((MIN(c->a.y, c->b.y) - reach) / kCellSize));
            NSInteger y1 = MIN(self->_gridHeight - 1, (NSInteger)floorf((MAX(c->a.y, c->b.y) + reach) / kCellSize));
            for (NSInteger y = y0; y <= y1; y++) {
                for (NSInteger x = x0; x <= x1; x++) {
                    simd_float2 cellCenter = simd_make_float2((x + 0.5f) * kCellSize, (y + 0.5f) * kCellSize);
                    simd_float2 q = PBClosestOnSegment(cellCenter, c->a, c->b, NULL);
                    if (simd_distance(cellCenter, q) > reach + kCellSize * 0.72f) continue;
                    NSInteger cell = y * self->_gridWidth + x;
                    if (fill) self->_cellItems[counts[cell]++] = (int32_t)i;
                    else counts[cell]++;
                }
            }
        }
    };

    visit(NO);
    _cellStart = calloc((size_t)cells + 1, sizeof(NSInteger));
    NSInteger total = 0;
    for (NSInteger i = 0; i < cells; i++) {
        _cellStart[i] = total;
        NSInteger count = counts[i];
        counts[i] = total;
        total += count;
    }
    _cellStart[cells] = total;
    _cellItems = calloc((size_t)MAX(total, 1), sizeof(int32_t));
    visit(YES);
    free(counts);
}

static PBSpotState PBSpotFrom(PBSpotDef *def) {
    PBSpotState spot = {0};
    spot.position = def.position;
    spot.radius = def.radius;
    spot.speed = def.speed;
    spot.holdSeconds = def.holdSeconds;
    spot.direction = def.direction;
    spot.captureSpeed = def.captureSpeed;
    return spot;
}

- (void)buildMovingParts {
    PBTableDefinition *t = _table;

    _flipperCount = (NSInteger)t.flippers.count;
    _flippers = calloc((size_t)MAX(_flipperCount, 1), sizeof(PBFlipperState));
    for (NSInteger i = 0; i < _flipperCount; i++) {
        PBFlipperDef *def = t.flippers[(NSUInteger)i];
        PBFlipperState *f = &_flippers[i];
        f->pivot = def.pivot;
        f->rest = def.restAngle;
        f->active = def.activeAngle;
        f->angle = def.restAngle;
        f->length = def.length;
        f->baseRadius = def.baseRadius;
        f->tipRadius = def.tipRadius;
        f->isLeft = def.isLeft;
        f->direction = def.activeAngle > def.restAngle ? 1.0f : -1.0f;
    }

    _spinnerCount = (NSInteger)t.spinners.count;
    _spinners = calloc((size_t)MAX(_spinnerCount, 1), sizeof(PBSpinnerState));
    for (NSInteger i = 0; i < _spinnerCount; i++) {
        _spinners[i].a = t.spinners[(NSUInteger)i].a;
        _spinners[i].b = t.spinners[(NSUInteger)i].b;
        _spinners[i].nextScoreAngle = (float)M_PI;
    }

    _rampCount = (NSInteger)t.ramps.count;
    _ramps = calloc((size_t)MAX(_rampCount, 1), sizeof(PBRampState));
    for (NSInteger i = 0; i < _rampCount; i++) {
        PBRampDef *def = t.ramps[(NSUInteger)i];
        PBRampState *r = &_ramps[i];
        r->count = def.pointCount;
        r->points = calloc((size_t)r->count, sizeof(simd_float3));
        r->distances = calloc((size_t)r->count, sizeof(float));
        r->mouthA = def.mouthA;
        r->mouthB = def.mouthB;
        for (NSInteger p = 0; p < r->count; p++) {
            r->points[p] = [def pointAtIndex:p];
            if (p > 0) r->distances[p] = r->distances[p - 1] + simd_distance(r->points[p].xy, r->points[p - 1].xy);
        }
        r->length = r->distances[r->count - 1];
    }

    PBSpotState *(^spots)(NSArray<PBSpotDef *> *) = ^PBSpotState *(NSArray<PBSpotDef *> *defs) {
        PBSpotState *out = calloc(MAX(defs.count, 1u), sizeof(PBSpotState));
        for (NSUInteger i = 0; i < defs.count; i++) out[i] = PBSpotFrom(defs[i]);
        return out;
    };
    _saucers = spots(t.saucers); _saucerCount = (NSInteger)t.saucers.count;
    _kickbacks = spots(t.kickbacks); _kickbackCount = (NSInteger)t.kickbacks.count;
    _magnets = spots(t.magnets); _magnetCount = (NSInteger)t.magnets.count;
    _rollovers = spots(t.rollovers); _rolloverCount = (NSInteger)t.rollovers.count;
    _rolloverInside = calloc((size_t)(kMaxBalls * MAX(_rolloverCount, 1)), 1);

    _dropDrop = calloc(MAX(t.dropTargets.count, 1u), sizeof(float));
    _bumperFlash = calloc(MAX(t.bumpers.count, 1u), sizeof(float));
    _slingFlash = calloc(MAX(t.slingshots.count, 1u), sizeof(float));
    _gateAngles = calloc(MAX(t.gates.count, 1u), sizeof(float));
    for (NSUInteger i = 0; i < t.bumpers.count; i++) _bumperFlash[i] = 10.0f;
    for (NSUInteger i = 0; i < t.slingshots.count; i++) _slingFlash[i] = 10.0f;
}

- (void)spawnCaptiveBalls {
    for (PBSpotDef *def in _table.captiveBalls) {
        NSInteger index = [self freeBallSlot];
        if (index < 0) return;
        PBBall *ball = &_balls[index];
        ball->state = PBBallFree;
        ball->captive = YES;
        ball->position = def.position;
        ball->velocity = 0;
        ball->z = _ballRadius;
        ball->layers = PBLayerPlayfield | PBLayerCaptive;
        ball->ramp = -1;
    }
}

#pragma mark - Public controls

- (NSInteger)freeBallSlot {
    for (NSInteger i = 0; i < kMaxBalls; i++) if (_balls[i].state == PBBallInactive) return i;
    return -1;
}

- (NSInteger)activeBallCount {
    NSInteger count = 0;
    for (NSInteger i = 0; i < kMaxBalls; i++) if (_balls[i].state != PBBallInactive && !_balls[i].captive) count++;
    return count;
}

- (NSInteger)spawnBallAtPlunger {
    NSInteger index = [self freeBallSlot];
    if (index < 0) return -1;
    PBBall *ball = &_balls[index];
    ball->state = PBBallFree;
    ball->captive = NO;
    ball->position = simd_make_float2(_plungerSpot.x, _plungerY + _ballRadius + 0.002f);
    ball->velocity = 0;
    ball->z = _ballRadius;
    ball->zVelocity = 0;
    ball->layers = PBLayerPlayfield;
    ball->ramp = -1;
    ball->stuckTime = 0;
    if (_rolloverCount) memset(&_rolloverInside[index * _rolloverCount], 0, (size_t)_rolloverCount);
    return index;
}

- (BOOL)isBallInLane:(const PBBall *)ball {
    return fabsf(ball->position.x - _plungerSpot.x) < _plungerWidth * 0.75f;
}

- (BOOL)isBallOnPlunger {
    for (NSInteger i = 0; i < kMaxBalls; i++) {
        PBBall *ball = &_balls[i];
        if (ball->state != PBBallFree || ball->captive) continue;
        if ([self isBallInLane:ball] && ball->position.y < _plungerSpot.y + _ballRadius + 0.03f) return YES;
    }
    return NO;
}

- (void)removeAllPlayBalls {
    // A restart while charging must not carry the old plunger into the new game.
    _plungerHeld = NO;
    _plungerPull = 0;
    _plungerY = _plungerSpot.y;
    for (NSInteger i = 0; i < kMaxBalls; i++) if (!_balls[i].captive) _balls[i].state = PBBallInactive;
}

- (void)removeBall:(NSInteger)index { _balls[index].state = PBBallInactive; }

- (void)placeBall:(NSInteger)index at:(simd_float2)position velocity:(simd_float2)velocity {
    _balls[index].position = position;
    _balls[index].velocity = velocity;
}

- (void)setFlipperGroupLeft:(BOOL)left pressed:(BOOL)pressed {
    if (!_flippersEnabled && pressed) return;
    for (NSInteger i = 0; i < _flipperCount; i++) {
        PBFlipperState *f = &_flippers[i];
        if (f->isLeft != left || f->pressed == pressed) continue;
        f->pressed = pressed;
        [self emit:pressed ? PBEventFlipperUp : PBEventFlipperDown element:i ball:-1 magnitude:0 at:f->pivot];
    }
}

- (void)setFlippersEnabled:(BOOL)enabled {
    _flippersEnabled = enabled;
    if (!enabled) {
        [self setFlipperGroupLeft:YES pressed:NO];
        [self setFlipperGroupLeft:NO pressed:NO];
    }
}

- (void)setPlungerPulled:(BOOL)pulled {
    if (_plungerHeld && !pulled) [self releasePlungerWithStrength:_plungerPull];
    _plungerHeld = pulled;
}

- (void)releasePlungerWithStrength:(float)strength {
    [self emit:PBEventPlungerRelease element:0 ball:-1 magnitude:strength at:_plungerSpot];
    for (NSInteger i = 0; i < kMaxBalls; i++) {
        PBBall *ball = &_balls[i];
        if (ball->state != PBBallFree || ball->captive || ![self isBallInLane:ball]) continue;
        if (ball->position.y < _plungerSpot.y + _ballRadius + 0.03f) {
            ball->velocity = simd_make_float2(0.0f, _plungerSpeed * strength);
        }
    }
    _plungerPull = 0;
    _plungerY = _plungerSpot.y;
}

- (void)autoPlunge { [self releasePlungerWithStrength:0.9f]; }

- (void)nudge:(simd_float2)impulse {
    for (NSInteger i = 0; i < kMaxBalls; i++) {
        if (_balls[i].state == PBBallFree && !_balls[i].captive) _balls[i].velocity += impulse;
    }
}

- (void)setDropTarget:(NSInteger)index up:(BOOL)up {
    _colliders[_dropColliderBase + index].enabled = up;
}

- (BOOL)isDropTargetUp:(NSInteger)index { return _colliders[_dropColliderBase + index].enabled; }

- (void)ejectSaucer:(NSInteger)index {
    PBSpotState *saucer = &_saucers[index];
    for (NSInteger i = 0; i < kMaxBalls; i++) {
        PBBall *ball = &_balls[i];
        if (ball->state == PBBallInSaucer && ball->holder == index) {
            ball->state = PBBallFree;
            ball->velocity = saucer->direction * saucer->speed;
            ball->stuckTime = 0;
            [self emit:PBEventSaucerEject element:index ball:i magnitude:saucer->speed at:ball->position];
        }
    }
}

- (void)setKickback:(NSInteger)index armed:(BOOL)armed { _kickbacks[index].armed = armed; }
- (void)setMagnet:(NSInteger)index armed:(BOOL)armed { _magnets[index].armed = armed; }

#pragma mark - Drawing state

- (float)flipperAngle:(NSInteger)index { return _flippers[index].angle; }
- (float)spinnerAngle:(NSInteger)index { return _spinners[index].angle; }
- (float)gateAngle:(NSInteger)index { return _gateAngles[index]; }
- (float)dropTargetDrop:(NSInteger)index { return _dropDrop[index]; }
- (float)bumperFlash:(NSInteger)index { return _bumperFlash[index]; }
- (float)slingFlash:(NSInteger)index { return _slingFlash[index]; }

#pragma mark - Events

- (void)emit:(PBEventKind)kind element:(NSInteger)element ball:(NSInteger)ball magnitude:(float)magnitude at:(simd_float2)position {
    if (_eventCount >= kMaxEvents) return;
    _events[_eventCount++] = (PBEvent){ kind, (int16_t)element, (int16_t)ball, magnitude, position };
}

- (void)drainEvents:(void (NS_NOESCAPE ^)(const PBEvent *))handler {
    // Handlers can call back in and queue more, so snapshot the count on each pass.
    NSInteger index = 0;
    while (index < _eventCount) {
        PBEvent event = _events[index++];
        handler(&event);
    }
    _eventCount = 0;
}

#pragma mark - Stepping

- (void)advanceBy:(double)elapsed {
    _accumulator += MIN(elapsed, kMaxCatchUp);
    while (_accumulator >= kStepDuration) {
        [self stepWithDuration:(float)kStepDuration];
        _accumulator -= kStepDuration;
    }
}

- (void)stepWithDuration:(float)dt {
    if (_plungerHeld) {
        _plungerPull = MIN(1.0f, _plungerPull + dt / 0.9f);
        _plungerY = _plungerSpot.y - _plungerPull * _plungerTravel;
    }
    for (NSInteger i = 0; i < _flipperCount; i++) [self stepFlipper:&_flippers[i] dt:dt];
    for (NSInteger i = 0; i < _spinnerCount; i++) [self stepSpinner:i dt:dt];
    for (NSInteger i = 0; i < _colliderCount; i++) if (_activeCooldown[i] > 0.0f) _activeCooldown[i] -= dt;

    PBTableDefinition *t = _table;
    NSInteger dropCount = (NSInteger)t.dropTargets.count;
    for (NSInteger i = 0; i < dropCount; i++) {
        float target = _colliders[_dropColliderBase + i].enabled ? 0.0f : 1.0f;
        float rate = target > _dropDrop[i] ? 14.0f : 6.0f;
        float delta = simd_clamp(target - _dropDrop[i], -rate * dt, rate * dt);
        _dropDrop[i] += delta;
    }
    for (NSUInteger i = 0; i < t.bumpers.count; i++) _bumperFlash[i] += dt;
    for (NSUInteger i = 0; i < t.slingshots.count; i++) _slingFlash[i] += dt;
    for (NSUInteger i = 0; i < t.gates.count; i++) _gateAngles[i] *= (1.0f - 5.0f * dt);

    for (NSInteger i = 0; i < kMaxBalls; i++) {
        PBBall *ball = &_balls[i];
        if (ball->state == PBBallInactive) continue;
        if (ball->state == PBBallInSaucer) continue;
        if (ball->state == PBBallHeldByMagnet) { [self stepHeldBall:i dt:dt]; continue; }
        [self stepBall:i dt:dt];
    }
    [self collideBallsWithEachOther];
}

- (void)stepFlipper:(PBFlipperState *)f dt:(float)dt {
    float target = f->pressed ? f->active : f->rest;
    float toTarget = target - f->angle;
    if (fabsf(toTarget) < 1e-4f) { f->velocity = 0; return; }
    float sign = toTarget > 0 ? 1.0f : -1.0f;
    float maxSpeed = f->pressed ? kFlipperMaxSpeed : kFlipperReturnSpeed;
    f->velocity = simd_clamp(f->velocity + sign * kFlipperAcceleration * dt, -maxSpeed, maxSpeed);
    float step = f->velocity * dt;
    if ((sign > 0 && step >= toTarget) || (sign < 0 && step <= toTarget)) {
        f->angle = target;
        f->velocity = 0;
    } else {
        f->angle += step;
    }
}

- (void)stepSpinner:(NSInteger)index dt:(float)dt {
    PBSpinnerState *s = &_spinners[index];
    if (fabsf(s->velocity) < 0.01f) {
        // Settle back to hanging straight down.
        float rest = roundf(s->angle / (2.0f * (float)M_PI)) * 2.0f * (float)M_PI;
        s->angle += (rest - s->angle) * MIN(1.0f, 6.0f * dt);
        s->velocity = 0;
        return;
    }
    s->angle += s->velocity * dt;
    s->velocity -= s->velocity * 1.1f * dt;
    s->velocity -= copysignf(MIN(fabsf(s->velocity), 2.5f * dt), s->velocity);
    float a = fabsf(s->angle);
    if (a >= s->nextScoreAngle) {
        s->nextScoreAngle += 2.0f * (float)M_PI;
        [self emit:PBEventSpinner element:index ball:-1 magnitude:fabsf(s->velocity) at:(s->a + s->b) * 0.5f];
    }
}

- (void)stepHeldBall:(NSInteger)index dt:(float)dt {
    PBBall *ball = &_balls[index];
    PBSpotState *magnet = &_magnets[ball->holder];
    ball->position += (magnet->position - ball->position) * MIN(1.0f, 12.0f * dt);
    ball->holdTimer -= dt;
    if (ball->holdTimer <= 0.0f) {
        float angle = (float)M_PI * (0.25f + 0.5f * [self randomUnit]);
        ball->velocity = simd_make_float2(cosf(angle), sinf(angle)) * magnet->speed;
        ball->state = PBBallFree;
        ball->stuckTime = 0;
    }
}

- (float)randomUnit {
    _random ^= _random << 13; _random ^= _random >> 17; _random ^= _random << 5;
    return (float)(_random & 0xFFFFFF) / (float)0xFFFFFF;
}

- (void)stepBall:(NSInteger)index dt:(float)dt {
    PBBall *ball = &_balls[index];
    simd_float2 previous = ball->position;

    simd_float2 acceleration = simd_make_float2(0.0f, -_gravity);
    float groundZ = 0.0f;
    if (ball->ramp >= 0) acceleration += [self rampForceForBall:ball groundZ:&groundZ];

    for (NSInteger m = 0; m < _magnetCount; m++) [self applyMagnet:m toBall:index dt:dt];
    if (ball->state != PBBallFree) return;

    ball->velocity += acceleration * dt;
    ball->velocity -= ball->velocity * kRollingDrag * dt;
    float speed = simd_length(ball->velocity);
    if (speed > kMaxBallSpeed) ball->velocity *= kMaxBallSpeed / speed;
    ball->position += ball->velocity * dt;

    // Vertical motion is only for drawing and for falling off a ramp end.
    float restZ = groundZ + _ballRadius;
    if (ball->z > restZ + 1e-4f && ball->ramp < 0) {
        ball->zVelocity -= 12.0f * dt;
        ball->z += ball->zVelocity * dt;
        if (ball->z <= restZ) { ball->z = restZ; ball->zVelocity = 0; }
    } else {
        ball->z = restZ;
        ball->zVelocity = 0;
    }

    [self collideBall:index];
    [self collideFlippers:index];
    [self checkSensors:index previous:previous];
    [self rollBall:ball moved:ball->position - previous];

    // Ball search: a ball that has stayed in one small spot, even if jittering, gets a shove.
    if (ball->captive || [self isBallInLane:ball] || simd_distance(ball->position, ball->stuckAnchor) > 0.03f) {
        ball->stuckAnchor = ball->position;
        ball->stuckTime = 0;
    } else {
        ball->stuckTime += dt;
        if (ball->stuckTime > kStuckSeconds) {
            ball->stuckTime = 0;
            float angle = 2.0f * (float)M_PI * [self randomUnit];
            ball->velocity = simd_make_float2(cosf(angle), sinf(angle)) * 1.6f;
            [self emit:PBEventBallStuck element:0 ball:index magnitude:0 at:ball->position];
        }
    }

    if (ball->position.y < _drainY && ball->ramp < 0 && ![self isBallInLane:ball]) {
        ball->state = PBBallInactive;
        [self emit:PBEventDrain element:0 ball:index magnitude:0 at:ball->position];
    }
}

- (simd_float2)rampForceForBall:(PBBall *)ball groundZ:(float *)groundZ {
    PBRampState *r = &_ramps[ball->ramp];
    float bestDistance = FLT_MAX, bestS = 0, bestZ = 0, bestSlope = 0;
    simd_float2 bestTangent = simd_make_float2(0.0f, 1.0f);
    for (NSInteger i = 0; i + 1 < r->count; i++) {
        simd_float3 a = r->points[i], b = r->points[i + 1];
        float t;
        simd_float2 q = PBClosestOnSegment(ball->position, a.xy, b.xy, &t);
        float distance = simd_distance_squared(ball->position, q);
        if (distance < bestDistance) {
            bestDistance = distance;
            float length = simd_distance(a.xy, b.xy);
            bestS = r->distances[i] + t * length;
            bestZ = a.z + (b.z - a.z) * t;
            bestSlope = (b.z - a.z) / MAX(length, 1e-4f);
            bestTangent = (b.xy - a.xy) / MAX(length, 1e-4f);
        }
    }
    ball->rampDistance = bestS;
    *groundZ = bestZ;
    return -bestTangent * bestSlope * _rampGravity;
}

- (void)applyMagnet:(NSInteger)m toBall:(NSInteger)index dt:(float)dt {
    PBSpotState *magnet = &_magnets[m];
    PBBall *ball = &_balls[index];
    if (!magnet->armed || ball->captive || ball->ramp >= 0) return;
    simd_float2 delta = magnet->position - ball->position;
    float distance = simd_length(delta);
    if (distance > magnet->radius) return;
    ball->velocity += delta / MAX(distance, 1e-3f) * 14.0f * dt;
    if (distance < 0.02f) {
        ball->state = PBBallHeldByMagnet;
        ball->holder = (int16_t)m;
        ball->holdTimer = magnet->holdSeconds;
        ball->velocity = 0;
        magnet->armed = NO;
        [self emit:PBEventMagnetGrab element:m ball:index magnitude:0 at:magnet->position];
    }
}

- (void)rollBall:(PBBall *)ball moved:(simd_float2)moved {
    float distance = simd_length(moved);
    if (distance < 1e-6f) return;
    // Rolling without slipping about the axis perpendicular to travel, in table space.
    simd_float3 axis = simd_normalize(simd_make_float3(-moved.y, moved.x, 0.0f));
    simd_quatf turn = simd_quaternion(distance / _ballRadius, axis);
    ball->orientation = simd_normalize(simd_mul(turn, ball->orientation));
}

- (void)collideBall:(NSInteger)index {
    PBBall *ball = &_balls[index];
    NSInteger cx = (NSInteger)floorf(ball->position.x / kCellSize);
    NSInteger cy = (NSInteger)floorf(ball->position.y / kCellSize);
    if (cx < 0 || cy < 0 || cx >= _gridWidth || cy >= _gridHeight) {
        // Escaped the table, which should be impossible. Treat it as a drain so play continues.
        ball->state = PBBallInactive;
        [self emit:PBEventDrain element:0 ball:index magnitude:0 at:ball->position];
        return;
    }
    NSInteger cell = cy * _gridWidth + cx;
    for (NSInteger i = _cellStart[cell]; i < _cellStart[cell + 1]; i++) {
        PBCollider *c = &_colliders[_cellItems[i]];
        if (!c->enabled || !(c->layers & ball->layers)) continue;
        [self resolveBall:index against:c colliderIndex:_cellItems[i]];
    }
    [self collidePlunger:index];
}

- (void)collidePlunger:(NSInteger)index {
    PBBall *ball = &_balls[index];
    if (![self isBallInLane:ball]) return;
    float floorY = _plungerY + _ballRadius;
    if (ball->position.y < floorY) {
        ball->position.y = floorY;
        float impact = -ball->velocity.y;
        if (ball->velocity.y < 0.0f) ball->velocity.y *= -0.2f;
        if (fabsf(ball->velocity.y) < 0.05f) ball->velocity.y = 0;
        if (impact > 0.0f && ball->velocity.y > 0.0f) {
            [self emit:PBEventWallHit element:-1 ball:index magnitude:impact at:ball->position];
        }
    }
}

- (void)resolveBall:(NSInteger)index against:(PBCollider *)c colliderIndex:(int32_t)colliderIndex {
    PBBall *ball = &_balls[index];
    simd_float2 q = PBClosestOnSegment(ball->position, c->a, c->b, NULL);
    simd_float2 delta = ball->position - q;
    float reach = _ballRadius + c->radius;
    float distanceSquared = simd_length_squared(delta);
    if (distanceSquared >= reach * reach || distanceSquared < 1e-12f) return;

    if (c->kind == PBColliderGate) {
        // One-way wire: open to a ball moving with the pass direction, solid against it.
        if (simd_dot(ball->velocity, c->passDirection) > 0.0f) {
            _gateAngles[c->element] = 1.0f;
            return;
        }
    }

    float distance = sqrtf(distanceSquared);
    simd_float2 normal = delta / distance;
    ball->position = q + normal * reach;

    float vn = simd_dot(ball->velocity, normal);
    if (vn >= 0.0f) return;
    float impact = -vn;

    ball->velocity -= normal * vn * (1.0f + c->bounce);
    // Tangential friction scales with impact, so a ball rolling along a guide keeps its speed.
    simd_float2 tangent = ball->velocity - normal * simd_dot(ball->velocity, normal);
    ball->velocity -= tangent * MIN(0.04f, impact * 0.02f);

    BOOL activeHit = NO;
    switch (c->kind) {
        case PBColliderBumper:
            if (_activeCooldown[colliderIndex] <= 0.0f) {
                _activeCooldown[colliderIndex] = kActiveCooldown;
                float out = simd_dot(ball->velocity, normal);
                ball->velocity += normal * MAX(0.0f, kBumperSpeed - out);
                _bumperFlash[c->element] = 0;
                [self emit:PBEventBumper element:c->element ball:index magnitude:impact at:ball->position];
                activeHit = YES;
            }
            break;
        case PBColliderSling:
            if (impact > kSlingThreshold && _activeCooldown[colliderIndex] <= 0.0f) {
                _activeCooldown[colliderIndex] = kActiveCooldown;
                ball->velocity += normal * kSlingSpeed;
                _slingFlash[c->element] = 0;
                [self emit:PBEventSling element:c->element ball:index magnitude:impact at:ball->position];
                activeHit = YES;
            }
            break;
        case PBColliderDrop:
            c->enabled = NO;
            [self emit:PBEventDropTarget element:c->element ball:index magnitude:impact at:ball->position];
            activeHit = YES;
            break;
        case PBColliderStandup:
            if (_activeCooldown[colliderIndex] <= 0.0f) {
                _activeCooldown[colliderIndex] = kActiveCooldown;
                [self emit:PBEventStandup element:c->element ball:index magnitude:impact at:ball->position];
                activeHit = YES;
            }
            break;
        default:
            break;
    }
    // A passive rebound still happens when an element is cooling down or a sling
    // is hit too gently to fire. Report it once, without duplicating active hits.
    if (!activeHit && impact > kMinBounceImpact) {
        [self emit:PBEventWallHit element:-1 ball:index magnitude:impact at:ball->position];
    }
}

- (void)collideFlippers:(NSInteger)index {
    PBBall *ball = &_balls[index];
    if (!(ball->layers & PBLayerPlayfield)) return;
    for (NSInteger i = 0; i < _flipperCount; i++) {
        PBFlipperState *f = &_flippers[i];
        simd_float2 axis = simd_make_float2(cosf(f->angle), sinf(f->angle));
        simd_float2 tip = f->pivot + axis * f->length;
        float t;
        simd_float2 q = PBClosestOnSegment(ball->position, f->pivot, tip, &t);
        float radius = f->baseRadius + (f->tipRadius - f->baseRadius) * t;
        simd_float2 delta = ball->position - q;
        float reach = _ballRadius + radius;
        float distanceSquared = simd_length_squared(delta);
        if (distanceSquared >= reach * reach || distanceSquared < 1e-12f) continue;

        float distance = sqrtf(distanceSquared);
        simd_float2 normal = delta / distance;
        ball->position = q + normal * reach;

        // Surface velocity at the contact point: omega x r.
        simd_float2 r = ball->position - f->pivot;
        simd_float2 surface = simd_make_float2(-r.y, r.x) * f->velocity;
        simd_float2 relative = ball->velocity - surface;
        float vn = simd_dot(relative, normal);
        if (vn < 0.0f) {
            BOOL moving = fabsf(f->velocity) > 1.0f;
            float bounce = moving ? kFlipperMovingBounce : kFlipperRestBounce;
            ball->velocity -= normal * vn * (1.0f + bounce);
            if (-vn > kMinBounceImpact) [self emit:PBEventWallHit element:-1 ball:index magnitude:-vn at:ball->position];
        }
        ball->stuckTime = f->pressed ? 0.0f : ball->stuckTime;
    }
}

- (void)checkSensors:(NSInteger)index previous:(simd_float2)previous {
    PBBall *ball = &_balls[index];
    if (ball->captive) return;

    for (NSInteger s = 0; s < _spinnerCount; s++) {
        PBSpinnerState *spinner = &_spinners[s];
        if (ball->ramp < 0 && PBSegmentsCross(previous, ball->position, spinner->a, spinner->b)) {
            float speed = ball->velocity.y;
            spinner->velocity += speed * 14.0f;
        }
    }

    if (ball->ramp < 0) {
        uint8_t *inside = &_rolloverInside[index * _rolloverCount];
        for (NSInteger r = 0; r < _rolloverCount; r++) {
            BOOL isInside = simd_distance_squared(ball->position, _rollovers[r].position) < _rollovers[r].radius * _rollovers[r].radius;
            if (isInside && !inside[r]) [self emit:PBEventRollover element:r ball:index magnitude:0 at:ball->position];
            inside[r] = (uint8_t)isInside;
        }
        for (NSInteger k = 0; k < _kickbackCount; k++) {
            PBSpotState *kick = &_kickbacks[k];
            if (kick->armed && simd_distance_squared(ball->position, kick->position) < kick->radius * kick->radius && ball->velocity.y < 0.0f) {
                ball->velocity = simd_make_float2(0.0f, kick->speed);
                kick->armed = NO;
                [self emit:PBEventKickback element:k ball:index magnitude:0 at:kick->position];
            }
        }
        for (NSInteger w = 0; w < _saucerCount; w++) {
            PBSpotState *saucer = &_saucers[w];
            float distance = simd_distance(ball->position, saucer->position);
            if (distance < saucer->radius && simd_length(ball->velocity) < saucer->captureSpeed) {
                ball->state = PBBallInSaucer;
                ball->holder = (int16_t)w;
                ball->position = saucer->position;
                ball->velocity = 0;
                [self emit:PBEventSaucerCapture element:w ball:index magnitude:0 at:saucer->position];
                return;
            }
        }
        for (NSInteger m = 0; m < _rampCount; m++) {
            PBRampState *ramp = &_ramps[m];
            if (ball->velocity.y > 0.0f && PBSegmentsCross(previous, ball->position, ramp->mouthA, ramp->mouthB)) {
                ball->ramp = (int16_t)m;
                ball->layers = PBLayerRamp;
                ball->rampDistance = 0;
                [self emit:PBEventRampEnter element:m ball:index magnitude:0 at:ball->position];
            }
        }
    } else {
        PBRampState *ramp = &_ramps[ball->ramp];
        if (ball->rampDistance >= ramp->length - 0.002f) {
            NSInteger finished = ball->ramp;
            ball->ramp = -1;
            ball->layers = PBLayerPlayfield;
            ball->zVelocity = 0;
            [self emit:PBEventRampComplete element:finished ball:index magnitude:0 at:ball->position];
        } else if (ball->rampDistance <= 0.002f && simd_dot(ball->position - previous, ramp->mouthB - ramp->mouthA) <= 1.0f && ball->velocity.y < 0.0f) {
            ball->ramp = -1;
            ball->layers = PBLayerPlayfield;
        }
    }
}

- (void)collideBallsWithEachOther {
    for (NSInteger i = 0; i < kMaxBalls; i++) {
        PBBall *a = &_balls[i];
        if (a->state != PBBallFree) continue;
        for (NSInteger j = i + 1; j < kMaxBalls; j++) {
            PBBall *b = &_balls[j];
            if (b->state != PBBallFree) continue;
            if ((a->ramp >= 0) != (b->ramp >= 0)) continue;
            simd_float2 delta = a->position - b->position;
            float reach = _ballRadius * 2.0f;
            float distanceSquared = simd_length_squared(delta);
            if (distanceSquared >= reach * reach || distanceSquared < 1e-10f) continue;
            float distance = sqrtf(distanceSquared);
            simd_float2 normal = delta / distance;
            float overlap = (reach - distance) * 0.5f;
            a->position += normal * overlap;
            b->position -= normal * overlap;
            float vn = simd_dot(a->velocity - b->velocity, normal);
            if (vn < 0.0f) {
                simd_float2 impulse = normal * vn * 0.5f * (1.0f + 0.85f);
                a->velocity -= impulse;
                b->velocity += impulse;
                if (-vn > kMinBounceImpact) [self emit:PBEventWallHit element:-1 ball:i magnitude:-vn at:a->position];
            }
        }
    }
}

@end
