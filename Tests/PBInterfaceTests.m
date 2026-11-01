#import <XCTest/XCTest.h>
#import "PBMenuFlow.h"
#import "PBGame.h"

@interface PBInterfaceTests : XCTestCase
@end

@implementation PBInterfaceTests

- (void)testHomeRequiresAnExplicitPlayAction {
    PBMenuFlow *flow = [PBMenuFlow new];
    XCTAssertEqual(flow.screen, PBMenuHome);
    XCTAssertFalse(flow.hasActiveGame);
    XCTAssertEqual([flow performAction:PBUIResume], PBMenuNoCommand);
    XCTAssertEqual(flow.screen, PBMenuHome);
    XCTAssertEqual([flow performAction:PBUIPlay], PBMenuStartGame);
    XCTAssertTrue(flow.hasActiveGame);
    XCTAssertEqual(flow.screen, PBMenuPlaying);
}

- (void)testReturningFromSettingsKeepsAnActiveGamePaused {
    PBMenuFlow *flow = [PBMenuFlow new];
    [flow performAction:PBUIPlay];
    [flow performAction:PBUIPause];
    [flow performAction:PBUISettings];
    [flow performAction:PBUIBack];
    XCTAssertEqual(flow.screen, PBMenuPaused);
    XCTAssertTrue(flow.hasActiveGame);
    [flow performAction:PBUIResume];
    XCTAssertEqual(flow.screen, PBMenuPlaying);
}

- (void)testEndingAGameNeedsConfirmationAndCancelPreservesTheRun {
    PBMenuFlow *flow = [PBMenuFlow new];
    [flow performAction:PBUIPlay];
    [flow performAction:PBUIPause];
    XCTAssertEqual([flow performAction:PBUIHome], PBMenuNoCommand);
    XCTAssertEqual(flow.screen, PBMenuConfirmHome);
    XCTAssertTrue(flow.hasActiveGame);
    [flow performAction:PBUICancel];
    XCTAssertEqual(flow.screen, PBMenuPaused);
    [flow performAction:PBUIHome];
    XCTAssertEqual([flow performAction:PBUIConfirm], PBMenuAbandonGame);
    XCTAssertEqual(flow.screen, PBMenuHome);
    XCTAssertFalse(flow.hasActiveGame);
}

- (void)testRestartOnlyStartsAfterConfirmation {
    PBMenuFlow *flow = [PBMenuFlow new];
    [flow performAction:PBUIPlay];
    [flow performAction:PBUIPause];
    XCTAssertEqual([flow performAction:PBUIRestart], PBMenuNoCommand);
    XCTAssertEqual(flow.screen, PBMenuConfirmRestart);
    XCTAssertEqual([flow performAction:PBUIConfirm], PBMenuStartGame);
    XCTAssertTrue(flow.hasActiveGame);
    XCTAssertEqual(flow.screen, PBMenuPlaying);
}

- (void)testHelpReturnsToItsOriginAndResultsStayUntilPlayerChooses {
    PBMenuFlow *flow = [PBMenuFlow new];
    [flow performAction:PBUIHelp];
    [flow performAction:PBUIBack];
    XCTAssertEqual(flow.screen, PBMenuHome);
    [flow performAction:PBUIPlay];
    [flow gameDidFinish];
    XCTAssertEqual(flow.screen, PBMenuResults);
    XCTAssertFalse(flow.hasActiveGame);
    [flow performAction:PBUISettings];
    [flow performAction:PBUIBack];
    XCTAssertEqual(flow.screen, PBMenuResults);
    XCTAssertEqual([flow performAction:PBUIPlay], PBMenuStartGame);
}

- (void)testRestartWhileChargingClearsTheOldPlungerAndScore {
    NSString *path = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
                      stringByAppendingPathComponent:@"../GameData/Tables/aurora.json"];
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSData dataWithContentsOfFile:path] error:NULL];
    XCTAssertNotNil(table);
    PBGame *game = [[PBGame alloc] initWithTable:table highScore:123456];
    [game requestNewGame]; [game update:1.0 / 60.0];
    PBEvent hit = { .kind = PBEventBumper, .element = 0, .ball = 0 };
    [game.rules handleEvent:&hit];
    XCTAssertGreaterThan(game.rules.score, 0);
    [game setRightPressed:YES]; [game update:0.2];
    XCTAssertGreaterThan(game.world.plungerPull, 0);
    [game setRightPressed:NO]; [game requestNewGame]; [game update:1.0 / 60.0];
    XCTAssertEqual(game.rules.phase, PBGamePhasePlaying);
    XCTAssertEqual(game.rules.ballNumber, 1);
    XCTAssertEqual(game.rules.score, 0);
    XCTAssertEqual(game.rules.highScore, 123456);
    XCTAssertEqual(game.world.plungerPull, 0);
    XCTAssertTrue(game.world.isBallOnPlunger);
    XCTAssertEqual(game.world.activeBallCount, 1);
}

@end
