//
//  PBPhysicsWorld.h
//  Hand-written 2.5D pinball physics at a fixed 960 Hz.
//
//  SCNPhysicsWorld is deliberately not used: a generic rigid-body step at 60 Hz
//  tunnels through flippers, and pinball feel depends on exact control of bounce
//  and kick. At this rate a ball moves under a third of its radius per step, so
//  plain overlap tests are enough even at the speed clamp.
//

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#import "PBTableDefinition.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PBEventKind) {
    PBEventBumper,
    PBEventSling,
    PBEventDropTarget,
    PBEventStandup,
    PBEventRollover,
    PBEventSpinner,
    PBEventSaucerCapture,
    PBEventSaucerEject,
    PBEventRampEnter,
    PBEventRampComplete,
    PBEventKickback,
    PBEventMagnetGrab,
    PBEventDrain,
    PBEventFlipperUp,
    PBEventFlipperDown,
    PBEventWallHit,
    PBEventPlungerRelease,
    PBEventGate,
    PBEventBallStuck,
    PBEventPlungerCoil,  // One turn of the spring as it is drawn; magnitude is the pull so far.
    PBEventFlipperContact,
    PBEventRampRollback,
    PBEventMagnetRelease,
};

typedef struct {
    PBEventKind kind;
    int16_t element;     // Index into the array for that kind on PBTableDefinition.
    int16_t ball;
    float magnitude;     // Impact speed; plunger release uses applied pull (0...1).
    simd_float2 position;
    uint64_t tick;       // Fixed physics tick, including events emitted outside stepping.
} PBEvent;

FOUNDATION_EXPORT NSString *PBEventName(PBEventKind kind);
FOUNDATION_EXPORT NSString *PBEventElementIdentifier(PBEvent event, PBTableDefinition *table);

typedef NS_ENUM(uint8_t, PBBallState) {
    PBBallInactive,
    PBBallFree,
    PBBallInSaucer,
    PBBallHeldByMagnet,
    PBBallInTransit,  // Underground, between a drop hole and where it comes up.
};

typedef struct {
    simd_float2 position;
    simd_float2 velocity;
    float z;              // Height of the ball's centre above the playfield.
    float zVelocity;
    simd_quatf orientation;  // Visual rolling only.
    float stuckTime;
    int stuckCount;
    simd_float2 stuckAnchor;
    float holdTimer;
    int16_t holder;       // Saucer or magnet index while held.
    int16_t ramp;         // Ramp index while on one, otherwise -1.
    float rampDistance;
    PBLayerMask layers;
    PBBallState state;
    BOOL captive;
    float saucerCooldown;
} PBBall;

@interface PBPhysicsWorld : NSObject

@property (nonatomic, readonly) PBTableDefinition *table;
@property (nonatomic, readonly) NSInteger ballCapacity;
@property (nonatomic, readonly) float plungerPull;  // 0...1, for drawing.

- (instancetype)initWithTable:(PBTableDefinition *)table;
- (instancetype)initWithTable:(PBTableDefinition *)table seed:(uint32_t)seed;
@property (nonatomic, readonly) uint64_t tick;
/// Disable rescue in strict design trials; PBEventBallStuck still reports the defect.
@property (nonatomic) BOOL automaticBallSearch;
/// One exact production physics step, for headless fixtures; drain events after each step.
- (void)advanceOneTick;

/// Advances by real elapsed time, running as many fixed steps as fit. Long hitches are clamped.
- (void)advanceBy:(double)elapsed;

/// Hands queued events to the block and clears the queue.
- (void)drainEvents:(void (NS_NOESCAPE ^)(const PBEvent *event))handler;

#pragma mark Balls
- (const PBBall *)balls;
/// Number of live non-captive balls.
- (NSInteger)activeBallCount;
- (NSInteger)spawnBallAtPlunger;
- (BOOL)isBallOnPlunger;
- (void)removeAllPlayBalls;
- (void)removeBall:(NSInteger)index;
- (void)placeBall:(NSInteger)index at:(simd_float2)position velocity:(simd_float2)velocity;

#pragma mark Controls
- (void)setFlipperGroupLeft:(BOOL)left pressed:(BOOL)pressed;
- (void)setPlungerPulled:(BOOL)pulled;
- (void)autoPlunge;
- (void)nudge:(simd_float2)impulse;
- (void)setFlippersEnabled:(BOOL)enabled;

#pragma mark Actuators (driven by the rules)
- (void)setDropTarget:(NSInteger)index up:(BOOL)up;
- (BOOL)isDropTargetUp:(NSInteger)index;
- (void)ejectSaucer:(NSInteger)index;
- (void)setKickback:(NSInteger)index armed:(BOOL)armed;
- (void)setMagnet:(NSInteger)index armed:(BOOL)armed;

#pragma mark State for drawing
- (float)flipperAngle:(NSInteger)index;
- (float)spinnerAngle:(NSInteger)index;
- (float)gateAngle:(NSInteger)index;
- (float)dropTargetDrop:(NSInteger)index;
/// Seconds since a bumper, sling or stand-up last fired, for animation.
- (float)bumperFlash:(NSInteger)index;
- (float)slingFlash:(NSInteger)index;
- (void)setStopper:(NSInteger)index up:(BOOL)up;
- (BOOL)isStopperUp:(NSInteger)index;
- (float)standupFlash:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END

