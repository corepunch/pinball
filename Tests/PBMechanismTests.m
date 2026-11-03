#import <XCTest/XCTest.h>
#import "PBGame.h"
#import "PBGateGeometry.h"

@interface PBMechanismTests : XCTestCase @end
@implementation PBMechanismTests
/// A shipped table, or `features`, the old level 1 kept in Tests/Fixtures with every kind of device.
- (NSString *)pathForTable:(NSString *)name {
    NSString *root=[NSString stringWithUTF8String:__FILE__].stringByDeletingLastPathComponent;
    NSString *shipped=[root stringByAppendingFormat:@"/../GameData/Tables/%@.json",name];
    return [NSFileManager.defaultManager fileExistsAtPath:shipped] ? shipped : [root stringByAppendingFormat:@"/Fixtures/%@.json",name];
}
- (NSMutableDictionary *)empty:(NSString *)name {
    NSMutableDictionary *json=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[self pathForTable:name]] options:NSJSONReadingMutableContainers error:NULL];
    for (NSString *key in @[ @"walls", @"posts", @"flippers", @"bumpers", @"slingshots", @"dropTargets", @"standups", @"rollovers", @"spinners", @"saucers", @"gates", @"kickbacks", @"magnets", @"captiveBalls", @"ramps" ]) json[key]=@[];
    json[@"physics"][@"gravity"]=@0;
    return json;
}
- (PBPhysicsWorld *)world:(NSDictionary *)json {
    PBTableDefinition *t=[[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] error:NULL];
    return [[PBPhysicsWorld alloc] initWithTable:t seed:17];
}
- (NSArray<NSString *> *)run:(PBPhysicsWorld *)w ticks:(int)ticks {
    NSMutableArray *events=[NSMutableArray array];
    for (int i=0;i<ticks;i++) {
        [w advanceOneTick];
        [w drainEvents:^(const PBEvent *e) { [events addObject:[NSString stringWithFormat:@"%@:%@",PBEventName(e->kind),PBEventElementIdentifier(*e,w.table)]]; }];
    }
    return events;
}
- (void)testEveryShippingContactDeviceByIDInIsolation {
    NSDictionary *types=@{ @"bumpers":@"bumper", @"slingshots":@"sling", @"dropTargets":@"drop", @"standups":@"standup", @"spinners":@"spinner", @"rollovers":@"rollover", @"saucers":@"saucer", @"gates":@"gate", @"kickbacks":@"kickback", @"magnets":@"magnet" };
    for (NSString *name in @[ @"aurora", @"features" ]) {
        NSDictionary *shipping=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[self pathForTable:name]] options:0 error:NULL];
        for (NSString *key in types) for (NSDictionary *device in shipping[key]) {
            if ([device[@"layers"] containsObject:@"deck"]) continue;  // On the second level: a ball from the plunger never meets it.
            NSMutableDictionary *json=[self empty:name]; json[key]=@[device];
            PBPhysicsWorld *w=[self world:json];
            NSInteger ball=[w spawnBallAtPlunger];
            simd_float2 p=simd_make_float2([device[@"x"] floatValue],[device[@"y"] floatValue]), v=simd_make_float2(0,-1);
            if (device[@"a"]) {
                NSArray *a=device[@"a"], *b=device[@"b"];
                simd_float2 av=simd_make_float2([a[0] floatValue],[a[1] floatValue]), bv=simd_make_float2([b[0] floatValue],[b[1] floatValue]);
                simd_float2 normal=simd_normalize(simd_make_float2(-(bv-av).y,(bv-av).x));
                if ([key isEqual:@"gates"]) {
                    NSArray *d=device[@"passDirection"];
                    v=simd_normalize(simd_make_float2([d[0] floatValue],[d[1] floatValue]))*2;
                    p=(av+bv)*.5f-v*.025f;
                } else { p=(av+bv)*.5f+normal*.035f; v=-normal*3; }
            } else if ([key isEqual:@"bumpers"]) { p.x += [device[@"r"] floatValue]+w.table.ballRadius-.001f; v=simd_make_float2(-1,0); }
            else if ([key isEqual:@"saucers"] || [key isEqual:@"rollovers"] || [key isEqual:@"magnets"]) v=0;
            if ([key isEqual:@"kickbacks"]) [w setKickback:0 armed:YES];
            if ([key isEqual:@"magnets"]) [w setMagnet:0 armed:YES];
            [w placeBall:ball at:p velocity:v];
            NSArray *events=[self run:w ticks:[key isEqual:@"spinners"] ? 960 : 120];
            NSString *expected=[NSString stringWithFormat:@"%@:%@",types[key],device[@"id"]];
            XCTAssertTrue([events containsObject:expected],@"%@ %@ %@: %@",name,key,device[@"id"],events);
        }
    }
}
- (void)testGateBlocksReverseAndPassesForward {
    NSMutableDictionary *j=[self empty:@"aurora"];
    j[@"gates"]=@[ @{ @"id":@"gate", @"a":@[ @.3,@1 ], @"b":@[ @.7,@1 ], @"passDirection":@[ @0,@1 ] } ];
    PBPhysicsWorld *w=[self world:j]; NSInteger b=[w spawnBallAtPlunger];
    [w placeBall:b at:simd_make_float2(.5,1.035) velocity:simd_make_float2(0,-2)];
    XCTAssertFalse([[self run:w ticks:40] containsObject:@"gate:gate"]);
    XCTAssertGreaterThan(w.balls[b].velocity.y,0);
    [w placeBall:b at:simd_make_float2(.5,.95) velocity:simd_make_float2(0,2)];
    XCTAssertTrue([[self run:w ticks:40] containsObject:@"gate:gate"]);
}
- (void)testDiagonalGateBlocksReverseEvenWithUpwardTangentialVelocity {
    NSMutableDictionary *json = [self empty:@"aurora"];
    json[@"gates"] = @[@{@"id": @"diagonal", @"a": @[@.3, @.9], @"b": @[@.7, @1.3], @"passDirection": @[@0, @1]}];
    PBPhysicsWorld *world = [self world:json];
    simd_float2 normal = simd_normalize(simd_make_float2(-1, 1));
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(.5, 1.1) + normal * .033f velocity:simd_make_float2(2, .1)];
    NSArray *events = [self run:world ticks:8];
    XCTAssertGreaterThan(simd_dot(world.balls[ball].velocity, normal), 0, @"positive y velocity must not bypass the slanted closed gate from its back");
    XCTAssertEqualWithAccuracy([world gateAngle:0], 0, 1e-6);
    XCTAssertFalse([events containsObject:@"gate:diagonal"]);
}

- (void)testDiagonalGateAllowsForwardPassWithNegativeVerticalVelocity {
    NSMutableDictionary *json = [self empty:@"aurora"];
    json[@"gates"] = @[@{@"id": @"diagonal", @"a": @[@.3, @.9], @"b": @[@.7, @1.3], @"passDirection": @[@0, @1]}];
    PBPhysicsWorld *world = [self world:json];
    simd_float2 normal = simd_normalize(simd_make_float2(-1, 1));
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(.5, 1.1) - normal * .045f velocity:simd_make_float2(-2, -.1)];
    NSArray *events = [self run:world ticks:80];
    XCTAssertTrue([events containsObject:@"gate:diagonal"], @"actual forward crossing, independent of the vertical velocity sign");
    XCTAssertLessThan(world.balls[ball].velocity.x, -1.9f, @"light gate does not reverse or slow the legal shot");
    XCTAssertGreaterThan([world gateAngle:0], 1.2f);
}

- (void)testWeakPlungeCanReverseInsideTheGateWithoutSnappingOrBeingTrapped {
    NSMutableDictionary *json = [self empty:@"aurora"];
    json[@"physics"][@"gravity"] = @2.2;
    json[@"gates"] = @[@{@"id": @"gate", @"a": @[@.3, @1], @"b": @[@.7, @1], @"passDirection": @[@0, @1]}];
    PBPhysicsWorld *world = [self world:json];
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(.5, .95) velocity:simd_make_float2(0, .5)];
    NSArray *events = [self run:world ticks:528];
    XCTAssertTrue([events containsObject:@"gate:gate"]);
    XCTAssertFalse([events containsObject:@"wall:wall"], @"the gate must not close its collider inside a returning ball");
    XCTAssertLessThan(world.balls[ball].position.y, .95f);
    XCTAssertLessThan(world.balls[ball].velocity.y, -.65f);
    [self run:world ticks:400];
    XCTAssertEqualWithAccuracy([world gateAngle:0], 0, .001, @"wire returns to its mechanical stop once the whole ball clears");
}

- (void)testPartlyOpenedGateCannotSwingPastItsUpperStopAfterBallLeaves {
    NSMutableDictionary *json = [self empty:@"aurora"];
    json[@"gates"] = @[@{@"id": @"gate", @"a": @[@.3, @1], @"b": @[@.7, @1], @"passDirection": @[@0, @1]}];
    PBPhysicsWorld *world = [self world:json];
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(.5, .95) velocity:simd_make_float2(0, 2)];
    [world advanceOneTick];
    XCTAssertGreaterThan([world gateAngle:0], 0);
    [world removeBall:ball];
    for (int i = 0; i < 960; i++) {
        [world advanceOneTick];
        XCTAssertGreaterThanOrEqual([world gateAngle:0], 0);
        XCTAssertLessThanOrEqual([world gateAngle:0], 1.48001f);
    }
    XCTAssertEqualWithAccuracy([world gateAngle:0], 0, .001);
}

- (void)testOpenDoorRotatesInTheFieldAndStillCollidesAtItsFreeEnd {
    NSMutableDictionary *json = [self empty:@"aurora"];
    json[@"gates"] = @[@{@"id": @"door", @"a": @[@.3, @1], @"b": @[@.7, @1], @"passDirection": @[@0, @1]}];
    PBPhysicsWorld *world = [self world:json];
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(.5, .95) velocity:simd_make_float2(0, 2)];
    [self run:world ticks:30];
    float angle = [world gateAngle:0];
    XCTAssertGreaterThan(angle, 1.4f);
    simd_float2 hinge = simd_make_float2(.3, 1), closedTip = simd_make_float2(.7, 1);
    simd_float2 tip = PBGateTip(hinge, closedTip, simd_make_float2(0, 1), angle);
    XCTAssertEqualWithAccuracy(simd_distance(hinge, tip), .4f, 1e-6);
    simd_float2 axis = simd_normalize(tip - hinge);
    simd_float2 normal = simd_make_float2(-axis.y, axis.x);
    float reach = world.table.ballRadius + PBGateGeometryMake(world.table.ballRadius).wireRadius;
    [world placeBall:ball at:(hinge + tip) * .5f + normal * (reach - .002f) velocity:-normal * 2];
    [world advanceOneTick];
    XCTAssertGreaterThan(simd_dot(world.balls[ball].velocity, normal), 0, @"the open door has a rotated collider at ball height, rather than floating above it");
}

- (void)testRealShooterGateOpensAndClosesAfterOneCleanFullPowerPass {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[self pathForTable:@"aurora"]] options:0 error:NULL];
    PBPhysicsWorld *world = [self world:json];
    [world spawnBallAtPlunger];
    [world setPlungerPulled:YES];
    [self run:world ticks:960];
    [world setPlungerPulled:NO];
    __block NSInteger crossings = 0;
    float maximum = 0;
    for (int i = 0; i < 960; i++) {
        [world advanceOneTick]; maximum = MAX(maximum, [world gateAngle:0]);
        [world drainEvents:^(const PBEvent *event) { if (event->kind == PBEventGate && event->element == 0) crossings++; }];
    }
    XCTAssertGreaterThan(maximum, 1.4f);
    XCTAssertEqualWithAccuracy([world gateAngle:0], 0, .001);
    XCTAssertEqual(crossings, 1);
}

- (void)testSaucerEjectionCannotImmediatelyRecaptureSlowBall {
    NSMutableDictionary *j=[self empty:@"aurora"];
    j[@"saucers"]=@[ @{ @"id":@"s", @"x":@.5,@"y":@1,@"r":@.03,@"captureSpeed":@3,@"ejectSpeed":@1,@"ejectDirection":@[ @0,@-1 ] } ];
    PBPhysicsWorld *w=[self world:j];NSInteger b=[w spawnBallAtPlunger];[w placeBall:b at:simd_make_float2(.5,1) velocity:0];
    XCTAssertTrue([[self run:w ticks:1] containsObject:@"saucer:s"]);
    [w ejectSaucer:0];
    NSArray *events=[self run:w ticks:100];
    XCTAssertTrue([events containsObject:@"saucerEject:s"]);
    XCTAssertFalse([events containsObject:@"saucer:s"]);
    XCTAssertEqual(w.balls[b].state,PBBallFree);
}
- (void)testHorizontalRampCompletesAndWeakShotRollsBack {
    for (NSNumber *speed in @[ @3,@.15 ]) {
        NSMutableDictionary *j=[self empty:@"aurora"];
        j[@"ramps"]=@[ @{ @"id":@"horizontal",@"width":@.15,@"mouth":@[ @[ @.4,@.9 ],@[ @.4,@1.1 ] ],@"points":@[ @[ @.4,@1,@0 ],@[ @.7,@1,@.06 ] ],@"authoring":@{ @"path_sampled":@YES } } ];
        PBPhysicsWorld *w=[self world:j];NSInteger b=[w spawnBallAtPlunger];
        [w placeBall:b at:simd_make_float2(.3999,1) velocity:simd_make_float2(speed.floatValue,0)];
        NSArray *events=[self run:w ticks:1000];
        XCTAssertTrue([events containsObject:@"rampEnter:horizontal"]);
        XCTAssertTrue([events containsObject:speed.floatValue>1 ? @"rampComplete:horizontal" : @"rampRollback:horizontal"]);
    }
}
- (void)testRotatedSpinnerScoresAndAttributesBall {
    NSMutableDictionary *j=[self empty:@"aurora"];
    j[@"spinners"]=@[ @{ @"id":@"vertical", @"a":@[ @.5,@.8 ], @"b":@[ @.5,@1.2 ] } ];
    PBPhysicsWorld *w=[self world:j];NSInteger b=[w spawnBallAtPlunger];
    [w placeBall:b at:simd_make_float2(.49,1) velocity:simd_make_float2(3,0)];
    XCTAssertTrue([[self run:w ticks:200] containsObject:@"spinner:vertical"]);
    __block int scoreBall=-1;
    for (int i=0;i<300;i++) { [w advanceOneTick]; [w drainEvents:^(const PBEvent *e){ if(e->kind==PBEventSpinner)scoreBall=e->ball; }]; }
    XCTAssertEqual(scoreBall,b);
    [w removeBall:b]; b=[w spawnBallAtPlunger];
    [w placeBall:b at:simd_make_float2(.51,1) velocity:simd_make_float2(-6,0)];
    XCTAssertTrue([[self run:w ticks:200] containsObject:@"spinner:vertical"]);
}
- (void)testMagnetReleaseAndDeterministicSeed {
    NSMutableDictionary *j=[self empty:@"aurora"];
    j[@"magnets"]=@[ @{ @"id":@"m",@"x":@.5,@"y":@1,@"r":@.1,@"holdSeconds":@.05,@"flingSpeed":@2 } ];
    PBPhysicsWorld *a=[self world:j], *b=[self world:j];
    for (PBPhysicsWorld *w in @[a,b]) {NSInteger i=[w spawnBallAtPlunger];[w placeBall:i at:simd_make_float2(.5,1) velocity:0];[w setMagnet:0 armed:YES];}
    NSArray *events=[self run:a ticks:100];
    XCTAssertEqualObjects(events,[self run:b ticks:100]);
    XCTAssertTrue([events containsObject:@"magnetRelease:m"]);
    XCTAssertEqualWithAccuracy(a.balls[0].velocity.x,b.balls[0].velocity.x,1e-7);
}
- (void)testCaptiveBallReceivesImpulseAndStaysCaptive {
    NSMutableDictionary *j=[self empty:@"aurora"];
    j[@"captiveBalls"]=@[ @{ @"id":@"c",@"x":@.5,@"y":@1,@"r":@.03 } ];
    PBPhysicsWorld *w=[self world:j]; NSInteger b=[w spawnBallAtPlunger];
    [w placeBall:b at:simd_make_float2(.439,1) velocity:simd_make_float2(2,0)];
    [self run:w ticks:2];
    XCTAssertTrue(w.balls[0].captive);
    XCTAssertGreaterThan(w.balls[0].velocity.x,1);
    XCTAssertEqual(w.activeBallCount,1);
}
- (void)testCrossingRampsAtDifferentHeightsDoNotShareRailsOrBallContacts {
    NSMutableDictionary *j=[self empty:@"aurora"];
    j[@"ramps"]=@[
        @{ @"id":@"upper",@"width":@.15,@"mouth":@[ @[ @.3,@.9 ],@[ @.3,@1.1 ] ],
           @"points":@[ @[ @.3,@1,@.2 ],@[ @.7,@1,@.2 ] ],@"authoring":@{ @"path_sampled":@YES } },
        @{ @"id":@"lower",@"width":@.15,@"mouth":@[ @[ @.4,@.8 ],@[ @.6,@.8 ] ],
           @"points":@[ @[ @.5,@.8,@.05 ],@[ @.5,@1.2,@.05 ] ],@"authoring":@{ @"path_sampled":@YES } }
    ];
    PBPhysicsWorld *w=[self world:j];NSInteger a=[w spawnBallAtPlunger],b=[w spawnBallAtPlunger];
    [w placeBall:a at:simd_make_float2(.2999,1) velocity:simd_make_float2(1,0)];
    [w placeBall:b at:simd_make_float2(.5,.7999) velocity:simd_make_float2(0,1)];
    [self run:w ticks:250];
    XCTAssertEqual(w.balls[a].ramp,0);
    XCTAssertEqual(w.balls[b].ramp,1);
    XCTAssertGreaterThan(w.balls[a].position.x,.54);
    XCTAssertGreaterThan(w.balls[b].position.y,1.04);
    XCTAssertGreaterThan(w.balls[a].velocity.x,.8);
    XCTAssertGreaterThan(w.balls[b].velocity.y,.8);
}

- (void)testDropResetAndInactiveActuators {
    NSMutableDictionary *j=[self empty:@"aurora"];
    j[@"dropTargets"]=@[ @{ @"id":@"d",@"a":@[ @.4,@1 ],@"b":@[ @.6,@1 ] } ];
    j[@"kickbacks"]=@[ @{ @"id":@"k",@"x":@.2,@"y":@1,@"r":@.05,@"speed":@4 } ];
    j[@"magnets"]=@[ @{ @"id":@"m",@"x":@.8,@"y":@1,@"r":@.05,@"holdSeconds":@.1,@"flingSpeed":@2 } ];
    PBPhysicsWorld *w=[self world:j];NSInteger b=[w spawnBallAtPlunger];
    for (int hit=0;hit<2;hit++) {
        [w setDropTarget:0 up:YES];
        [w placeBall:b at:simd_make_float2(.5,1.035) velocity:simd_make_float2(0,-2)];
        XCTAssertTrue([[self run:w ticks:15] containsObject:@"drop:d"]);
        XCTAssertFalse([w isDropTargetUp:0]);
        [w placeBall:b at:simd_make_float2(.5,1.035) velocity:simd_make_float2(0,-2)];
        XCTAssertFalse([[self run:w ticks:15] containsObject:@"drop:d"]);
    }
    [w placeBall:b at:simd_make_float2(.2,1) velocity:simd_make_float2(0,-1)];
    XCTAssertFalse([[self run:w ticks:2] containsObject:@"kickback:k"]);
    [w placeBall:b at:simd_make_float2(.8,1) velocity:0];
    XCTAssertFalse([[self run:w ticks:2] containsObject:@"magnet:m"]);
    XCTAssertEqual(w.balls[b].state,PBBallFree);
}

- (void)testStrictSearchReportsWithoutRescuingAndTickIsExact {
    NSMutableDictionary *j=[self empty:@"aurora"];
    PBPhysicsWorld *w=[self world:j];w.automaticBallSearch=NO;
    NSInteger b=[w spawnBallAtPlunger];[w placeBall:b at:simd_make_float2(.5,1) velocity:0];
    NSArray *events=[self run:w ticks:4000];
    XCTAssertTrue([events containsObject:@"stuck:stuck"]);
    XCTAssertEqual(w.tick,4000u);
    XCTAssertEqualWithAccuracy(w.balls[b].position.x,.5,1e-7);
    XCTAssertEqualWithAccuracy(w.balls[b].velocity.x,0,1e-7);
}
@end
