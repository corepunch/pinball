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
    static NSString *const names[] = { @"bumper", @"sling", @"drop", @"standup", @"rollover", @"spinner", @"saucer", @"saucerEject",
        @"rampEnter", @"rampComplete", @"kickback", @"magnet", @"drain", @"flipUp", @"flipDown", @"wall", @"plunge", @"gate", @"stuck" };
    [self.hits addObject:names[event->kind]];
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
    json[@"decor"] = [@[ @{ @"id": @"sunken", @"model": @"gear", @"x": @0.5, @"y": @0.1, @"size": @0.02 } ] mutableCopy];
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
    // A missing model would otherwise just leave a hole in the table.
    PBTableDefinition *table = [self loadTable:@"aurora"];
    for (PBDecorDef *decor in table.decor) XCTAssertNotNil(assets[decor.model], @"%@", decor.model);
    for (PBRampDef *ramp in table.ramps) {
        NSString *model = [NSString stringWithFormat:@"%@-%@", table.identifier, ramp.identifier];
        XCTAssertNotNil(assets[model], @"%@", model);
    }
}

- (void)testBallStaysInsideTheTable {
    PBTableDefinition *table = [self loadTable:@"aurora"];
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
    PBTableDefinition *table = [self loadTable:@"aurora"];
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
    XCTAssertGreaterThan(top, 1.8f, @"ball should climb to the arch");
    XCTAssertLessThan(leftmost, 0.8f, @"ball should clear the one-way gate into the playfield");
}

- (void)testShortPlungeRollsBackToThePlunger {
    PBTableDefinition *table = [self loadTable:@"aurora"];
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    [world spawnBallAtPlunger];
    [world setPlungerPulled:YES];
    for (int i = 0; i < 12; i++) [world advanceBy:1.0 / 60.0];
    [world setPlungerPulled:NO];
    for (int i = 0; i < 60 * 3; i++) [world advanceBy:1.0 / 60.0];
    XCTAssertTrue(world.isBallOnPlunger);
}

- (void)testBallPassesBetweenRestingFlippers {
    PBTableDefinition *table = [self loadTable:@"aurora"];
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger index = [world spawnBallAtPlunger];
    [world placeBall:index at:simd_make_float2(0.4775f, 0.45f) velocity:0];
    __block BOOL drained = NO;
    for (int i = 0; i < 60 * 3 && !drained; i++) {
        [world advanceBy:1.0 / 60.0];
        [world drainEvents:^(const PBEvent *event) { if (event->kind == PBEventDrain) drained = YES; }];
    }
    XCTAssertTrue(drained, @"a ball straight down the middle must drain, not wedge");
}

- (void)testFlipperSendsBallUpTheTable {
    PBTableDefinition *table = [self loadTable:@"aurora"];
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger index = [world spawnBallAtPlunger];
    [world placeBall:index at:simd_make_float2(0.39f, 0.345f) velocity:0];
    for (int i = 0; i < 6; i++) [world advanceBy:1.0 / 60.0];
    [world setFlipperGroupLeft:YES pressed:YES];
    float top = 0;
    for (int i = 0; i < 60; i++) { [world advanceBy:1.0 / 60.0]; top = MAX(top, world.balls[index].position.y); }
    XCTAssertGreaterThan(top, 1.1f, @"a full flip should reach the upper playfield");
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
    XCTAssertGreaterThan(top, 0.8f, @"the kick should clear the outlane");
}

- (void)testAllFeaturesAreReachableInPlay {
    PBTableDefinition *table = [self loadTable:@"aurora"];
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
    NSLog(@"STATS best=%lld %@", bestScore, [lines componentsJoinedByString:@" "]);

    NSArray *mustHappen = @[ @"bumper", @"sling", @"drop", @"standup", @"spinner", @"saucer", @"rampEnter", @"rampComplete", @"rampL", @"rampR",
                             @"laneA", @"laneB", @"laneC", @"orbitR", @"inlaneLeft", @"inlaneRight", @"outlaneLeft", @"outlaneRight",
                             @"standL1", @"standR1", @"captiveTarget", @"magnet", @"fanfare:multiball", @"fanfare:gameOver" ];
    for (NSString *key in mustHappen) XCTAssertGreaterThan([stats.hits countForObject:key], 0u, @"%@ never happened", key);
    XCTAssertGreaterThan(bestScore, 50000);
    NSUInteger drains = [stats.hits countForObject:@"drain"];
    NSUInteger stuck = [stats.hits countForObject:@"stuck"];
    XCTAssertLessThan(stuck, MAX(drains, 1u), @"ball search should be rare; a high count means a trap in the layout");
}

@end
