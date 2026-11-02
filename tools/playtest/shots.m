// Fires a fan of real flipper shots at one table, and reports what each one reaches and where it ends up.
// shots <table.json>; see run_shots.py.
#import <Foundation/Foundation.h>
#import "PBPhysicsWorld.h"

static const int kContacts = 40;
static const float kRolls[] = { 0.0f, 0.5f, 1.0f, 1.5f };

@interface PBShotOutcome : NSObject
@property (nonatomic, copy) NSString *reached, *ended;
@property (nonatomic) float heading, speed;  // As the ball leaves the lower board.
@property (nonatomic) simd_float2 leaving, firstBounce;
@end
@implementation PBShotOutcome @end

static PBShotOutcome *PBFire(PBTableDefinition *table, PBFlipperDef *flipper, float contact, float roll) {
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger ball = [world spawnBallAtPlunger];
    float angle = flipper.restAngle;
    simd_float2 along = simd_make_float2(cosf(angle), sinf(angle));
    // Above the flipper, whichever way it points.
    simd_float2 normal = simd_make_float2(-along.y, along.x);
    if (normal.y < 0.0f) normal = -normal;
    float radius = flipper.baseRadius + (flipper.tipRadius - flipper.baseRadius) * contact;
    simd_float2 at = flipper.pivot + along * flipper.length * contact + normal * (radius + table.ballRadius + 0.002f);
    [world placeBall:ball at:at velocity:along * roll];
    [world setFlipperGroupLeft:flipper.isLeft pressed:YES];

    PBShotOutcome *outcome = [PBShotOutcome new];
    __block NSString *reached = nil, *ended = nil;
    __block BOOL leftOrbit = NO, rightOrbit = NO;
    for (int frame = 0; frame < 60 * 8 && !ended; frame++) {
        if (frame == 15) [world setFlipperGroupLeft:flipper.isLeft pressed:NO];
        [world advanceBy:1.0 / 60.0];
        [world drainEvents:^(const PBEvent *event) {
            NSString *first = nil;
            if (event->kind == PBEventWallHit && event->position.y > 0.6f && outcome.firstBounce.y == 0.0f) outcome.firstBounce = event->position;
            switch (event->kind) {
                case PBEventRampComplete: first = [@"ramp " stringByAppendingString:table.ramps[(NSUInteger)event->element].identifier]; break;
                case PBEventSaucerCapture: first = [@"hole " stringByAppendingString:table.saucers[(NSUInteger)event->element].identifier]; break;
                case PBEventBumper: first = @"bumpers"; break;
                case PBEventDropTarget: first = @"drops"; break;
                case PBEventStandup: first = @"standups"; break;
                case PBEventDrain: ended = @"drain"; break;
                default: break;
            }
            if (first && !reached) reached = first;
        }];
        const PBBall *b = &world.balls[ball];
        if (b->state != PBBallFree) continue;
        if (outcome.speed == 0.0f && b->position.y > 0.6f && b->velocity.y > 0.0f) {
            outcome.speed = simd_length(b->velocity);
            outcome.heading = atan2f(b->velocity.y, b->velocity.x) * 180.0f / (float)M_PI;
            outcome.leaving = b->position;
        }
        // An orbit counts once the ball has run up the side and come over the top.
        if (b->ramp < 0 && b->velocity.y > 0.0f && b->position.x < 0.09f && b->position.y > 1.45f) leftOrbit = YES;
        if (b->ramp < 0 && b->velocity.y > 0.0f && b->position.x > 0.84f && b->position.x < 0.92f && b->position.y > 1.45f) rightOrbit = YES;
        if (b->position.y > 2.1f && !reached) {
            if (leftOrbit) reached = @"orbit left";
            else if (rightOrbit) reached = @"orbit right";
        }
        if (frame > 40 && b->position.y < 0.3f && b->velocity.y < 0.0f && !ended && b->ramp < 0) {
            float middle = 0.461f;
            if (b->position.x < 0.09f || b->position.x > 0.83f) ended = @"outlane";
            else if (fabsf(b->position.x - middle) < 0.05f) ended = @"gap";
            else ended = b->position.x < middle ? @"left flipper" : @"right flipper";
        }
    }
    outcome.reached = reached ?: @"nothing";
    outcome.ended = ended ?: @"still playing";
    return outcome;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSError *error;
        PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSData dataWithContentsOfFile:@(argv[1])] error:&error];
        if (!table) { fprintf(stderr, "%s\n", error.description.UTF8String); return 2; }
        NSMutableDictionary *report = [NSMutableDictionary dictionary];
        for (PBFlipperDef *flipper in table.flippers) {
            if (flipper.layers != PBLayerPlayfield || flipper.pivot.y > 0.5f) continue;
            NSCountedSet *reached = [NSCountedSet set], *ended = [NSCountedSet set];
            NSMutableArray *fan = [NSMutableArray array];
            for (int i = 0; i < kContacts; i++) {
                float contact = 0.2f + 0.8f * i / (kContacts - 1);
                for (size_t r = 0; r < sizeof(kRolls) / sizeof(*kRolls); r++) {
                    PBShotOutcome *shot = PBFire(table, flipper, contact, kRolls[r]);
                    [reached addObject:shot.reached];
                    [ended addObject:shot.ended];
                    [fan addObject:@{ @"contact": @(contact), @"roll": @(kRolls[r]), @"reached": shot.reached, @"ended": shot.ended,
                                      @"heading": @(shot.heading), @"speed": @(shot.speed), @"x": @(shot.leaving.x),
                                      @"bounceX": @(shot.firstBounce.x), @"bounceY": @(shot.firstBounce.y) }];
                }
            }
            NSMutableDictionary *r = [NSMutableDictionary dictionary], *e = [NSMutableDictionary dictionary];
            for (NSString *key in reached) r[key] = @([reached countForObject:key]);
            for (NSString *key in ended) e[key] = @([ended countForObject:key]);
            report[flipper.identifier] = @{ @"shots": @(fan.count), @"reached": r, @"ended": e, @"fan": fan };
        }
        NSData *out = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:&error];
        printf("%s\n", [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding].UTF8String);
    }
    return 0;
}
