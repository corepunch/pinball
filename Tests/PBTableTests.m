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

/// A shipped table from GameData/Tables, or a fixture from Tests/Fixtures: `features` is a full board
/// (ramp, deck, drops, stand-ups, scoops, bumpers) for testing rules that no shipped table uses yet.
- (NSString *)pathForTable:(NSString *)name {
    NSString *tests = [[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent];
    NSString *shipped = [tests stringByAppendingFormat:@"/../GameData/Tables/%@.json", name];
    if ([NSFileManager.defaultManager fileExistsAtPath:shipped]) return shipped;
    return [tests stringByAppendingFormat:@"/Fixtures/%@.json", name];
}

- (PBTableDefinition *)loadTable:(NSString *)name {
    NSString *path = [self pathForTable:name];
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
    NSString *path = [self pathForTable:name];
    return [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:NSJSONReadingMutableContainers error:NULL];
}

- (NSArray<PBLayoutIssue *> *)issuesForJSON:(NSDictionary *)json {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
    return [PBLayoutValidator issuesForTable:[[PBTableDefinition alloc] initWithJSONData:data error:NULL]];
}

- (void)testSampledRampPathsAndAuthoringDimensionsSurviveLoading {
    NSMutableDictionary *json = [self tableJSON:@"features"];
    NSMutableDictionary *ramp = json[@"ramps"][0];
    NSMutableDictionary *settings = [ramp[@"authoring"] mutableCopy];
    settings[@"path_sampled"] = @YES;
    settings[@"wall_height"] = @0.047;
    settings[@"rail_width"] = @0.009;
    ramp[@"authoring"] = settings;
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] error:NULL];
    PBRampDef *loaded = table.ramps[0];
    XCTAssertEqual(loaded.pointCount, [ramp[@"points"] count], @"sampled paths must not be smoothed again");
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
    for (NSArray *drop in @[ @[ @"features", @0.70, @1.08 ] ]) {
        PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:[self tableJSON:drop[0]] options:0 error:NULL] error:NULL];
        PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
        NSInteger ball = [world spawnBallAtPlunger];
        simd_float2 start = simd_make_float2([drop[1] floatValue], [drop[2] floatValue]);
        [world placeBall:ball at:start velocity:simd_make_float2(0, 0)];
        // The lowest it reached: once past, it may be anywhere, even bouncing back up an orbit.
        float lowest = start.y;
        for (int i = 0; i < 180 && world.balls[ball].state == PBBallFree; i++) {
            [world advanceBy:1.0 / 60.0];
            lowest = MIN(lowest, world.balls[ball].position.y);
        }
        XCTAssertLessThan(lowest, 0.9, @"%@: the ball must roll on past the housing", drop[0]);
    }
}

- (void)testASlingshotsTopTipDoesNotFire {
    // A tip that fired threw a ball back up through the orbit gate that had just dropped it there, for ever.
    for (NSString *name in [[self allTableNames] arrayByAddingObject:@"features"]) {
        PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:[self tableJSON:name] options:0 error:NULL] error:NULL];
        PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
        NSInteger ball = [world spawnBallAtPlunger];
        PBEdgeDef *sling = table.slingshots[1];
        [world placeBall:ball at:sling.b + simd_make_float2(0.012f, 0.06f) velocity:simd_make_float2(0, -1.5f)];
        for (int i = 0; i < 10; i++) [world advanceBy:1.0 / 60.0];
        XCTAssertGreaterThan([world slingFlash:1], 1.0f, @"%@: landing on the tip must not fire it", name);
        [world placeBall:ball at:(sling.a + sling.b) * 0.5f + simd_make_float2(-0.06f, 0.03f) velocity:simd_make_float2(1.5f, -0.6f)];
        for (int i = 0; i < 10; i++) [world advanceBy:1.0 / 60.0];
        XCTAssertLessThan([world slingFlash:1], 1.0f, @"%@: the face must still fire", name);
    }
}

- (void)testABallFallingBehindRollsUnderTheFlippersToTheDrain {
    for (NSString *name in [[self allTableNames] arrayByAddingObject:@"features"]) {
        PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:[self tableJSON:name] options:0 error:NULL] error:NULL];
        for (NSNumber *lane in @[ @0.884f, @0.2f, @0.75f ]) {
            PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
            NSInteger ball = [world spawnBallAtPlunger];
            [world placeBall:ball at:simd_make_float2(lane.floatValue, lane.floatValue == 0.884f ? 0.3f : 0.125f) velocity:simd_make_float2(0, 0)];
            for (int i = 0; i < 300 && world.balls[ball].state == PBBallFree; i++) [world advanceBy:1.0 / 60.0];
            XCTAssertNotEqual(world.balls[ball].state, PBBallFree, @"%@: the ball must reach the drain", name);
            XCTAssertEqualWithAccuracy(world.balls[ball].position.x, 0.4775f, 0.12f, @"%@: it drains between the flippers", name);
        }
    }
}

#pragma mark - Features earned in play

- (PBRuleEngine *)rulesFor:(NSMutableDictionary *)json world:(PBPhysicsWorld **)outWorld {
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] error:NULL];
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    PBRuleEngine *rules = [[PBRuleEngine alloc] initWithWorld:world highScore:0];
    [rules startGame];
    if (outWorld) *outWorld = world;
    return rules;
}

- (void)hit:(PBRuleEngine *)rules kind:(PBEventKind)kind element:(NSInteger)element magnitude:(float)magnitude {
    PBEvent event = { .kind = kind, .element = (int16_t)element, .ball = 0, .magnitude = magnitude };
    [rules handleEvent:&event];
}

/// A table whose left targets, when both are hit, do one thing.
- (NSMutableDictionary *)tableWithAction:(NSString *)action {
    NSMutableDictionary *json = [self tableJSON:@"features"];
    for (NSMutableDictionary *group in json[@"rules"][@"groups"]) {
        if ([group[@"id"] isEqualToString:@"standLeft"]) group[@"actions"] = @[ action ];
    }
    return json;
}

- (void)completeLeftTargets:(PBRuleEngine *)rules table:(PBTableDefinition *)table {
    [table.standups enumerateObjectsUsingBlock:^(PBEdgeDef *standup, NSUInteger i, BOOL *stop) {
        if ([standup.identifier hasPrefix:@"standL"]) [self hit:rules kind:PBEventStandup element:(NSInteger)i magnitude:0.1f];
    }];
}

- (void)testPlayfieldMultiplierDoublesScoringThenEnds {
    PBPhysicsWorld *world;
    PBRuleEngine *rules = [self rulesFor:[self tableWithAction:@"playfieldX"] world:&world];
    [self completeLeftTargets:rules table:world.table];
    int64_t before = rules.score;
    [self hit:rules kind:PBEventSpinner element:0 magnitude:1];
    int64_t doubled = rules.score - before;
    for (int i = 0; i < 22; i++) [rules update:1.0];
    before = rules.score;
    [self hit:rules kind:PBEventSpinner element:0 magnitude:1];
    XCTAssertEqual(doubled, (rules.score - before) * 2);
}

- (void)testVariTargetScoresByHowHardItIsHit {
    NSMutableDictionary *json = [self tableJSON:@"features"];
    NSInteger index = 0;
    for (NSMutableDictionary *standup in json[@"standups"]) {
        if ([standup[@"id"] isEqualToString:@"standL1"]) { standup[@"vari"] = @YES; index = (NSInteger)[json[@"standups"] indexOfObject:standup]; }
    }
    PBRuleEngine *rules = [self rulesFor:json world:NULL];
    [self hit:rules kind:PBEventStandup element:index magnitude:0.1f];
    int64_t gentle = rules.score;
    [self hit:rules kind:PBEventStandup element:index magnitude:5.0f];
    XCTAssertEqual(rules.score - gentle, gentle * 5);
}

- (void)testCentrePostRisesWhenEarnedAndStopsAFallingBall {
    NSMutableDictionary *json = [self tableWithAction:@"armStopper"];
    json[@"stoppers"] = [@[ [@{ @"id": @"post", @"x": @0.4775, @"y": @0.062, @"r": @0.016 } mutableCopy] ] mutableCopy];
    PBPhysicsWorld *world;
    PBRuleEngine *rules = [self rulesFor:json world:&world];
    XCTAssertFalse([world isStopperUp:0]);
    [self completeLeftTargets:rules table:world.table];
    XCTAssertTrue([world isStopperUp:0]);
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(0.4775f, 0.2f) velocity:simd_make_float2(0, -1)];
    float lowest = 1;
    for (int i = 0; i < 30; i++) { [world advanceBy:1.0 / 60.0]; lowest = MIN(lowest, world.balls[ball].position.y); }
    XCTAssertGreaterThan(lowest, 0.08f, @"the post is in the way");
    for (int i = 0; i < 22; i++) [rules update:1.0];
    XCTAssertFalse([world isStopperUp:0]);
}

- (void)testHurryUpPaysLessTheLongerItTakes {
    int64_t paid[2];
    for (int attempt = 0; attempt < 2; attempt++) {
        PBPhysicsWorld *world;
        PBRuleEngine *rules = [self rulesFor:[self tableWithAction:@"hurryUp"] world:&world];
        [self completeLeftTargets:rules table:world.table];
        for (int i = 0; i < attempt * 10; i++) [rules update:1.0];
        int64_t before = rules.score;
        [self hit:rules kind:PBEventSaucerCapture element:0 magnitude:0];
        paid[attempt] = rules.score - before;
    }
    XCTAssertGreaterThan(paid[0], paid[1]);
    XCTAssertGreaterThan(paid[1], [[self loadTable:@"features"].rules scoreFor:@"saucer"]);
}

- (void)testMysteryAwardIsSpentByTheScoop {
    PBPhysicsWorld *world;
    NSMutableDictionary *json = [self tableWithAction:@"lightMystery"];
    [json[@"lamps"] addObject:[@{ @"id": @"lampFeature", @"x": @0.4775, @"y": @0.75, @"size": @0.026, @"color": @"amber", @"icon": @0, @"bind": @"mystery" } mutableCopy]];
    PBRuleEngine *rules = [self rulesFor:json world:&world];
    NSInteger lamp = (NSInteger)world.table.lamps.count - 1;
    [self completeLeftTargets:rules table:world.table];
    [rules update:0.01];
    XCTAssertEqual([rules modeForLamp:lamp], PBLampBlink);
    [self hit:rules kind:PBEventSaucerCapture element:0 magnitude:0];
    [rules update:0.01];
    XCTAssertEqual([rules modeForLamp:lamp], PBLampOff);
}

- (void)testBonusHeldCarriesToTheNextBall {
    PBPhysicsWorld *world;
    NSMutableDictionary *json = [self tableJSON:@"features"];
    for (NSMutableDictionary *group in json[@"rules"][@"groups"]) {
        if ([group[@"id"] isEqualToString:@"standLeft"]) group[@"actions"] = @[ @"bonusX", @"holdBonus" ];
    }
    PBRuleEngine *rules = [self rulesFor:json world:&world];
    [self completeLeftTargets:rules table:world.table];
    XCTAssertEqual(rules.bonusMultiplier, 2);
    NSInteger number = rules.ballNumber;
    for (NSInteger i = 0; i < world.ballCapacity; i++) if (world.balls[i].state == PBBallFree || world.balls[i].state != PBBallInactive) [world removeBall:i];
    [self hit:rules kind:PBEventDrain element:0 magnitude:0];
    for (int i = 0; i < 4; i++) [rules update:1.0];
    XCTAssertEqual(rules.ballNumber, number + 1);
    XCTAssertEqual(rules.bonusMultiplier, 2, @"held for the next ball");
    for (NSInteger i = 0; i < world.ballCapacity; i++) if (world.balls[i].state != PBBallInactive) [world removeBall:i];
    [self hit:rules kind:PBEventDrain element:0 magnitude:0];
    for (int i = 0; i < 4; i++) [rules update:1.0];
    XCTAssertEqual(rules.bonusMultiplier, 1, @"only once");
}

- (void)testWizardModeNeedsEveryBankOfTargets {
    NSMutableDictionary *json = [self tableJSON:@"features"];
    json[@"rules"][@"wizard"] = @YES;
    PBPhysicsWorld *world;
    PBRuleEngine *rules = [self rulesFor:json world:&world];
    [world.table.standups enumerateObjectsUsingBlock:^(PBEdgeDef *standup, NSUInteger i, BOOL *stop) {
        if ([standup.identifier hasPrefix:@"stand"] || [standup.identifier hasPrefix:@"deck"]) [self hit:rules kind:PBEventStandup element:(NSInteger)i magnitude:0.1f];
    }];
    XCTAssertFalse(rules.multiballActive, @"the drops are still up");
    for (NSUInteger i = 0; i < world.table.dropTargets.count; i++) [self hit:rules kind:PBEventDropTarget element:(NSInteger)i magnitude:1];
    XCTAssertTrue(rules.multiballActive);
}

- (void)testABallTheSearchCannotFreeIsServedAgain {
    NSMutableDictionary *json = [self tableJSON:@"features"];
    // A closed box around the ball: no shove can get it out.
    json[@"walls"] = [json[@"walls"] arrayByAddingObject:@{ @"id": @"box", @"style": @"none", @"radius": @0.006, @"height": @0.05, @"closed": @YES,
        @"points": @[ @[ @0.6, @0.6 ], @[ @0.7, @0.6 ], @[ @0.7, @0.7 ], @[ @0.6, @0.7 ] ] }];
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] error:NULL];
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger ball = [world spawnBallAtPlunger];
    [world placeBall:ball at:simd_make_float2(0.65, 0.65) velocity:simd_make_float2(0, 0)];
    for (int i = 0; i < 60 * 15; i++) [world advanceBy:1.0 / 60.0];
    XCTAssertGreaterThan(world.balls[ball].position.x, 0.9, @"it must end up back in the shooter lane");
}

- (void)testGeneratedColumnIsAnActualPlayfieldCollider {
    NSMutableDictionary *json = [self tableJSON:@"features"];
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
    NSMutableDictionary *json = [self tableJSON:@"features"];
    NSMutableDictionary *lamp = json[@"lamps"][0], *bumper = json[@"bumpers"][0];
    lamp[@"x"] = bumper[@"x"];
    lamp[@"y"] = bumper[@"y"];
    XCTAssertTrue([self issues:[self issuesForJSON:json] contain:lamp[@"id"] and:bumper[@"id"] kind:PBLayoutIssueOverlap]);
}

- (void)testValidatorFindsARampOverABumper {
    NSMutableDictionary *json = [self tableJSON:@"features"];
    NSMutableDictionary *ramp = json[@"ramps"][0], *bumper = json[@"bumpers"][0];
    NSArray *point = ramp[@"points"][3];
    bumper[@"x"] = point[0];
    bumper[@"y"] = point[1];
    XCTAssertTrue([self issues:[self issuesForJSON:json] contain:ramp[@"id"] and:bumper[@"id"] kind:PBLayoutIssueOverlap]);
}

- (void)testValidatorFindsWallsCrossing {
    NSMutableDictionary *json = [self tableJSON:@"features"];
    [json[@"walls"] addObject:@{ @"id": @"crossing", @"style": @"wall", @"height": @0.05, @"radius": @0.006,
                                 @"points": @[ @[ @0.03, @1.32 ], @[ @0.3, @1.32 ] ] }];
    NSArray *issues = [self issuesForJSON:json];
    XCTAssertTrue([self issues:issues contain:@"crossing" and:@"guideOrbitL" kind:PBLayoutIssueOverlap] ||
                  [self issues:issues contain:@"crossing" and:@"magnet" kind:PBLayoutIssueOverlap], @"%@", issues);
}

- (void)testValidatorFindsAGapTooNarrowForTheBall {
    NSMutableDictionary *json = [self tableJSON:@"features"];
    NSMutableDictionary *a = json[@"bumpers"][0], *b = json[@"bumpers"][1];
    b[@"x"] = @([a[@"x"] floatValue] + [a[@"r"] floatValue] * 2.0f * 1.14f + 0.02f);
    b[@"y"] = a[@"y"];
    XCTAssertTrue([self issues:[self issuesForJSON:json] contain:a[@"id"] and:b[@"id"] kind:PBLayoutIssueNarrowGap]);
}

- (void)testValidatorFindsDecorOnTheApron {
    NSMutableDictionary *json = [self tableJSON:@"features"];
    json[@"decor"] = [@[ @{ @"id": @"sunken", @"model": @"gear", @"x": @0.5, @"y": @0.0, @"size": @0.02 } ] mutableCopy];
    BOOL found = NO;
    for (PBLayoutIssue *issue in [self issuesForJSON:json]) {
        if (issue.kind == PBLayoutIssueOutOfBounds && [issue.first isEqualToString:@"sunken"]) found = YES;
    }
    XCTAssertTrue(found);
}

// Footprints are only honest if they cover the models actually drawn.
- (void)testFootprintsCoverTheCompiledModels {
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
            NSString *model = ramp.model;
            [models addObject:model];
            XCTAssertLessThanOrEqual([assets[model][@"triangles"] integerValue], 6000,
                                     @"%@ exceeds the complete ramp triangle budget", model);
        }
        for (NSString *part in @[ @"flipper", @"walls", @"plastics" ]) [models addObject:[@"common-" stringByAppendingString:part]];
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
    XCTAssertGreaterThan(top, table.size.y - 0.1f, @"ball should climb to the arch");
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
    // Up the middle it may meet a centred scoop or a target first, which is reaching the playfield too.
    XCTAssertTrue(top > 0.85f || world.balls[index].state != PBBallFree, @"%@: a full flip should reach the upper playfield, reached %.3f", table.identifier, top);
}

// A table's script says what a cue does; without one, flashers and the like stay quiet.
- (void)testTheScriptRunsActionsOnCues {
    NSMutableDictionary *json = [self tableJSON:@"features"];
    json[@"rules"][@"script"] = @[ @{ @"cue": @"ramp", @"actions": @[ @"flash:flashTR", @"playfieldX" ] }, @{ @"cue": @"sling", @"actions": @[ @"flash:flashTL" ] } ];
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] error:NULL];
    PBStatsObserver *stats = [PBStatsObserver new];
    PBGame *game = [[PBGame alloc] initWithTable:table highScore:0];
    [game addObserver:stats];
    [game requestNewGame]; [game update:1.0 / 60.0];
    PBEvent ramp = { .kind = PBEventRampComplete, .element = 0 }, sling = { .kind = PBEventSling, .element = 0 }, bumper = { .kind = PBEventBumper, .element = 0 };
    [game.rules handleEvent:&bumper];
    [game update:1.0 / 60.0];
    XCTAssertEqual([stats.hits countForObject:@"flash:flashTL"], 0u, @"no cue for bumpers");
    [game.rules handleEvent:&ramp];
    int64_t before = game.rules.score;
    [game.rules handleEvent:&sling];
    [game update:1.0 / 60.0];
    XCTAssertEqual([stats.hits countForObject:@"flash:flashTR"], 1u);
    XCTAssertEqual([stats.hits countForObject:@"flash:flashTL"], 1u);
    XCTAssertEqual(game.rules.score - before, 2 * [table.rules scoreFor:@"sling"], @"any group action works from a cue: the ramp doubled the playfield");
}

// A saved ball comes back to the plunger and waits there: launching it is the player's job.
- (void)testASavedBallWaitsAtThePlungerForThePlayer {
    PBGame *game = [[PBGame alloc] initWithTable:[self loadTable:@"aurora"] highScore:0];
    [game requestNewGame]; [game update:1.0 / 60.0];
    [game setRightPressed:YES]; for (int i = 0; i < 60; i++) [game update:1.0 / 60.0];
    [game setRightPressed:NO]; for (int i = 0; i < 30; i++) [game update:1.0 / 60.0];
    XCTAssertFalse(game.world.isBallOnPlunger, @"the launch left the lane");
    for (NSInteger i = 0; i < game.world.ballCapacity; i++) if (game.world.balls[i].state != PBBallInactive) [game.world removeBall:i];
    PBEvent drain = { .kind = PBEventDrain };
    [game.rules handleEvent:&drain];
    for (int i = 0; i < 60 * 4; i++) [game update:1.0 / 60.0];
    XCTAssertEqual(game.rules.ballNumber, 1, @"drained inside the ball save, so the same ball goes on");
    XCTAssertEqual(game.world.activeBallCount, 1);
    XCTAssertTrue(game.world.isBallOnPlunger, @"it must sit at the plunger until the player launches it");
}

// Arming it takes both left targets and then a left outlane ball, too rare to count on in autoplay.
- (void)testArmedKickbackSavesALeftOutlaneBall {
    PBTableDefinition *table = [self loadTable:@"features"];
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
    NSMutableArray *mustHappen = [@[ @"sling", @"fanfare:gameOver" ] mutableCopy];
    if (table.bumpers.count) [mustHappen addObject:@"bumper"];
    if (table.dropTargets.count) [mustHappen addObject:@"drop"];
    if (table.spinners.count) [mustHappen addObject:@"spinner"];
    if (table.saucers.count) [mustHappen addObject:@"saucer"];
    if (table.magnets.count) [mustHappen addObject:@"magnet"];
    if (table.rules.locksForMultiball && table.saucers.count) [mustHappen addObject:@"fanfare:multiball"];
    if (table.ramps.count) [mustHappen addObjectsFromArray:@[ @"rampEnter", @"rampComplete" ]];
    for (PBRampDef *ramp in table.ramps) [mustHappen addObject:ramp.identifier];
    for (PBSpotDef *rollover in table.rollovers) [mustHappen addObject:rollover.identifier];
    for (PBEdgeDef *standup in table.standups) [mustHappen addObject:standup.identifier];
    // Every device of these kinds, by id, not just one of its kind.
    NSDictionary *byKind = @{ @"bumper": table.bumpers, @"sling": table.slingshots, @"drop": table.dropTargets, @"spinner": table.spinners,
                              @"saucer": table.saucers, @"magnet": table.magnets, @"gate": table.gates };
    for (NSString *kind in byKind) for (PBElementDef *element in byKind[kind]) [mustHappen addObject:[NSString stringWithFormat:@"%@:%@", kind, element.identifier]];

    // Autopilot play is chaotic: any layout change reshuffles a run, so a rare feature may come late.
    // 25 simulated minutes for the stats, then up to 75 in all for whatever hasn't happened yet.
    int64_t bestScore = 0;
    BOOL (^allHappened)(void) = ^BOOL {
        for (NSString *key in mustHappen) if (![stats.hits countForObject:key]) return NO;
        return YES;
    };
    for (int i = 0; i < 60 * 60 * 75; i++) {
        if (i >= 60 * 60 * 25 && i % 60 == 0 && allHappened()) break;
        [game update:1.0 / 60.0];
        bestScore = MAX(bestScore, game.rules.score);
    }

    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *key in [stats.hits.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        [lines addObject:[NSString stringWithFormat:@"%@=%lu", key, (unsigned long)[stats.hits countForObject:key]]];
    }
    NSLog(@"STATS %@ best=%lld %@", table.identifier, bestScore, [lines componentsJoinedByString:@" "]);

    for (NSString *key in mustHappen) XCTAssertGreaterThan([stats.hits countForObject:key], 0u, @"%@: %@ never happened", table.identifier, key);
    // A bare board scores only from its slingshots, lanes and spinner.
    BOOL bare = !(table.bumpers.count || table.ramps.count || table.dropTargets.count || table.standups.count || table.saucers.count);
    XCTAssertGreaterThan(bestScore, bare ? 5000 : 50000);
    NSUInteger drains = [stats.hits countForObject:@"drain"];
    NSUInteger stuck = [stats.hits countForObject:@"stuck"];
    XCTAssertLessThan(stuck, MAX(drains, 1u), @"ball search should be rare; a high count means a trap in the layout");
}

@end

