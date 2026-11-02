//
//  PBGame.m
//

#import "PBGame.h"
#import <stdatomic.h>

@interface PBGame () <PBRuleEngineDelegate>
@end

@implementation PBGame {
    NSHashTable<id<PBGameObserver>> *_observers;
    _Atomic(BOOL) _leftInput, _rightInput, _plungerInput, _newGameRequested;
    _Atomic(float) _nudgeX, _nudgeY;
    BOOL _leftApplied, _rightApplied;
    BOOL _charging;
    double _autoLeftUntil, _autoRightUntil, _autoPlungeUntil, _clock;
    uint32_t _autoSeed;
}

- (instancetype)initWithTable:(PBTableDefinition *)table highScore:(int64_t)highScore {
    return [self initWithTable:table highScore:highScore seed:0x2545F491u];
}

- (instancetype)initWithTable:(PBTableDefinition *)table highScore:(int64_t)highScore seed:(uint32_t)seed {
    if ((self = [super init])) {
        _table = table;
        _world = [[PBPhysicsWorld alloc] initWithTable:table seed:seed ^ (0x2545F491u ^ 0x9E3779B9u)];
        _rules = [[PBRuleEngine alloc] initWithWorld:_world highScore:highScore];
        _rules.delegate = self;
        _observers = [NSHashTable weakObjectsHashTable];
        _autoSeed = seed ?: 0x2545F491u;
    }
    return self;
}

- (void)addObserver:(id<PBGameObserver>)observer { [_observers addObject:observer]; }
- (void)removeObserver:(id<PBGameObserver>)observer { [_observers removeObject:observer]; }

- (void)setLeftPressed:(BOOL)pressed { atomic_store(&_leftInput, pressed); }
- (void)requestNewGame { atomic_store(&_newGameRequested, YES); }
- (void)setRightPressed:(BOOL)pressed { atomic_store(&_rightInput, pressed); }
- (void)setPlungerPressed:(BOOL)pressed { atomic_store(&_plungerInput, pressed); }
- (void)requestNudgeX:(float)x y:(float)y {
    atomic_store(&_nudgeX, x);
    atomic_store(&_nudgeY, y);
}

- (void)update:(double)elapsed {
    _clock += elapsed;
    [self applyInput];
    [_world advanceBy:elapsed];
    [_world drainEvents:^(const PBEvent *event) {
        [self->_rules handleEvent:event];
        for (id<PBGameObserver> observer in self->_observers) [observer game:self didReceiveEvent:event];
    }];
    [_rules update:elapsed];
}

- (void)applyInput {
    BOOL left = atomic_load(&_leftInput);
    BOOL right = atomic_load(&_rightInput);
    BOOL plunger = atomic_load(&_plungerInput);
    if (_autopilot) [self runAutopilotLeft:&left right:&right plunger:&plunger];

    BOOL leftEdge = left && !_leftApplied;
    BOOL rightEdge = right && !_rightApplied;

    if (atomic_exchange(&_newGameRequested, NO) ||
        (_rules.phase == PBGamePhaseAttract && (leftEdge || rightEdge || (plunger && !_charging)))) {
        _charging = NO;
        [_rules startGame];
    } else {
        // On a phone there is no plunger key, so a fresh right-hand press charges it
        // whenever a ball is waiting in the lane.
        if (rightEdge && _world.isBallOnPlunger) _charging = YES;
        if (plunger && _world.isBallOnPlunger) _charging = YES;
        BOOL holding = (right || plunger) && _charging;
        if (_charging) {
            [_world setPlungerPulled:holding];
            if (!holding) _charging = NO;
        }
    }

    if (left != _leftApplied) {
        [_world setFlipperGroupLeft:YES pressed:left];
        if (left) [_rules flipperPressedLeft:YES];
        _leftApplied = left;
    }
    if (right != _rightApplied) {
        [_world setFlipperGroupLeft:NO pressed:right];
        if (right) [_rules flipperPressedLeft:NO];
        _rightApplied = right;
    }

    float nudgeX = atomic_exchange(&_nudgeX, 0.0f);
    float nudgeY = atomic_exchange(&_nudgeY, 0.0f);
    if (nudgeX != 0.0f || nudgeY != 0.0f) {
        simd_float2 impulse = simd_make_float2(nudgeX, nudgeY);
        [_world nudge:impulse];
        [_rules nudged];
        _lastNudge = impulse;
    } else {
        _lastNudge *= 0.8f;
    }
}

#pragma mark - Autopilot

- (float)autoRandom {
    _autoSeed ^= _autoSeed << 13; _autoSeed ^= _autoSeed >> 17; _autoSeed ^= _autoSeed << 5;
    return (float)(_autoSeed & 0xFFFF) / 65535.0f;
}

/// A decent but imperfect player, varied so it explores the table: used to prove
/// in tests that every shot is reachable and that no layout flaw traps the ball.
- (void)runAutopilotLeft:(BOOL *)left right:(BOOL *)right plunger:(BOOL *)plunger {
    if (_rules.phase == PBGamePhaseAttract) { *right = fmod(_clock, 1.0) < 0.5; return; }

    const PBBall *balls = _world.balls;
    NSArray<PBFlipperDef *> *flippers = _table.flippers;
    for (NSInteger i = 0; i < _world.ballCapacity; i++) {
        const PBBall *ball = &balls[i];
        if (ball->state != PBBallFree || ball->captive || ball->ramp >= 0 || ball->velocity.y > 0.6f) continue;
        for (NSUInteger f = 0; f < flippers.count; f++) {
            PBFlipperDef *flipper = flippers[f];
            float angle = flipper.restAngle;
            simd_float2 mid = flipper.pivot + simd_make_float2(cosf(angle), sinf(angle)) * flipper.length * (0.45f + 0.35f * [self autoRandom]);
            if (simd_distance(ball->position, mid) < 0.052f + 0.02f * [self autoRandom]) {
                double hold = 0.12 + 0.12 * [self autoRandom];
                if (flipper.isLeft) _autoLeftUntil = _clock + hold;
                else _autoRightUntil = _clock + hold;
            }
        }
    }
    *left = _clock < _autoLeftUntil;
    *right = _clock < _autoRightUntil;

    if (_world.isBallOnPlunger && _autoPlungeUntil < _clock - 0.3) _autoPlungeUntil = _clock + 0.3 + 0.7 * [self autoRandom];
    *plunger = _clock < _autoPlungeUntil;
}

#pragma mark - PBRuleEngineDelegate

- (void)ruleEngine:(PBRuleEngine *)engine flash:(NSString *)flasherIdentifier {
    for (id<PBGameObserver> observer in _observers) [observer game:self flash:flasherIdentifier];
}

- (void)ruleEngine:(PBRuleEngine *)engine fanfare:(NSString *)name {
    for (id<PBGameObserver> observer in _observers) [observer game:self fanfare:name];
}

@end

