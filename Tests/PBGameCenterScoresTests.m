#import <XCTest/XCTest.h>
#import "PBGameCenterScores.h"

@interface PBGameCenterScoresTests : XCTestCase
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, copy) NSString *suite;
@property (nonatomic, strong) PBGameCenterScores *scores;
@end

@implementation PBGameCenterScoresTests

- (void)setUp {
    [super setUp];
    self.suite = [@"PBGameCenterTests." stringByAppendingString:NSUUID.UUID.UUIDString];
    self.defaults = [[NSUserDefaults alloc] initWithSuiteName:self.suite];
    self.scores = [[PBGameCenterScores alloc] initWithDefaults:self.defaults];
}

- (void)tearDown {
    [self.defaults removePersistentDomainForName:self.suite];
    [super tearDown];
}

- (void)testFailedUploadSurvivesRestartAndKeepsOnlyBestScorePerTable {
    [self.scores beginGameForPlayer:@"alice"];
    [self.scores finishGameWithScore:12000 leaderboardID:@"aurora" playerID:@"alice"];
    [self.scores beginGameForPlayer:@"alice"];
    [self.scores finishGameWithScore:5000 leaderboardID:@"aurora" playerID:@"alice"];
    [self.scores beginGameForPlayer:@"alice"];
    [self.scores finishGameWithScore:9000 leaderboardID:@"other" playerID:@"alice"];
    PBGameCenterScores *reopened = [[PBGameCenterScores alloc] initWithDefaults:self.defaults];
    XCTAssertEqualObjects([reopened pendingScoresForPlayer:@"alice"], (@{@"aurora": @12000, @"other": @9000}));
}

- (void)testAccountSwitchNeverAttributesAnotherPlayersGame {
    [self.scores beginGameForPlayer:@"alice"];
    [self.scores finishGameWithScore:12000 leaderboardID:@"aurora" playerID:@"bob"];
    XCTAssertEqual([self.scores pendingScoresForPlayer:@"alice"].count, 0u);
    XCTAssertEqual([self.scores pendingScoresForPlayer:@"bob"].count, 0u);
    [self.scores beginGameForPlayer:nil];
    [self.scores finishGameWithScore:12000 leaderboardID:@"aurora" playerID:@"bob"];
    XCTAssertEqual([self.scores pendingScoresForPlayer:@"bob"].count, 0u);
    [self.scores beginGameForPlayer:@"alice"];
    [self.scores finishGameWithScore:12000 leaderboardID:@"aurora" playerID:nil];
    XCTAssertEqual([self.scores pendingScoresForPlayer:@"alice"].count, 0u);
}

- (void)testAcknowledgmentDoesNotLoseANewerScoreOrAnotherPlayersScore {
    [self.scores beginGameForPlayer:@"alice"];
    [self.scores finishGameWithScore:12000 leaderboardID:@"aurora" playerID:@"alice"];
    [self.scores beginGameForPlayer:@"bob"];
    [self.scores finishGameWithScore:14000 leaderboardID:@"aurora" playerID:@"bob"];
    [self.scores beginGameForPlayer:@"alice"];
    [self.scores finishGameWithScore:18000 leaderboardID:@"aurora" playerID:@"alice"];
    [self.scores acknowledgeScore:12000 leaderboardID:@"aurora" playerID:@"alice"];
    XCTAssertEqualObjects([self.scores pendingScoresForPlayer:@"alice"][@"aurora"], @18000);
    [self.scores acknowledgeScore:18000 leaderboardID:@"aurora" playerID:@"alice"];
    XCTAssertEqual([self.scores pendingScoresForPlayer:@"alice"].count, 0u);
    XCTAssertEqualObjects([self.scores pendingScoresForPlayer:@"bob"][@"aurora"], @14000);
}

- (void)testUnconfiguredTableOrEmptyScoreCannotBeSubmitted {
    for (NSNumber *score in @[@0, @-1]) {
        [self.scores beginGameForPlayer:@"alice"];
        [self.scores finishGameWithScore:score.longLongValue leaderboardID:@"aurora" playerID:@"alice"];
    }
    [self.scores beginGameForPlayer:@"alice"];
    [self.scores finishGameWithScore:12000 leaderboardID:nil playerID:@"alice"];
    XCTAssertEqual([self.scores pendingScoresForPlayer:@"alice"].count, 0u);
    // A repeated end-of-game callback must not create a second eligible session.
    [self.scores finishGameWithScore:12000 leaderboardID:@"aurora" playerID:@"alice"];
    XCTAssertEqual([self.scores pendingScoresForPlayer:@"alice"].count, 0u);
}

@end
