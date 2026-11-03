#import <XCTest/XCTest.h>
#import "PBSoftBall.h"
#import "PBPhysicsWorld.h"
#import "PBGame.h"

@interface PBSoftBallTests : XCTestCase
@end

@implementation PBSoftBallTests
- (void)assertRound:(PBSoftBall)ball {
    simd_float3x3 shape = PBSoftBallShape(ball);
    for (int i = 0; i < 3; i++) XCTAssertLessThan(simd_distance(shape.columns[i], matrix_identity_float3x3.columns[i]), 1e-5f);
}

- (void)testObliqueImpactCompressesAlongContactAndPreservesVolume {
    PBSoftBall ball = {0};
    simd_float3 normal = simd_normalize(simd_make_float3(1, 2, 0));
    simd_float3 tangent = simd_make_float3(-normal.y, normal.x, 0);
    PBSoftBallHit(&ball, normal, 4);
    simd_float3x3 shape = PBSoftBallShape(ball);
    XCTAssertLessThan(PBSoftBallSupport(shape, normal), .85f);
    XCTAssertGreaterThan(PBSoftBallSupport(shape, tangent), 1.08f);
    XCTAssertEqualWithAccuracy(simd_determinant(shape), 1, 2e-6);
    XCTAssertLessThan(fabsf(simd_dot(simd_mul(shape, normal), tangent)), 1e-6f);
}

- (void)testStrongerImpactDeformsMoreAndRestingContactsStayQuiet {
    PBSoftBall quiet = {0}, gentle = {0}, strong = {0};
    simd_float3 normal = simd_make_float3(1, 0, 0);
    for (int i = 0; i < 960; i++) {
        PBSoftBallHit(&quiet, normal, .02f);
        PBSoftBallAdvance(&quiet, 1.0f / 960);
    }
    [self assertRound:quiet];
    PBSoftBallHit(&gentle, normal, .5f);
    PBSoftBallHit(&strong, normal, 5);
    XCTAssertLessThan(PBSoftBallSupport(PBSoftBallShape(strong), normal), PBSoftBallSupport(PBSoftBallShape(gentle), normal));
}

- (void)testRecoveryOvershootsThenSettlesWithoutVolumePumping {
    PBSoftBall ball = {0};
    simd_float3 normal = simd_make_float3(0, 0, 1);
    PBSoftBallHit(&ball, normal, 4);
    BOOL stretched = NO;
    for (int i = 0; i < 960; i++) {
        PBSoftBallAdvance(&ball, 1.0f / 960);
        simd_float3x3 shape = PBSoftBallShape(ball);
        stretched |= PBSoftBallSupport(shape, normal) > 1.01f;
        XCTAssertEqualWithAccuracy(simd_determinant(shape), 1, 2e-6);
    }
    XCTAssertTrue(stretched, @"a rebound should have a short elastic overshoot");
    [self assertRound:ball];
}

- (void)testSpringRecoveryAgreesAtThirtySixtyAndOneTwentyHz {
    simd_float3x3 reference = matrix_identity_float3x3;
    for (int rate = 30; rate <= 120; rate *= 2) {
        PBSoftBall ball = {0};
        PBSoftBallHit(&ball, simd_make_float3(1, 1, 0), 2);
        for (int i = 0; i < rate / 10; i++) PBSoftBallAdvance(&ball, 1.0f / rate);
        simd_float3x3 shape = PBSoftBallShape(ball);
        if (rate == 30) reference = shape;
        else for (int i = 0; i < 3; i++) XCTAssertLessThan(simd_distance(shape.columns[i], reference.columns[i]), 2e-6f);
    }
}

- (void)testRapidCompoundHitsCannotCollapseOrExplodeTheBall {
    PBSoftBall ball = {0};
    for (int i = 0; i < 2000; i++) {
        simd_float3 normal = simd_normalize(simd_make_float3(cosf(i * .37f), sinf(i * .37f), .3f));
        PBSoftBallHit(&ball, normal, 12);
        PBSoftBallAdvance(&ball, 1.0f / 960);
        simd_float3x3 shape = PBSoftBallShape(ball);
        XCTAssertEqualWithAccuracy(simd_determinant(shape), 1, 3e-6);
        XCTAssertGreaterThan(PBSoftBallSupport(shape, normal), .65f);
        XCTAssertLessThan(PBSoftBallSupport(shape, normal), 1.4f);
    }
    PBSoftBallAdvance(&ball, 2);
    [self assertRound:ball];
}

- (void)testInvalidSamplesDoNotPoisonTheSpring {
    PBSoftBall ball = {0};
    PBSoftBallHit(&ball, simd_make_float3(NAN, 0, 0), 3);
    PBSoftBallHit(&ball, simd_make_float3(0, 0, 0), 3);
    PBSoftBallHit(&ball, simd_make_float3(1, 0, 0), NAN);
    PBSoftBallAdvance(&ball, NAN);
    [self assertRound:ball];
    PBSoftBallHit(&ball, simd_make_float3(1, 0, 0), 2);
    XCTAssertLessThan(PBSoftBallSupport(PBSoftBallShape(ball), simd_make_float3(1, 0, 0)), .9f);
}

- (NSMutableDictionary *)emptyTable {
    NSString *root = [@(__FILE__) stringByDeletingLastPathComponent];
    NSString *path = [root stringByAppendingPathComponent:@"../GameData/Tables/aurora.json"];
    NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:NSJSONReadingMutableContainers error:NULL];
    for (NSString *key in @[@"walls", @"posts", @"bumpers", @"slingshots", @"dropTargets", @"standups", @"rollovers", @"spinners", @"saucers", @"gates", @"kickbacks", @"magnets", @"captiveBalls", @"ramps"]) json[key] = @[];
    json[@"physics"][@"gravity"] = @0;
    return json;
}

- (PBPhysicsWorld *)world:(NSDictionary *)json {
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] error:NULL];
    return [[PBPhysicsWorld alloc] initWithTable:table];
}

- (void)testRealWallImpactDrivesShapeWithoutChangingBounceOrCollisionRadius {
    NSMutableDictionary *json = [self emptyTable];
    json[@"flippers"] = @[];
    json[@"walls"] = @[@{@"id":@"wall", @"style":@"wall", @"radius":@.006, @"height":@.08, @"points":@[@[@.5, @.7], @[@.5, @1.3]]}];
    PBPhysicsWorld *world = [self world:json];
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(.4638f, 1) velocity:simd_make_float2(3, 0)];
    [world advanceOneTick];
    simd_float3x3 shape = PBSoftBallShape([world softBallAtIndex:ball]);
    XCTAssertLessThan(PBSoftBallSupport(shape, simd_make_float3(1, 0, 0)), .9f);
    XCTAssertEqualWithAccuracy(world.balls[ball].velocity.x, -3 * (1 - .045f / 960) * .42f, 1e-5);
    XCTAssertEqualWithAccuracy(world.balls[ball].position.x, .5f - world.table.ballRadius - .006f, 1e-6);
    [world removeBall:ball];
    ball = [world spawnBallAtPlunger];
    [self assertRound:[world softBallAtIndex:ball]];
}

- (void)testLiveGameFramesKeepAnOrdinaryImpactVisible {
    NSMutableDictionary *json = [self emptyTable];
    json[@"flippers"] = @[];
    json[@"walls"] = @[@{@"id":@"wall", @"style":@"wall", @"radius":@.006, @"height":@.08, @"points":@[@[@.5, @.7], @[@.5, @1.3]]}];
    PBTableDefinition *table = [self world:json].table;
    for (NSNumber *rate in @[@30, @60, @120]) {
        PBGame *game = [[PBGame alloc] initWithTable:table highScore:0];
        [game requestNewGame]; [game update:0];
        [game.world removeAllPlayBalls];
        NSInteger ball = [game.world spawnBallAtPlunger];
        [game.world placeBall:ball at:simd_make_float2(.4638f, 1) velocity:simd_make_float2(2.4f, 0)];
        // Sample after complete display frames, not one 1/960 s solver tick.
        // Noticeable squash must survive several display frames (~67–83 ms).
        NSInteger frames = rate.integerValue / 12;
        for (NSInteger frame = 0; frame < frames; frame++) {
            [game update:1.0 / rate.doubleValue];
            simd_float3x3 shape = PBSoftBallShape([game.world softBallAtIndex:ball]);
            XCTAssertLessThan(PBSoftBallSupport(shape, simd_make_float3(1, 0, 0)), .91f, @"frame %ld at %@ Hz", (long)frame, rate);
            XCTAssertEqualWithAccuracy(simd_determinant(shape), 1, 2e-6);
        }
        for (NSInteger frame = 0; frame < rate.integerValue; frame++) [game update:1.0 / rate.doubleValue];
        [self assertRound:[game.world softBallAtIndex:ball]];
    }
}

- (void)testActualFlipperContactUsesItsSurfaceNormal {
    PBPhysicsWorld *world = [self world:[self emptyTable]];
    PBFlipperDef *flipper = world.table.flippers[0];
    simd_float2 axis = simd_make_float2(cosf(flipper.restAngle), sinf(flipper.restAngle));
    simd_float2 normal = simd_make_float2(-axis.y, axis.x);
    float radius = flipper.baseRadius + (flipper.tipRadius - flipper.baseRadius) * .6f;
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:flipper.pivot + axis * flipper.length * .6f + normal * (world.table.ballRadius + radius - .001f) velocity:-normal * 3];
    [world advanceOneTick];
    simd_float3x3 shape = PBSoftBallShape([world softBallAtIndex:ball]);
    XCTAssertLessThan(PBSoftBallSupport(shape, simd_make_float3(normal.x, normal.y, 0)), .9f);
    XCTAssertGreaterThan(simd_dot(world.balls[ball].velocity, normal), 0);
}

- (void)testBallToBallContactDeformsBothBodies {
    NSMutableDictionary *json = [self emptyTable]; json[@"flippers"] = @[];
    PBPhysicsWorld *world = [self world:json];
    NSInteger a = [world spawnBallAtPlunger], b = [world spawnBallAtPlunger];
    [world placeBall:a at:simd_make_float2(.469f, 1) velocity:simd_make_float2(1.5, 0)];
    [world placeBall:b at:simd_make_float2(.531f, 1) velocity:simd_make_float2(-1.5, 0)];
    [world advanceOneTick];
    for (NSNumber *index in @[@(a), @(b)]) {
        simd_float3x3 shape = PBSoftBallShape([world softBallAtIndex:index.integerValue]);
        XCTAssertLessThan(PBSoftBallSupport(shape, simd_make_float3(1, 0, 0)), .95f);
        XCTAssertEqualWithAccuracy(simd_determinant(shape), 1, 2e-6);
    }
    XCTAssertLessThan(world.balls[a].velocity.x, 0);
    XCTAssertGreaterThan(world.balls[b].velocity.x, 0);
}
@end
