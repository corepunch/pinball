//
//  PBTableTests.m
//  Plays the real table headless. A layout mistake in the JSON (a gap too narrow,
//  a shot that can't be made, a flat spot that traps a ball) shows up here, not as
//  a bug report: this is the safety net for adding more tables.
//

#import <XCTest/XCTest.h>
#import "PBGame.h"

@interface PBStatsObserver : NSObject <PBGameObserver>
@property (nonatomic, strong) NSCountedSet<NSString *> *hits;
@end

@implementation PBStatsObserver
- (instancetype)init { if ((self = [super init])) _hits = [NSCountedSet set]; return self; }
- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {
    static NSString *const names[] = { @"bumper", @"sling", @"drop", @"standup", @"rollover", @"spinner", @"saucer", @"saucerEject",
        @"rampEnter", @"rampComplete", @"kickback", @"magnet", @"drain", @"flipUp", @"flipDown", @"wall", @"plunge", @"gate", @"stuck" };
    [self.hits addObject:names[event->kind]];
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
                      stringByAppendingFormat:@"/../Pinball/GameData/Tables/%@.json", name];
    NSError *error;
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSData dataWithContentsOfFile:path] error:&error];
    XCTAssertNotNil(table, @"%@", error);
    return table;
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

    NSArray *mustHappen = @[ @"bumper", @"sling", @"drop", @"standup", @"spinner", @"saucer", @"rampEnter", @"rampComplete",
                             @"laneA", @"laneB", @"laneC", @"orbitR", @"inlaneLeft", @"inlaneRight", @"outlaneLeft", @"outlaneRight",
                             @"standL1", @"standR1", @"captiveTarget", @"kickback", @"magnet", @"fanfare:multiball", @"fanfare:gameOver" ];
    for (NSString *key in mustHappen) XCTAssertGreaterThan([stats.hits countForObject:key], 0u, @"%@ never happened", key);
    XCTAssertGreaterThan(bestScore, 50000);
    NSUInteger drains = [stats.hits countForObject:@"drain"];
    NSUInteger stuck = [stats.hits countForObject:@"stuck"];
    XCTAssertLessThan(stuck, MAX(drains, 1u), @"ball search should be rare; a high count means a trap in the layout");
}

@end
