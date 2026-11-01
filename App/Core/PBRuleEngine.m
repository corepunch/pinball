//
//  PBRuleEngine.m
//

#import "PBRuleEngine.h"

static const double kMessageSeconds = 1.8;
static const double kBonusSeconds = 2.2;
static const double kSaucerHoldSeconds = 1.1;
static const double kTiltDecaySeconds = 3.0;
static const double kBallAddDelay = 0.8;

@interface PBPendingAction : NSObject
@property (nonatomic) double remaining;
@property (nonatomic, copy) void (^block)(void);
@end
@implementation PBPendingAction @end

@interface PBGroupState : NSObject
@property (nonatomic, strong) PBRuleGroupDef *def;
@property (nonatomic, strong) NSMutableSet<NSString *> *lit;
@end
@implementation PBGroupState @end

@implementation PBRuleEngine {
    PBPhysicsWorld *_world;
    PBTableDefinition *_table;
    PBRulesDef *_rules;
    NSArray<PBGroupState *> *_groups;
    NSMutableDictionary<NSString *, PBGroupState *> *_groupByMember;
    NSMutableDictionary<NSString *, NSNumber *> *_lampIndex;
    PBLampMode *_lampModes;
    NSMutableArray<PBPendingAction *> *_pending;

    NSInteger _extraBalls;
    NSInteger _ballsPending;
    int64_t _bonus;
    int64_t _bonusAwarded;
    double _bonusTimer;
    double _ballSaveTimer;
    double _skillTimer;
    BOOL _ballInPlayCounted;
    BOOL _plunged;

    NSInteger _locks;
    BOOL _lockLit;
    BOOL _jackpotLit;
    NSInteger _rampCount;
    NSInteger _ringLit;
    BOOL _extraBallLit;
    BOOL _specialLit;
    BOOL _kickbackArmed;
    BOOL _magnetArmed;
    BOOL _orbitHot;
    BOOL _shootAgain;

    NSInteger _tiltWarnings;
    double _tiltDecay;

    NSString *_message;
    double _messageTimer;
    double _attractClock;
}

- (instancetype)initWithWorld:(PBPhysicsWorld *)world highScore:(int64_t)highScore {
    if ((self = [super init])) {
        _world = world;
        _table = world.table;
        _rules = _table.rules;
        _highScore = highScore;
        _phase = PBGamePhaseAttract;
        _bonusMultiplier = 1;
        _pending = [NSMutableArray array];
        _displayTop = _table.name;
        _displayBottom = @"PRESS START";

        NSMutableArray *groups = [NSMutableArray array];
        _groupByMember = [NSMutableDictionary dictionary];
        for (PBRuleGroupDef *def in _rules.groups) {
            PBGroupState *state = [PBGroupState new];
            state.def = def;
            state.lit = [NSMutableSet set];
            [groups addObject:state];
            for (NSString *member in def.members) _groupByMember[member] = state;
        }
        _groups = groups;

        _lampIndex = [NSMutableDictionary dictionary];
        [_table.lamps enumerateObjectsUsingBlock:^(PBLampDef *lamp, NSUInteger i, BOOL *stop) {
            self->_lampIndex[lamp.identifier] = @(i);
        }];
        _lampModes = calloc(MAX(_table.lamps.count, 1u), sizeof(PBLampMode));
    }
    return self;
}

- (void)dealloc { free(_lampModes); }

- (PBLampMode)modeForLamp:(NSInteger)lampIndex { return _lampModes[lampIndex]; }

#pragma mark - Game flow

- (void)startGame {
    _score = 0;
    _ballNumber = 0;
    _extraBalls = 0;
    _locks = 0;
    _rampCount = 0;
    _ringLit = 0;
    _lockLit = NO;
    _extraBallLit = NO;
    _specialLit = NO;
    _kickbackArmed = NO;
    _magnetArmed = NO;
    _multiballActive = NO;
    _jackpotLit = NO;
    _shootAgain = NO;
    _ballsPending = 0;
    [_pending removeAllObjects];
    [_world removeAllPlayBalls];
    [self.delegate ruleEngine:self fanfare:@"start"];
    [self startNextBall];
}

- (void)startNextBall {
    _phase = PBGamePhasePlaying;
    _ballNumber += 1;
    [self beginBall];
}

- (void)beginBall {
    _bonus = 0;
    _bonusMultiplier = 1;
    _tilted = NO;
    _tiltWarnings = 0;
    _tiltDecay = 0;
    _plunged = NO;
    _skillTimer = 0;
    _ballSaveTimer = 0;
    _orbitHot = NO;
    [_world setFlippersEnabled:YES];
    for (PBGroupState *group in _groups) [group.lit removeAllObjects];
    for (NSUInteger i = 0; i < _table.dropTargets.count; i++) [_world setDropTarget:(NSInteger)i up:YES];
    [self armKickbacks:_kickbackArmed];
    [_world spawnBallAtPlunger];
    // The skill-shot lane is lit, and the plunger lane lamp shows it.
    _skillTimer = _rules.skillShotSeconds;
}

- (void)endGame {
    _phase = PBGamePhaseGameOver;
    if (_score > _highScore) {
        _highScore = _score;
        [self showMessage:@"NEW HIGH SCORE"];
    } else {
        [self showMessage:@"GAME OVER"];
    }
    [self.delegate ruleEngine:self fanfare:@"gameOver"];
    [self after:3.5 do:^{ self->_phase = PBGamePhaseAttract; self->_attractClock = 0; }];
}

- (void)endBall {
    _phase = PBGamePhaseBonus;
    _multiballActive = NO;
    _bonusAwarded = _tilted ? 0 : _bonus * _bonusMultiplier;
    _bonusTimer = kBonusSeconds;
    [_world setFlippersEnabled:NO];
    [self showMessage:_tilted ? @"TILT" : [NSString stringWithFormat:@"BONUS %@", [self.class formattedScore:_bonusAwarded]]];
}

- (void)finishBonus {
    [self addScore:_bonusAwarded];
    _bonusAwarded = 0;
    if (_extraBalls > 0) {
        _extraBalls -= 1;
        _shootAgain = _extraBalls > 0;
        _phase = PBGamePhasePlaying;
        [self showMessage:@"SHOOT AGAIN"];
        [self beginBall];
    } else if (_ballNumber >= _rules.balls) {
        [self endGame];
    } else {
        [self startNextBall];
    }
}

#pragma mark - Scoring helpers

- (void)addScore:(int64_t)points {
    if (_tilted || _phase == PBGamePhaseAttract || _phase == PBGamePhaseGameOver) return;
    _score += points;
}

- (void)award:(NSString *)key {
    [self addScore:[_rules scoreFor:key]];
}

- (void)showMessage:(NSString *)message {
    _message = message;
    _messageTimer = kMessageSeconds;
}

- (void)after:(double)seconds do:(void (^)(void))block {
    PBPendingAction *action = [PBPendingAction new];
    action.remaining = seconds;
    action.block = block;
    [_pending addObject:action];
}

+ (NSString *)formattedScore:(int64_t)score {
    NSMutableString *digits = [NSMutableString stringWithFormat:@"%lld", score];
    for (NSInteger i = (NSInteger)digits.length - 3; i > 0; i -= 3) [digits insertString:@"," atIndex:(NSUInteger)i];
    return digits;
}

#pragma mark - Events

- (void)handleEvent:(const PBEvent *)event {
    if (_phase == PBGamePhaseAttract || _phase == PBGamePhaseGameOver) {
        if (event->kind == PBEventDrain) [_world removeBall:event->ball];
        if (event->kind == PBEventSaucerCapture) [_world ejectSaucer:event->element];
        return;
    }
    switch (event->kind) {
        case PBEventBumper:
            [self award:@"bumper"];
            _bonus += 1;
            _ringLit = (_ringLit + 1) % 13;
            break;
        case PBEventSling:
            [self award:@"sling"];
            break;
        case PBEventDropTarget: {
            NSString *identifier = _table.dropTargets[(NSUInteger)event->element].identifier;
            [self award:@"drop"];
            [self litMember:identifier];
            break;
        }
        case PBEventStandup: {
            NSString *identifier = _table.standups[(NSUInteger)event->element].identifier;
            if (_groupByMember[identifier]) {
                [self award:@"standup"];
                [self litMember:identifier];
            } else {
                [self award:@"captive"];
                [self showMessage:@"CAPTIVE HIT"];
                [self relightJackpot];
            }
            break;
        }
        case PBEventRollover:
            [self handleRollover:_table.rollovers[(NSUInteger)event->element].identifier];
            break;
        case PBEventSpinner:
            [self award:@"spinner"];
            break;
        case PBEventSaucerCapture:
            [self handleSaucer:event->element];
            break;
        case PBEventRampComplete:
            [self handleRampComplete];
            break;
        case PBEventKickback:
            [self award:@"kickback"];
            _kickbackArmed = NO;
            [self showMessage:@"KICKBACK"];
            break;
        case PBEventMagnetGrab:
            _magnetArmed = NO;
            [self showMessage:@"MAGNET"];
            break;
        case PBEventDrain:
            [self handleDrain];
            break;
        case PBEventPlungerRelease:
            if (!_plunged && event->magnitude > 0.05f) {
                _plunged = YES;
                _ballSaveTimer = _rules.ballSaveSeconds;
            }
            break;
        default:
            break;
    }
}

- (void)handleRollover:(NSString *)identifier {
    // Roles come from id prefixes: orbit*, outlane*, inlane*. Anything else is a plain rollover.
    if ([identifier hasPrefix:@"orbit"]) {
        [self award:@"orbit"];
        if (_orbitHot) {
            [self addScore:[_rules scoreFor:@"orbit"] * 3];
            [self showMessage:@"ORBIT"];
        }
        _orbitHot = !_orbitHot;
        [self relightJackpot];
        return;
    }
    if ([identifier hasPrefix:@"outlane"]) {
        [self award:@"outlane"];
        if (_specialLit && [identifier hasSuffix:@"Right"]) {
            _specialLit = NO;
            [self award:@"special"];
            [self showMessage:@"SPECIAL"];
        }
        return;
    }
    if ([identifier hasPrefix:@"inlane"]) {
        [self award:@"inlane"];
        [self litMember:identifier];
        return;
    }
    [self award:@"rollover"];
    if (_skillTimer > 0 && [identifier isEqualToString:_rules.skillShotTarget]) {
        _skillTimer = 0;
        [self award:@"skillShot"];
        [self showMessage:@"SKILL SHOT"];
        [self.delegate ruleEngine:self fanfare:@"jackpot"];
    }
    [self litMember:identifier];
}

- (void)litMember:(NSString *)member {
    PBGroupState *group = _groupByMember[member];
    if (!group) return;
    [group.lit addObject:member];
    if (group.lit.count < group.def.members.count) return;

    [self addScore:group.def.completeScore];
    if (group.def.message.length) [self showMessage:group.def.message];
    for (NSString *action in group.def.actions) [self perform:action group:group];
}

- (void)perform:(NSString *)action group:(PBGroupState *)group {
    if ([action isEqualToString:@"bonusX"]) {
        _bonusMultiplier = _bonusMultiplier >= 5 ? 5 : (_bonusMultiplier == 3 ? 5 : _bonusMultiplier + 1);
    } else if ([action isEqualToString:@"resetGroup"]) {
        [group.lit removeAllObjects];
    } else if ([action isEqualToString:@"lightLock"]) {
        _lockLit = YES;
        _specialLit = YES;
    } else if ([action isEqualToString:@"resetDrops"]) {
        [group.lit removeAllObjects];
        [self after:0.9 do:^{
            for (NSUInteger i = 0; i < self->_table.dropTargets.count; i++) [self->_world setDropTarget:(NSInteger)i up:YES];
        }];
    } else if ([action isEqualToString:@"armKickback"]) {
        _kickbackArmed = YES;
        [self armKickbacks:YES];
    } else if ([action isEqualToString:@"armMagnet"]) {
        _magnetArmed = YES;
        for (NSUInteger i = 0; i < _table.magnets.count; i++) [_world setMagnet:(NSInteger)i armed:YES];
    } else if ([action isEqualToString:@"addBonus"]) {
        _bonus += 5;
    } else if ([action hasPrefix:@"flash:"]) {
        [self.delegate ruleEngine:self flash:[action substringFromIndex:6]];
    }
}

- (void)armKickbacks:(BOOL)armed {
    for (NSUInteger i = 0; i < _table.kickbacks.count; i++) [_world setKickback:(NSInteger)i armed:armed];
}

- (void)handleSaucer:(NSInteger)saucer {
    [self award:@"saucer"];
    NSTimeInterval hold = kSaucerHoldSeconds;
    if (_lockLit && !_multiballActive) {
        _lockLit = NO;
        _locks += 1;
        if (_locks >= _rules.locksForMultiball) {
            [self startMultiball];
            hold = 2.0;
        } else {
            [self showMessage:[NSString stringWithFormat:@"BALL %ld LOCKED", (long)_locks]];
            [self.delegate ruleEngine:self flash:@"flashTL"];
        }
    }
    [self after:hold do:^{ [self->_world ejectSaucer:saucer]; }];
}

- (void)startMultiball {
    _multiballActive = YES;
    _jackpotLit = YES;
    _locks = 0;
    _ballSaveTimer = MAX(_ballSaveTimer, 12.0);
    [self showMessage:@"MULTIBALL"];
    [self.delegate ruleEngine:self fanfare:@"multiball"];
    for (NSInteger i = 1; i < _rules.multiballBalls; i++) [self addBallAfter:kBallAddDelay * (double)i];
}

- (void)addBallAfter:(double)delay {
    _ballsPending += 1;
    [self after:delay do:^{
        self->_ballsPending -= 1;
        if (self->_phase != PBGamePhasePlaying) return;
        [self->_world spawnBallAtPlunger];
        [self after:0.45 do:^{ [self->_world autoPlunge]; }];
    }];
}

- (void)relightJackpot {
    if (_multiballActive) _jackpotLit = YES;
}

- (void)handleRampComplete {
    [self award:@"ramp"];
    _bonus += 3;
    if (_multiballActive && _jackpotLit) {
        _jackpotLit = NO;
        [self award:@"jackpot"];
        [self showMessage:@"JACKPOT"];
        [self.delegate ruleEngine:self fanfare:@"jackpot"];
        [self.delegate ruleEngine:self flash:@"flashTL"];
        [self.delegate ruleEngine:self flash:@"flashTR"];
        return;
    }
    [self showMessage:@"RAMP"];
    [self.delegate ruleEngine:self flash:@"flashTR"];
    _rampCount += 1;
    if (_rampCount >= _rules.rampsForExtraBall) {
        _rampCount = 0;
        _extraBalls += 1;
        _shootAgain = YES;
        [self showMessage:@"EXTRA BALL"];
        [self.delegate ruleEngine:self fanfare:@"extraBall"];
    }
}

- (void)handleDrain {
    if (_phase != PBGamePhasePlaying) return;
    if (_ballSaveTimer > 0 && !_tilted) {
        [self showMessage:@"BALL SAVED"];
        [self.delegate ruleEngine:self fanfare:@"ballSave"];
        [self addBallAfter:0.5];
        return;
    }
    NSInteger remaining = _world.activeBallCount;
    if (_multiballActive && remaining + _ballsPending <= 1) {
        _multiballActive = NO;
        _jackpotLit = NO;
    }
    if (remaining == 0 && _ballsPending == 0) [self endBall];
}

- (void)nudged {
    if (_phase != PBGamePhasePlaying || _tilted) return;
    _tiltDecay = kTiltDecaySeconds;
    _tiltWarnings += 1;
    if (_tiltWarnings > _rules.tiltWarnings) {
        _tilted = YES;
        _ballSaveTimer = 0;
        [_world setFlippersEnabled:NO];
        [self showMessage:@"TILT"];
        [self.delegate ruleEngine:self fanfare:@"tilt"];
    } else {
        [self showMessage:@"DANGER"];
    }
}

- (void)flipperPressedLeft:(BOOL)left {
    for (PBGroupState *group in _groups) {
        if (!group.def.rotateWithFlippers || group.lit.count == 0) continue;
        NSArray<NSString *> *members = group.def.members;
        NSInteger count = (NSInteger)members.count;
        NSMutableSet *rotated = [NSMutableSet set];
        for (NSInteger i = 0; i < count; i++) {
            if ([group.lit containsObject:members[(NSUInteger)i]]) {
                NSInteger next = (i + (left ? -1 : 1) + count) % count;
                [rotated addObject:members[(NSUInteger)next]];
            }
        }
        group.lit = rotated;
    }
}

#pragma mark - Time

- (void)update:(double)dt {
    _attractClock += dt;
    if (_ballSaveTimer > 0 && _plunged) _ballSaveTimer -= dt;
    if (_skillTimer > 0 && _plunged) _skillTimer -= dt;
    if (_tiltDecay > 0) {
        _tiltDecay -= dt;
        if (_tiltDecay <= 0 && !_tilted) _tiltWarnings = 0;
    }
    if (_messageTimer > 0) _messageTimer -= dt;

    if (_phase == PBGamePhaseBonus) {
        _bonusTimer -= dt;
        if (_bonusTimer <= 0) [self finishBonus];
    }

    if (_pending.count) {
        NSArray<PBPendingAction *> *snapshot = [_pending copy];
        for (PBPendingAction *action in snapshot) {
            action.remaining -= dt;
            if (action.remaining <= 0) {
                [_pending removeObject:action];
                action.block();
            }
        }
    }

    [self refreshLamps];
    [self refreshDisplay];
}

- (void)refreshDisplay {
    _displayIsMessage = _messageTimer > 0 && _message != nil;
    if (_displayIsMessage) {
        _displayTop = _message;
        _displayBottom = @"";
        return;
    }
    switch (_phase) {
        case PBGamePhaseAttract: {
            NSInteger slide = ((NSInteger)(_attractClock / 2.5)) % 3;
            if (slide == 0) { _displayTop = _table.name; _displayBottom = @"PRESS START"; }
            else if (slide == 1) { _displayTop = @"HIGH SCORE"; _displayBottom = [self.class formattedScore:_highScore]; }
            else { _displayTop = @"LAST GAME"; _displayBottom = [self.class formattedScore:_score]; }
            break;
        }
        case PBGamePhaseGameOver:
            _displayTop = @"GAME OVER";
            _displayBottom = [self.class formattedScore:_score];
            break;
        default:
            _displayTop = [self.class formattedScore:_score];
            _displayBottom = _multiballActive
                ? @"MULTIBALL"
                : [NSString stringWithFormat:@"BALL %ld   X%ld", (long)_ballNumber, (long)_bonusMultiplier];
            break;
    }
}

- (void)refreshLamps {
    NSArray<PBLampDef *> *lamps = _table.lamps;
    for (NSUInteger i = 0; i < lamps.count; i++) {
        NSString *bind = lamps[i].bind;
        _lampModes[i] = bind ? [self modeForBinding:bind] : PBLampOff;
    }
    for (PBGroupState *group in _groups) {
        NSArray *members = group.def.members;
        for (NSUInteger m = 0; m < members.count && m < group.def.lamps.count; m++) {
            NSInteger lampIndex = _lampIndex[group.def.lamps[m]].integerValue;
            BOOL lit = [group.lit containsObject:members[m]];
            BOOL skill = _skillTimer > 0 && [members[m] isEqualToString:_rules.skillShotTarget];
            _lampModes[lampIndex] = skill ? PBLampFastBlink : (lit ? PBLampOn : PBLampOff);
        }
    }
}

- (PBLampMode)modeForBinding:(NSString *)bind {
    // ring1...ringN: a progress dial that fills with bumper hits, then starts again.
    if ([bind hasPrefix:@"ring"]) return _ringLit >= [bind substringFromIndex:4].integerValue ? PBLampOn : PBLampOff;
    static NSDictionary<NSString *, NSNumber *> *bindings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bindings = @{ @"shootAgain": @0, @"bonusX2": @1, @"bonusX3": @2, @"bonusX5": @3, @"jackpot": @4,
                      @"magnet": @5, @"lockLit": @6, @"lock1": @7, @"lock2": @8, @"rampHot": @9,
                      @"ramp1": @10, @"ramp2": @11, @"ramp3": @12, @"extraBall": @13, @"orbitHot": @14,
                      @"captiveHot": @15, @"kickback": @16, @"special": @17, @"skillShot": @18 };
    });
    switch (bindings[bind].integerValue) {
        case 0: return _ballSaveTimer > 0 ? PBLampFastBlink : (_shootAgain ? PBLampOn : PBLampOff);
        case 1: return _bonusMultiplier >= 2 ? PBLampOn : PBLampOff;
        case 2: return _bonusMultiplier >= 3 ? PBLampOn : PBLampOff;
        case 3: return _bonusMultiplier >= 5 ? PBLampOn : PBLampOff;
        case 4: return _jackpotLit ? PBLampFastBlink : PBLampOff;
        case 5: return _magnetArmed ? PBLampBlink : PBLampOff;
        case 6: return _lockLit ? PBLampBlink : PBLampOff;
        case 7: return _locks >= 1 ? PBLampOn : PBLampOff;
        case 8: return _locks >= 2 ? PBLampOn : PBLampOff;
        case 9: return _multiballActive && _jackpotLit ? PBLampFastBlink : PBLampBlink;
        case 10: return _rampCount >= 1 ? PBLampOn : PBLampOff;
        case 11: return _rampCount >= 2 ? PBLampOn : PBLampOff;
        case 12: return _rampCount >= 3 ? PBLampOn : PBLampOff;
        case 13: return _rampCount + 1 >= _rules.rampsForExtraBall ? PBLampBlink : (_extraBalls > 0 ? PBLampOn : PBLampOff);
        case 14: return _orbitHot ? PBLampBlink : PBLampOff;
        case 15: return _multiballActive && !_jackpotLit ? PBLampBlink : PBLampOff;
        case 16: return _kickbackArmed ? PBLampOn : PBLampOff;
        case 17: return _specialLit ? PBLampBlink : PBLampOff;
        case 18: return (_skillTimer > 0 && !_plunged) ? PBLampFastBlink : PBLampOff;
    }
    return PBLampOff;
}

@end
