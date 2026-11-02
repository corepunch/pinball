//
//  PBTableTests.m
//  Plays the real table headless. A layout mistake in the JSON (a gap too narrow,
//  a shot that can't be made, a flat spot that traps a ball) shows up here, not as
//  a bug report: this is the safety net for adding more tables.
//

#import <XCTest/XCTest.h>
#import "PBGame.h"
#import "PBLayoutValidator.h"

@interface PBStatsObserver : NSObject <PBGameObserver>
@property (nonatomic, strong) NSCountedSet<NSString *> *hits;
@end

@implementation PBStatsObserver
- (instancetype)init { if ((self = [super init])) _hits = [NSCountedSet set]; return self; }
- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {
    [self.hits addObject:PBEventName(event->kind)];
    [self.hits addObject:[NSString stringWithFormat:@"%@:%@", PBEventName(event->kind), PBEventElementIdentifier(*event, game.table)]];
    if (event->kind == PBEventRampComplete) [self.hits addObject:game.table.ramps[(NSUInteger)event->element].identifier];
    if (event->kind == PBEventRollover) [self.hits addObject:game.table.rollovers[(NSUInteger)event->element].identifier];
    if (event->kind == PBEventStandup) [self.hits addObject:game.table.standups[(NSUInteger)event->element].identifier];
}
- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier { [self.hits addObject:[@"flash:" stringByAppendingString:flasherIdentifier]]; }
- (void)game:(PBGame *)game fanfare:(NSString *)name { [self.hits addObject:[@"fanfare:" stringByAppendingString:name]]; }
@end

@interface PBTableTests : XCTestCase
@end

@implementation PBTableTests

- (PBTableDefinition *)loadTable:(NSString *)name {
    NSString *path = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
                      stringByAppendingFormat:@"/../GameData/Tables/%@.json", name];
    NSError *error;
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSData dataWithContentsOfFile:path] error:&error];
    XCTAssertNotNil(table, @"%@", error);
    return table;
}

- (NSArray<NSString *> *)allTableNames {
    NSString *folder = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../GameData/Tables"];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:NULL]) {
        if ([file.pathExtension isEqualToString:@"json"]) [names addObject:file.stringByDeletingPathExtension];
    }
    return names;
}

- (NSMutableDictionary *)tableJSON:(NSString *)name {
    NSString *path = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
                      stringByAppendingFormat:@"/../GameData/Tables/%@.json", name];
    return [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:NSJSONReadingMutableContainers error:NULL];
}

- (NSArray<PBLayoutIssue *> *)issuesForJSON:(NSDictionary *)json {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    return [PBLayoutValidator issuesForTable:[[PBTableDefinition alloc] initWithJSONData:data error:NULL]];
}

- (void)testBlenderSamplesAndModifierDimensionsSurviveLoading {
    NSMutableDictionary *json = [self tableJSON:@"aurora"];
    NSMutableDictionary *ramp = json[@"ramps"][0];
    NSMutableDictionary *settings = [ramp[@"authoring"] mutableCopy];
    settings[@"path_sampled"] = @YES;
    settings[@"wall_height"] = @0.047;
    settings[@"rail_width"] = @0.009;
    ramp[@"authoring"] = settings;
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] error:NULL];
    PBRampDef *loaded = table.ramps[0];
    XCTAssertEqual(loaded.pointCount, [ramp[@"points"] count], @"Blender's samples must not be smoothed again");
    XCTAssertEqualWithAccuracy(loaded.wallHeight, .047, 1e-6);
    XCTAssertEqualWithAccuracy(loaded.railWidth, .009, 1e-6);
    for (NSInteger i = 0; i < loaded.pointCount; i++) {
        NSArray *p = ramp[@"points"][(NSUInteger)i];
        XCTAssertEqualWithAccuracy([loaded pointAtIndex:i].x, [p[0] floatValue], 1e-6);
        XCTAssertEqualWithAccuracy([loaded pointAtIndex:i].y, [p[1] floatValue], 1e-6);
        XCTAssertEqualWithAccuracy([loaded pointAtIndex:i].z, [p[2] floatValue], 1e-6);
    }
}

- (void)testBallDoesNotSettleBetweenRampAndDropTargetHousing {
    // A hidden wall under the ramp used to end just below the housing's corner, leaving a dip.
    for (NSArray *drop in @[ @[ @"aurora", @0.70, @1.08 ], @[ @"meridian", @0.25, @1.08 ] ]) {
        PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:[self tableJSON:drop[0]] options:0 error:NULL] error:NULL];
        PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
        NSInteger ball = [world spawnBallAtPlunger];
        simd_float2 start = simd_make_float2([drop[1] floatValue], [drop[2] floatValue]);
        [world placeBall:ball at:start velocity:simd_make_float2(0, 0)];
        for (int i = 0; i < 180 && world.balls[ball].state == PBBallFree; i++) [world advanceBy:1.0 / 60.0];
        XCTAssertLessThan(world.balls[ball].position.y, 0.9, @"%@: the ball must roll on past the housing", drop[0]);
    }
}

- (void)testABallTheSearchCannotFreeIsServedAgain {
    NSMutableDictionary *json = [self tableJSON:@"aurora"];
    // A closed box around the ball: no shove can get it out.
    json[@"walls"] = [json[@"walls"] arrayByAddingObject:@{ @"id": @"box", @"style": @"none", @"radius": @0.006, @"height": @0.05, @"closed": @YES,
        @"points": @[ @[ @0.45, @0.9 ], @[ @0.55, @0.9 ], @[ @0.55, @1.0 ], @[ @0.45, @1.0 ] ] }];
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] error:NULL];
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(0.5, 0.95) velocity:simd_make_float2(0, 0)];
    for (int i = 0; i < 60 * 15; i++) [world advanceBy:1.0 / 60.0];
    XCTAssertGreaterThan(world.balls[ball].position.x, 0.9, @"it must end up back in the shooter lane");
}

- (void)testGeneratedColumnIsAnActualPlayfieldCollider {
    NSMutableDictionary *json = [self tableJSON:@"aurora"];
    json[@"physics"][@"gravity"] = @0;
    for (NSString *key in @[ @"walls", @"posts", @"bumpers", @"slingshots", @"dropTargets", @"standups", @"rollovers", @"spinners", @"saucers", @"gates", @"kickbacks", @"magnets", @"captiveBalls" ]) json[key] = @[];
    NSMutableDictionary *ramp = json[@"ramps"][0];
    ramp[@"authoring"][@"columns"] = @[ @[ @0.5, @1.2, @0.1 ] ];
    json[@"ramps"] = @[ ramp ];
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] error:NULL];
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(.4, 1.2) velocity:simd_make_float2(1, 0)];
    for (int i = 0; i < 8; i++) [world advanceBy:1.0 / 60.0];
    XCTAssertLessThan(world.balls[ball].velocity.x, 0, @"the ball must bounce off the generated shaft");
}

- (BOOL)issues:(NSArray<PBLayoutIssue *> *)issues contain:(NSString *)first and:(NSString *)second kind:(PBLayoutIssueKind)kind {
    for (PBLayoutIssue *issue in issues) {
        if (issue.kind != kind) continue;
        if (([issue.first isEqualToString:first] && [issue.second isEqualToString:second]) ||
            ([issue.first isEqualToString:second] && [issue.second isEqualToString:first])) return YES;
    }
    return NO;
}

// Every table in GameData is checked, so a new board is covered just by being added.
- (void)testNoTableHasOverlappingElements {
    NSArray *names = [self allTableNames];
    XCTAssertGreaterThan(names.count, 0u);
    for (NSString *name in names) {
        for (PBLayoutIssue *issue in [PBLayoutValidator issuesForTable:[self loadTable:name]]) {
            XCTFail(@"%@: %@", name, issue);
        }
    }
}

// The checks above are only worth having if each one still fires.
- (void)testValidatorFindsALampOnABumper {
    NSMutableDictionary *json = [self tableJSON:@"aurora"];
    NSMutableDictionary *lamp = json[@"lamps"][0], *bumper = json[@"bumpers"][0];
    lamp[@"x"] = bumper[@"x"];
    lamp[@"y"] = bumper[@"y"];
    XCTAssertTrue([self issues:[self issuesForJSON:json] contain:lamp[@"id"] and:bumper[@"id"] kind:PBLayoutIssueOverlap]);
}

- (void)testValidatorFindsARampOverABumper {
    NSMutableDictionary *json = [self tableJSON:@"aurora"];
    NSMutableDictionary *ramp = json[@"ramps"][0], *bumper = json[@"bumpers"][0];
    NSArray *point = ramp[@"points"][3];
    bumper[@"x"] = point[0];
    bumper[@"y"] = point[1];
    XCTAssertTrue([self issues:[self issuesForJSON:json] contain:ramp[@"id"] and:bumper[@"id"] kind:PBLayoutIssueOverlap]);
}

- (void)testValidatorFindsWallsCrossing {
    NSMutableDictionary *json = [self tableJSON:@"aurora"];
    [json[@"walls"] addObject:@{ @"id": @"crossing", @"style": @"wall", @"height": @0.05, @"radius": @0.006,
                                 @"points": @[ @[ @0.03, @0.8 ], @[ @0.5, @0.8 ] ] }];
    NSArray *issues = [self issuesForJSON:json];
    XCTAssertTrue([self issues:issues contain:@"crossing" and:@"guideOrbitL" kind:PBLayoutIssueOverlap] ||
                  [self issues:issues contain:@"crossing" and:@"magnet" kind:PBLayoutIssueOverlap], @"%@", issues);
}

- (void)testValidatorFindsAGapTooNarrowForTheBall {
    NSMutableDictionary *json = [self tableJSON:@"aurora"];
    NSMutableDictionary *a = json[@"bumpers"][0], *b = json[@"bumpers"][1];
    b[@"x"] = @([a[@"x"] floatValue] + [a[@"r"] floatValue] * 2.0f * 1.14f + 0.02f);
    b[@"y"] = a[@"y"];
    XCTAssertTrue([self issues:[self issuesForJSON:json] contain:a[@"id"] and:b[@"id"] kind:PBLayoutIssueNarrowGap]);
}

- (void)testValidatorFindsDecorOnTheApron {
    NSMutableDictionary *json = [self tableJSON:@"aurora"];
    json[@"decor"] = [@[ @{ @"id": @"sunken", @"model": @"gear", @"x": @0.5, @"y": @0.0, @"size": @0.02 } ] mutableCopy];
    BOOL found = NO;
    for (PBLayoutIssue *issue in [self issuesForJSON:json]) {
        if (issue.kind == PBLayoutIssueOutOfBounds && [issue.first isEqualToString:@"sunken"]) found = YES;
    }
    XCTAssertTrue(found);
}

// Footprints are only honest if they cover the models actually drawn.
- (void)testFootprintsCoverTheBlenderModels {
    NSString *path = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../Art/Models/manifest.json"];
    NSDictionary *assets = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:NULL][@"assets"];
    XCTAssertLessThanOrEqual([assets[@"bumper-base"][@"radius"] floatValue], PBBumperFootprintScale);
    XCTAssertLessThanOrEqual([assets[@"bumper-cap"][@"radius"] floatValue], PBBumperFootprintScale);
    XCTAssertLessThanOrEqual([assets[@"insert-bezel"][@"radius"] floatValue], PBLampFootprintScale);
    XCTAssertLessThanOrEqual([assets[@"post"][@"radius"] floatValue], PBPostFootprintScale);
    // A missing model would otherwise leave a hole, or fall back to plain procedural parts.
    NSString *compiled = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../GameData/Models/premium"];
    for (NSString *name in [self allTableNames]) {
        PBTableDefinition *table = [self loadTable:name];
        NSMutableArray<NSString *> *models = [NSMutableArray array];
        for (PBDecorDef *decor in table.decor) [models addObject:decor.model];
        for (PBSpotDef *post in table.posts) if (post.model) [models addObject:post.model];
        for (PBRampDef *ramp in table.ramps) {
            NSString *model = [NSString stringWithFormat:@"%@-%@", table.identifier, ramp.identifier];
            [models addObject:model];
            XCTAssertLessThanOrEqual([assets[model][@"triangles"] integerValue], 6000,
                                     @"%@ exceeds the complete ramp triangle budget", model);
        }
        for (NSString *part in @[ @"flipper", @"walls", @"plastics" ]) [models addObject:[NSString stringWithFormat:@"%@-%@", table.identifier, part]];
        for (NSString *model in models) {
            XCTAssertNotNil(assets[model], @"%@: %@ is not built", name, model);
            NSString *scene = [compiled stringByAppendingFormat:@"/%@.scn", model];
            XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:scene], @"%@: %@ is not compiled", name, model);
        }
    }
}

- (void)testBallStaysInsideTheTable {
    for (NSString *name in [self allTableNames]) [self checkBallStaysInside:[self loadTable:name]];
}

- (void)checkBallStaysInside:(PBTableDefinition *)table {
    PBGame *game = [[PBGame alloc] initWithTable:table highScore:0];
    game.autopilot = YES;
    for (int i = 0; i < 60 * 300; i++) {
        [game update:1.0 / 60.0];
        const PBBall *balls = game.world.balls;
        for (NSInteger b = 0; b < game.world.ballCapacity; b++) {
            if (balls[b].state == PBBallInactive) continue;
            XCTAssertTrue(balls[b].position.x > 0.0f && balls[b].position.x < 1.0f, @"ball %ld x=%f", (long)b, balls[b].position.x);
            XCTAssertTrue(balls[b].position.y > 0.0f && balls[b].position.y < table.size.y, @"ball %ld y=%f", (long)b, balls[b].position.y);
            XCTAssertFalse(isnan(balls[b].position.x), @"NaN");
        }
    }
}

- (void)testFullPowerPlungeReachesTheTopLanes {
    for (NSString *name in [self allTableNames]) [self checkFullPowerPlunge:[self loadTable:name]];
}

- (void)checkFullPowerPlunge:(PBTableDefinition *)table {
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger index = [world spawnBallAtPlunger];
    [world setPlungerPulled:YES];
    for (int i = 0; i < 60; i++) [world advanceBy:1.0 / 60.0];
    [world setPlungerPulled:NO];
    float top = 0, leftmost = 1;
    for (int i = 0; i < 60 * 3; i++) {
        [world advanceBy:1.0 / 60.0];
        top = MAX(top, world.balls[index].position.y);
        leftmost = MIN(leftmost, world.balls[index].position.x);
    }
    XCTAssertGreaterThan(top, 1.9f, @"ball should climb to the arch");
    XCTAssertLessThan(leftmost, 0.8f, @"ball should clear the one-way gate into the playfield");
}

- (void)testShortPlungeRollsBackToThePlunger {
    for (NSString *name in [self allTableNames]) [self checkShortPlunge:[self loadTable:name]];
}

- (void)checkShortPlunge:(PBTableDefinition *)table {
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    [world spawnBallAtPlunger];
    [world setPlungerPulled:YES];
    for (int i = 0; i < 12; i++) [world advanceBy:1.0 / 60.0];
    [world setPlungerPulled:NO];
    for (int i = 0; i < 60 * 3; i++) [world advanceBy:1.0 / 60.0];
    XCTAssertTrue(world.isBallOnPlunger);
}

- (void)testBallPassesBetweenRestingFlippers {
    for (NSString *name in [self allTableNames]) [self checkBallPassesFlippers:[self loadTable:name]];
}

- (void)checkBallPassesFlippers:(PBTableDefinition *)table {
    simd_float2 left = table.flippers.firstObject.pivot, right = table.flippers.lastObject.pivot;
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger index = [world spawnBallAtPlunger];
    [world placeBall:index at:simd_make_float2((left.x + right.x) * 0.5f, left.y + 0.105f) velocity:0];
    __block BOOL drained = NO;
    for (int i = 0; i < 60 * 3 && !drained; i++) {
        [world advanceBy:1.0 / 60.0];
        [world drainEvents:^(const PBEvent *event) { if (event->kind == PBEventDrain) drained = YES; }];
    }
    XCTAssertTrue(drained, @"a ball straight down the middle must drain, not wedge");
}

- (void)testFlipperSendsBallUpTheTable {
    for (NSString *name in [self allTableNames]) [self checkFlipperSendsBallUp:[self loadTable:name]];
}

- (void)checkFlipperSendsBallUp:(PBTableDefinition *)table {
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger index = [world spawnBallAtPlunger];
    [world placeBall:index at:table.flippers.firstObject.pivot + simd_make_float2(0.09f, 0.0f) velocity:0];
    for (int i = 0; i < 6; i++) [world advanceBy:1.0 / 60.0];
    [world setFlipperGroupLeft:YES pressed:YES];
    float top = 0;
    for (int i = 0; i < 60; i++) { [world advanceBy:1.0 / 60.0]; top = MAX(top, world.balls[index].position.y); }
    XCTAssertGreaterThan(top, 0.9f, @"a full flip should reach the upper playfield");
}

// Arming it takes both left targets and then a left outlane ball, too rare to count on in autoplay.
- (void)testArmedKickbackSavesALeftOutlaneBall {
    PBTableDefinition *table = [self loadTable:@"aurora"];
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    [world setKickback:0 armed:YES];
    NSInteger index = [world spawnBallAtPlunger];
    PBSpotDef *kickback = table.kickbacks.firstObject;
    [world placeBall:index at:kickback.position + simd_make_float2(0, 0.14f) velocity:simd_make_float2(0, -0.5f)];
    __block BOOL kicked = NO;
    for (int i = 0; i < 60 && !kicked; i++) {
        [world advanceBy:1.0 / 60.0];
        [world drainEvents:^(const PBEvent *event) { if (event->kind == PBEventKickback) kicked = YES; }];
    }
    XCTAssertTrue(kicked);
    float top = 0;
    for (int i = 0; i < 40; i++) { [world advanceBy:1.0 / 60.0]; top = MAX(top, world.balls[index].position.y); }
    XCTAssertGreaterThan(top, 0.6f, @"the kick should clear the outlane");
}

- (void)testAllFeaturesAreReachableInPlay {
    for (NSString *name in [self allTableNames]) [self checkFeaturesReachable:[self loadTable:name]];
}

- (void)checkFeaturesReachable:(PBTableDefinition *)table {
    PBStatsObserver *stats = [PBStatsObserver new];
    PBGame *game = [[PBGame alloc] initWithTable:table highScore:0];
    [game addObserver:stats];
    game.autopilot = YES;
    int64_t bestScore = 0;
    for (int i = 0; i < 60 * 60 * 25; i++) {  // 25 simulated minutes.
        [game update:1.0 / 60.0];
        bestScore = MAX(bestScore, game.rules.score);
    }

    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *key in [stats.hits.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        [lines addObject:[NSString stringWithFormat:@"%@=%lu", key, (unsigned long)[stats.hits countForObject:key]]];
    }
    NSLog(@"STATS %@ best=%lld %@", table.identifier, bestScore, [lines componentsJoinedByString:@" "]);

    NSMutableArray *mustHappen = [@[ @"bumper", @"sling", @"fanfare:gameOver" ] mutableCopy];
    if (table.dropTargets.count) [mustHappen addObject:@"drop"];
    if (table.spinners.count) [mustHappen addObject:@"spinner"];
    if (table.saucers.count) [mustHappen addObject:@"saucer"];
    if (table.magnets.count) [mustHappen addObject:@"magnet"];
    if (table.rules.locksForMultiball && table.saucers.count) [mustHappen addObject:@"fanfare:multiball"];
    if (table.ramps.count) [mustHappen addObjectsFromArray:@[ @"rampEnter", @"rampComplete" ]];
    for (PBRampDef *ramp in table.ramps) [mustHappen addObject:ramp.identifier];
    for (PBSpotDef *rollover in table.rollovers) [mustHappen addObject:rollover.identifier];
    for (PBEdgeDef *standup in table.standups) [mustHappen addObject:standup.identifier];
    NSDictionary *byKind = @{ @"bumper":table.bumpers, @"sling":table.slingshots,
        @"drop":table.dropTargets, @"spinner":table.spinners, @"saucer":table.saucers,
        @"magnet":table.magnets, @"gate":table.gates };
    for (NSString *kind in byKind) for (PBElementDef *element in byKind[kind])
        [mustHappen addObject:[NSString stringWithFormat:@"%@:%@",kind,element.identifier]];
    for (NSString *key in mustHappen) XCTAssertGreaterThan([stats.hits countForObject:key], 0u, @"%@: %@ never happened", table.identifier, key);
    XCTAssertGreaterThan(bestScore, 50000);
    NSUInteger drains = [stats.hits countForObject:@"drain"];
    NSUInteger stuck = [stats.hits countForObject:@"stuck"];
    XCTAssertLessThan(stuck, MAX(drains, 1u), @"ball search should be rare; a high count means a trap in the layout");
}

@end

