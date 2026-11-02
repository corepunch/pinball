//
//  PBLevelTests.m
//  The level catalog, its unlock and star rules, and whether its goals can actually be met.
//

#import <XCTest/XCTest.h>
#import "PBLevels.h"
#import "PBMenuFlow.h"

/// What one game scored and counted, for every kind of goal.
@interface PBGameTally : NSObject <PBGameObserver>
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *games;
@end

@implementation PBGameTally {
    NSCountedSet<NSString *> *_current;
}
- (instancetype)init {
    if ((self = [super init])) { _games = [NSMutableArray array]; _current = [NSCountedSet set]; }
    return self;
}
- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {
    if (event->kind == PBEventRampComplete) [_current addObject:@"ramps"];
    if (event->kind == PBEventBumper) [_current addObject:@"bumpers"];
    if (event->kind == PBEventDropTarget) [_current addObject:@"drops"];
    if (event->kind == PBEventSaucerCapture) [_current addObject:@"saucers"];
    if (event->kind == PBEventSpinner) [_current addObject:@"spinners"];
    if (event->kind == PBEventStandup) [_current addObject:@"standups"];
}
- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier {}
- (void)game:(PBGame *)game fanfare:(NSString *)name {
    if ([name isEqualToString:@"multiball"]) [_current addObject:@"multiballs"];
    if ([name isEqualToString:@"jackpot"]) [_current addObject:@"jackpots"];
    if ([name isEqualToString:@"wizard"]) [_current addObject:@"wizards"];
    if ([name isEqualToString:@"start"]) _current = [NSCountedSet set];
    if ([name isEqualToString:@"gameOver"]) {
        NSMutableDictionary *result = [@{ @"score": @(game.rules.score) } mutableCopy];
        for (NSString *key in _current) result[key] = @([_current countForObject:key]);
        [_games addObject:result];
    }
}
@end

@interface PBLevelTests : XCTestCase
@end

@implementation PBLevelTests {
    NSUserDefaults *_defaults;
    NSString *_suite;
}

- (void)setUp {
    _suite = NSUUID.UUID.UUIDString;
    _defaults = [[NSUserDefaults alloc] initWithSuiteName:_suite];
}

- (void)tearDown { [_defaults removePersistentDomainForName:_suite]; }

- (NSString *)gameData:(NSString *)relative {
    return [[[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
             stringByAppendingPathComponent:@"../GameData"] stringByAppendingPathComponent:relative];
}

- (PBLevelCatalog *)catalog:(NSArray *)levels {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{ @"levels": levels } options:0 error:NULL];
    return [[PBLevelCatalog alloc] initWithJSONData:data error:NULL];
}

- (NSDictionary *)levelWithID:(NSString *)identifier {
    return @{ @"id": identifier, @"name": @"Test", @"table": @"aurora", @"skin": @"orbital",
              @"goal": @"ramps", @"count": @3, @"stars": @[ @100, @200 ] };
}

- (PBLevelCatalog *)shippingCatalog {
    NSError *error;
    PBLevelCatalog *catalog = [[PBLevelCatalog alloc] initWithJSONData:[NSData dataWithContentsOfFile:[self gameData:@"Levels.json"]] error:&error];
    XCTAssertNotNil(catalog, @"%@", error);
    return catalog;
}

- (PBTableDefinition *)table:(NSString *)name {
    NSString *path = [self gameData:[NSString stringWithFormat:@"Tables/%@.json", name]];
    return [[PBTableDefinition alloc] initWithJSONData:[NSData dataWithContentsOfFile:path] error:NULL];
}

#pragma mark Catalog

- (void)testEveryLevelHasItsOwnTable {
    NSMutableSet *tables = [NSMutableSet set];
    for (PBLevelDef *level in [self shippingCatalog].levels) [tables addObject:level.table];
    XCTAssertGreaterThan([self shippingCatalog].levels.count, 0u);
    XCTAssertEqual(tables.count, [self shippingCatalog].levels.count);
}

- (void)testShippingLevelsUseTablesAndSkinsThatExist {
    NSFileManager *files = NSFileManager.defaultManager;
    for (PBLevelDef *level in [self shippingCatalog].levels) {
        NSString *table = [self gameData:[NSString stringWithFormat:@"Tables/%@.json", level.table]];
        NSString *skin = [self gameData:[NSString stringWithFormat:@"Skins/%@.json", level.skin]];
        XCTAssertTrue([files fileExistsAtPath:table], @"%@", level.identifier);
        XCTAssertTrue([files fileExistsAtPath:skin], @"%@", level.identifier);
    }
}

- (void)testCatalogRejectsBrokenLevels {
    XCTAssertNotNil([self catalog:@[ [self levelWithID:@"a"] ]]);
    XCTAssertNil([self catalog:@[]]);
    NSArray *duplicated = @[ [self levelWithID:@"a"], [self levelWithID:@"a"] ];
    XCTAssertNil([self catalog:duplicated], @"duplicate id");
    NSMutableDictionary *bad = [[self levelWithID:@"a"] mutableCopy];
    bad[@"goal"] = @"unicorns";
    XCTAssertNil([self catalog:@[ bad ]], @"unknown goal");
    bad = [[self levelWithID:@"a"] mutableCopy];
    bad[@"stars"] = @[ @200, @100 ];
    XCTAssertNil([self catalog:@[ bad ]], @"stars out of order");
    bad = [[self levelWithID:@"a"] mutableCopy];
    bad[@"goal"] = @"score";
    bad[@"count"] = @500;
    XCTAssertNil([self catalog:@[ bad ]], @"two stars must ask more than the goal");
}

- (void)testGoalTextAndStars {
    PBLevelDef *level = [self catalog:@[ [self levelWithID:@"a"] ]].levels[0];
    XCTAssertEqualObjects(level.goalText, @"3 RAMPS");
    XCTAssertEqual([level starsForScore:1000 goalMet:NO], 0, @"no goal, no stars, whatever the score");
    XCTAssertEqual([level starsForScore:0 goalMet:YES], 1);
    XCTAssertEqual([level starsForScore:100 goalMet:YES], 2);
    XCTAssertEqual([level starsForScore:200 goalMet:YES], 3);
    NSMutableDictionary *score = [[self levelWithID:@"b"] mutableCopy];
    score[@"goal"] = @"score"; score[@"count"] = @50; score[@"stars"] = @[ @60000, @70000 ];
    score[@"count"] = @50000;
    XCTAssertEqualObjects([self catalog:@[ score ]].levels[0].goalText, @"SCORE 50,000");
}

#pragma mark Progress

- (void)testLevelsUnlockInOrderAndProgressSurvivesRelaunch {
    PBLevelCatalog *catalog = [self catalog:@[ [self levelWithID:@"a"], [self levelWithID:@"b"], [self levelWithID:@"c"] ]];
    PBLevelProgress *progress = [[PBLevelProgress alloc] initWithDefaults:_defaults];
    XCTAssertTrue([progress isLevelUnlockedAtIndex:0 inCatalog:catalog]);
    XCTAssertFalse([progress isLevelUnlockedAtIndex:1 inCatalog:catalog]);
    XCTAssertEqual([progress currentLevelIndexInCatalog:catalog], 0);

    [progress recordStars:0 score:50 forLevel:catalog.levels[0]];
    XCTAssertFalse([progress isLevelUnlockedAtIndex:1 inCatalog:catalog], @"a failed attempt opens nothing");

    [progress recordStars:2 score:150 forLevel:catalog.levels[0]];
    XCTAssertTrue([progress isLevelUnlockedAtIndex:1 inCatalog:catalog]);
    XCTAssertFalse([progress isLevelUnlockedAtIndex:2 inCatalog:catalog]);
    XCTAssertEqual([progress currentLevelIndexInCatalog:catalog], 1);
    XCTAssertFalse([progress isLevelUnlockedAtIndex:3 inCatalog:catalog], @"past the end");

    PBLevelProgress *relaunched = [[PBLevelProgress alloc] initWithDefaults:_defaults];
    XCTAssertEqual([relaunched starsForLevel:catalog.levels[0]], 2);
    XCTAssertEqual([relaunched bestScoreForLevel:catalog.levels[0]], 150);
    XCTAssertEqual(relaunched.totalStars, 2);
}

- (void)testAWorseReplayNeverLosesStarsOrBest {
    PBLevelDef *level = [self catalog:@[ [self levelWithID:@"a"] ]].levels[0];
    PBLevelProgress *progress = [[PBLevelProgress alloc] initWithDefaults:_defaults];
    [progress recordStars:3 score:900 forLevel:level];
    [progress recordStars:1 score:100 forLevel:level];
    XCTAssertEqual([progress starsForLevel:level], 3);
    XCTAssertEqual([progress bestScoreForLevel:level], 900);
}

- (void)testAfterEveryLevelHasAStarTheLastIsCurrent {
    PBLevelCatalog *catalog = [self catalog:@[ [self levelWithID:@"a"], [self levelWithID:@"b"] ]];
    PBLevelProgress *progress = [[PBLevelProgress alloc] initWithDefaults:_defaults];
    for (PBLevelDef *level in catalog.levels) [progress recordStars:1 score:1 forLevel:level];
    XCTAssertEqual([progress currentLevelIndexInCatalog:catalog], 1);
}

#pragma mark Session

- (void)testSessionCountsItsGoalAndResetsEachGame {
    PBLevelDef *level = [self catalog:@[ [self levelWithID:@"a"] ]].levels[0];
    PBLevelSession *session = [[PBLevelSession alloc] initWithLevel:level];
    PBGame *game = [[PBGame alloc] initWithTable:[self table:@"aurora"] highScore:0];
    PBEvent ramp = { .kind = PBEventRampComplete }, bumper = { .kind = PBEventBumper };
    [session game:game fanfare:@"start"];
    [session game:game didReceiveEvent:&bumper];
    XCTAssertEqual(session.progress, 0, @"other events do not count");
    for (int i = 0; i < 2; i++) [session game:game didReceiveEvent:&ramp];
    XCTAssertEqual(session.progress, 2);
    XCTAssertFalse(session.goalMet);
    [session game:game didReceiveEvent:&ramp];
    XCTAssertTrue(session.goalMet);
    [session game:game fanfare:@"start"];
    XCTAssertEqual(session.progress, 0);
    XCTAssertFalse(session.goalMet);
}

- (void)testARealGameAnnouncesItsGoalOnTheDisplay {
    PBLevelDef *level = [self catalog:@[ [self levelWithID:@"a"] ]].levels[0];
    PBLevelSession *session = [[PBLevelSession alloc] initWithLevel:level];
    PBGame *game = [[PBGame alloc] initWithTable:[self table:@"aurora"] highScore:0];
    [game addObserver:session];
    [game requestNewGame]; [game update:1.0 / 60.0]; [game update:1.0 / 60.0];
    XCTAssertEqualObjects(game.rules.displayTop, level.goalText);
    for (int i = 0; i < 60 * 8; i++) [game update:1.0 / 60.0];
    XCTAssertNotEqualObjects(game.rules.displayTop, level.goalText, @"it gives the display back");
}

- (void)testScoreGoalIncludesEndOfGameBonus {
    NSMutableDictionary *item = [[self levelWithID:@"a"] mutableCopy];
    item[@"goal"] = @"score"; item[@"count"] = @1000; item[@"stars"] = @[ @2000, @3000 ];
    PBLevelSession *session = [[PBLevelSession alloc] initWithLevel:[self catalog:@[ item ]].levels[0]];
    PBGame *game = [[PBGame alloc] initWithTable:[self table:@"aurora"] highScore:0];
    [game requestNewGame]; [game update:1.0 / 60.0];
    [session game:game fanfare:@"start"];
    PBEvent hit = { .kind = PBEventBumper };
    [game.rules handleEvent:&hit];
    [session game:game fanfare:@"gameOver"];
    XCTAssertEqual(session.progress, game.rules.score);
    XCTAssertTrue(session.goalMet, @"one bumper scores 1000");
}

#pragma mark Menu flow

- (void)testPlayOpensTheMapAndALevelStartsFromItsGoalScreen {
    PBMenuFlow *flow = [PBMenuFlow new];
    flow.usesLevelMap = YES;
    XCTAssertEqual([flow performAction:PBUIPlay], PBMenuNoCommand);
    XCTAssertEqual(flow.screen, PBMenuLevels);
    XCTAssertEqual([flow performAction:PBUISelectLevel], PBMenuNoCommand);
    XCTAssertEqual(flow.screen, PBMenuLevelIntro);
    [flow performAction:PBUIBack];
    XCTAssertEqual(flow.screen, PBMenuLevels);
    [flow performAction:PBUISelectLevel];
    XCTAssertEqual([flow performAction:PBUIPlay], PBMenuStartGame);
    XCTAssertEqual(flow.screen, PBMenuPlaying);
    XCTAssertTrue(flow.hasActiveGame);
    [flow gameDidFinish];
    XCTAssertEqual([flow performAction:PBUINextLevel], PBMenuNoCommand);
    XCTAssertEqual(flow.screen, PBMenuLevelIntro);
}

- (void)testResultsRetryOrReturnToTheMapAndEndingAGameLeavesToTheMap {
    PBMenuFlow *flow = [PBMenuFlow new];
    flow.usesLevelMap = YES;
    [flow performAction:PBUIPlay]; [flow performAction:PBUISelectLevel]; [flow performAction:PBUIPlay];
    [flow gameDidFinish];
    XCTAssertEqual([flow performAction:PBUIPlay], PBMenuStartGame, @"retry");
    [flow gameDidFinish];
    [flow performAction:PBUILevels];
    XCTAssertEqual(flow.screen, PBMenuLevels);
    [flow performAction:PBUIBack];
    XCTAssertEqual(flow.screen, PBMenuHome);
    [flow performAction:PBUIPlay]; [flow performAction:PBUISelectLevel]; [flow performAction:PBUIPlay];
    [flow performAction:PBUIPause]; [flow performAction:PBUIHome];
    XCTAssertEqual([flow performAction:PBUIConfirm], PBMenuAbandonGame);
    XCTAssertEqual(flow.screen, PBMenuLevels);
}

#pragma mark Balance

/// Autopilot games, per table. It is a mediocre player, which makes it a fair bar for a goal.
- (NSDictionary<NSString *, NSArray *> *)simulatedGamesForTables:(NSSet<NSString *> *)tables {
    NSMutableDictionary *results = [NSMutableDictionary dictionary];
    for (NSString *name in tables) {
        PBGameTally *tally = [PBGameTally new];
        PBGame *game = [[PBGame alloc] initWithTable:[self table:name] highScore:0];
        [game addObserver:tally];
        game.autopilot = YES;
        for (int i = 0; i < 60 * 60 * 40 && tally.games.count < 40; i++) [game update:1.0 / 60.0];
        results[name] = tally.games;
    }
    return results;
}

- (void)testEveryGoalIsReachableAndThreeStarsAreNotAutomatic {
    PBLevelCatalog *catalog = [self shippingCatalog];
    NSDictionary *games = [self simulatedGamesForTables:[NSSet setWithArray:[catalog.levels valueForKey:@"table"]]];
    for (NSString *name in games) {
        NSArray *list = games[name];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *key in @[ @"score", @"bumpers", @"ramps", @"drops", @"saucers", @"spinners", @"multiballs", @"jackpots" ]) {
            NSArray *values = [[list valueForKey:key] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
                return [a isKindOfClass:NSNull.class] ? ([b isKindOfClass:NSNull.class] ? NSOrderedSame : NSOrderedAscending)
                     : [b isKindOfClass:NSNull.class] ? NSOrderedDescending : [a compare:b];
            }];
            NSUInteger n = values.count;
            [lines addObject:[NSString stringWithFormat:@"%@ p25=%@ p50=%@ p75=%@ p90=%@", key, values[n / 4], values[n / 2], values[n * 3 / 4], values[n * 9 / 10]]];
        }
        NSLog(@"BALANCE %@ games=%lu %@", name, (unsigned long)list.count, [lines componentsJoinedByString:@" | "]);
    }
    for (PBLevelDef *level in catalog.levels) {
        NSUInteger met = 0, three = 0;
        NSArray<NSDictionary *> *list = games[level.table];
        for (NSDictionary *result in list) {
            BOOL goal = [result[level.goal] longLongValue] >= level.goalCount;
            if (goal) met++;
            if ([level starsForScore:[result[@"score"] longLongValue] goalMet:goal] == 3) three++;
        }
        NSLog(@"BALANCE level %@ %@: goal %lu/%lu, three stars %lu", level.identifier, level.goalText, (unsigned long)met, (unsigned long)list.count, (unsigned long)three);
        XCTAssertGreaterThan(met, 0u, @"level %@: nobody ever reaches %@", level.identifier, level.goalText);
        XCTAssertLessThan(three, list.count, @"level %@: three stars come with every game", level.identifier);
    }
}

@end
