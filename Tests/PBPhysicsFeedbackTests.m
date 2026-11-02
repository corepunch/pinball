#import <XCTest/XCTest.h>
#import "PBPhysicsWorld.h"

@interface PBPhysicsFeedbackTests : XCTestCase
@end

@implementation PBPhysicsFeedbackTests

// Keep the real table's physics and plunger, with isolated contacts so each
// assertion can distinguish a rebound from a scoring event or resting jitter.
- (NSMutableDictionary *)emptyTableJSON {
    NSString *path = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
                      stringByAppendingPathComponent:@"../GameData/Tables/aurora.json"];
    NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path]
                                                               options:NSJSONReadingMutableContainers error:NULL];
    for (NSString *key in @[ @"walls", @"posts", @"flippers", @"bumpers", @"slingshots", @"dropTargets",
                             @"standups", @"rollovers", @"spinners", @"saucers", @"gates", @"kickbacks",
                             @"magnets", @"captiveBalls", @"ramps" ]) json[key] = @[];
    return json;
}

- (PBPhysicsWorld *)worldWithJSON:(NSDictionary *)json {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:data error:NULL];
    XCTAssertNotNil(table);
    return [[PBPhysicsWorld alloc] initWithTable:table];
}

- (void)testSoftAndHardWallBouncesBothReportTheirImpactSpeed {
    NSMutableDictionary *json = [self emptyTableJSON];
    json[@"walls"] = @[ @{ @"id": @"wall", @"style": @"wall", @"radius": @0.006,
                           @"points": @[ @[ @0.5, @0.5 ], @[ @0.5, @1.5 ] ] } ];
    PBPhysicsWorld *world = [self worldWithJSON:json];
    NSInteger ball = [world spawnBallAtPlunger];
    for (NSNumber *speed in @[ @0.1, @2.0 ]) {
        [world placeBall:ball at:simd_make_float2(0.5309f, 1.0f) velocity:simd_make_float2(-speed.floatValue, 0)];
        [world advanceBy:1.0 / 960.0];
        __block NSInteger hits = 0;
        [world drainEvents:^(const PBEvent *event) {
            XCTAssertEqual(event->kind, PBEventWallHit);
            XCTAssertEqual(event->ball, ball);
            XCTAssertEqualWithAccuracy(event->magnitude, speed.floatValue, 0.001f);
            hits++;
        }];
        XCTAssertEqual(hits, 1);
        XCTAssertGreaterThan(world.balls[ball].velocity.x, 0);
    }
}

- (void)testSlingReportsPassiveBounceBelowItsFiringThreshold {
    NSMutableDictionary *json = [self emptyTableJSON];
    json[@"slingshots"] = @[ @{ @"id": @"sling", @"a": @[ @0.5, @0.5 ], @"b": @[ @0.5, @1.5 ] } ];
    PBPhysicsWorld *world = [self worldWithJSON:json];
    NSInteger ball = [world spawnBallAtPlunger];
    for (NSNumber *speed in @[ @0.1, @1.0 ]) {
        [world placeBall:ball at:simd_make_float2(0.5329f, 1.0f) velocity:simd_make_float2(-speed.floatValue, 0)];
        [world advanceBy:1.0 / 960.0];
        __block NSInteger hits = 0;
        [world drainEvents:^(const PBEvent *event) {
            XCTAssertEqual(event->kind, speed.floatValue < 0.25f ? PBEventWallHit : PBEventSling);
            hits++;
        }];
        XCTAssertEqual(hits, 1, @"Each bounce must report once, including when the sling fires.");
    }
}

- (void)testBumperStillReportsABounceWhileItsActuatorCoolsDown {
    NSMutableDictionary *json = [self emptyTableJSON];
    json[@"bumpers"] = @[ @{ @"id": @"bumper", @"x": @0.5, @"y": @1.0, @"r": @0.04 } ];
    PBPhysicsWorld *world = [self worldWithJSON:json];
    NSInteger ball = [world spawnBallAtPlunger];
    for (NSInteger hit = 0; hit < 2; hit++) {
        [world placeBall:ball at:simd_make_float2(0.5649f, 1.0f) velocity:simd_make_float2(-1.0f, 0)];
        [world advanceBy:1.0 / 960.0];
        __block NSInteger hits = 0;
        [world drainEvents:^(const PBEvent *event) {
            XCTAssertEqual(event->kind, hit == 0 ? PBEventBumper : PBEventWallHit);
            hits++;
        }];
        XCTAssertEqual(hits, 1);
    }
}

- (void)testSoftFlipperAndBallToBallBouncesReportFeedback {
    NSMutableDictionary *json = [self emptyTableJSON];
    json[@"flippers"] = @[ @{ @"id": @"flipper", @"side": @"left", @"pivot": @[ @0.3, @1.0 ],
                              @"length": @0.2, @"baseRadius": @0.02, @"tipRadius": @0.02,
                              @"restAngle": @0, @"activeAngle": @45 } ];
    PBPhysicsWorld *world = [self worldWithJSON:json];
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(0.4f, 1.0449f) velocity:simd_make_float2(0, -0.1f)];
    [world advanceBy:1.0 / 960.0];
    __block NSInteger hits = 0;
    [world drainEvents:^(const PBEvent *event) { if (event->kind == PBEventWallHit) hits++; }];
    XCTAssertEqual(hits, 1);
    XCTAssertGreaterThan(world.balls[ball].velocity.y, 0);

    NSInteger other = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(0.4f, 1.5f) velocity:simd_make_float2(0.1f, 0)];
    [world placeBall:other at:simd_make_float2(0.45005f, 1.5f) velocity:0];
    [world advanceBy:1.0 / 960.0];
    hits = 0;
    [world drainEvents:^(const PBEvent *event) { if (event->kind == PBEventWallHit) hits++; }];
    XCTAssertEqual(hits, 1);
    XCTAssertGreaterThan(world.balls[other].velocity.x, 0);
}

- (void)testPlungerReturnBouncesReportFeedbackAndSettlingStaysQuiet {
    PBPhysicsWorld *world = [self worldWithJSON:[self emptyTableJSON]];
    NSInteger ball = [world spawnBallAtPlunger];
    simd_float2 position = world.table.plunger.position + simd_make_float2(0, world.table.ballRadius + 0.0001f);
    [world placeBall:ball at:position velocity:simd_make_float2(0, -1.0f)];
    [world advanceBy:1.0 / 960.0];
    __block NSInteger hits = 0;
    [world drainEvents:^(const PBEvent *event) { if (event->kind == PBEventWallHit) hits++; }];
    XCTAssertEqual(hits, 1);
    XCTAssertGreaterThan(world.balls[ball].velocity.y, 0);

    for (NSInteger frame = 0; frame < 120; frame++) {
        [world advanceBy:1.0 / 60.0];
        [world drainEvents:^(const PBEvent *event) {}];
    }
    [world advanceBy:1.0 / 60.0];
    [world drainEvents:^(const PBEvent *event) { XCTFail(@"Resting ball emitted %ld", (long)event->kind); }];
}

- (void)testDrawingThePlungerWindsTheSpringThenStops {
    PBPhysicsWorld *world = [self worldWithJSON:[self emptyTableJSON]];
    [world spawnBallAtPlunger];
    [world setPlungerPulled:YES];
    __block NSInteger coils = 0;
    __block float last = 0;
    for (NSInteger frame = 0; frame < 120; frame++) {
        [world advanceBy:1.0 / 60.0];
        [world drainEvents:^(const PBEvent *event) {
            if (event->kind != PBEventPlungerCoil) return;
            XCTAssertGreaterThan(event->magnitude, last);
            last = event->magnitude;
            coils++;
        }];
    }
    XCTAssertEqual(coils, 12);
    XCTAssertEqual(last, 1.0f);
}

- (void)testLaunchMagnitudeMatchesAppliedPullAndBallSpeed {
    for (NSNumber *frames in @[ @12, @60 ]) {
        PBPhysicsWorld *world = [self worldWithJSON:[self emptyTableJSON]];
        NSInteger ball = [world spawnBallAtPlunger];
        [world setPlungerPulled:YES];
        for (NSInteger frame = 0; frame < frames.integerValue; frame++) [world advanceBy:1.0 / 60.0];
        [world drainEvents:^(const PBEvent *event) {}];
        float pull = world.plungerPull;
        [world setPlungerPulled:NO];
        __block NSInteger launches = 0;
        [world drainEvents:^(const PBEvent *event) {
            XCTAssertEqual(event->kind, PBEventPlungerRelease);
            XCTAssertEqualWithAccuracy(event->magnitude, pull, 0.0001f);
            launches++;
        }];
        XCTAssertEqual(launches, 1);
        XCTAssertEqualWithAccuracy(world.balls[ball].velocity.y, world.table.plungerSpeed * pull, 0.0001f);
        [world advanceBy:1.0 / 960.0];
        [world drainEvents:^(const PBEvent *event) {
            XCTAssertNotEqual(event->kind, PBEventWallHit, @"Plunger reset must not duplicate launch feedback.");
        }];
    }
}

@end
