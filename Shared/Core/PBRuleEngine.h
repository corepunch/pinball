//
//  PBRuleEngine.h
//  The game of pinball on top of the physics: scoring, balls, modes, lamps.
//  Generic. What differs per table (scores, target groups, what completing them
//  does) comes from the "rules" block of the table JSON.
//

#import <Foundation/Foundation.h>
#import "PBPhysicsWorld.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PBGamePhase) {
    PBGamePhaseAttract,
    PBGamePhasePlaying,
    PBGamePhaseBonus,
    PBGamePhaseGameOver,
};

typedef NS_ENUM(uint8_t, PBLampMode) {
    PBLampOff,
    PBLampOn,
    PBLampBlink,
    PBLampFastBlink,
};

@class PBRuleEngine;

@protocol PBRuleEngineDelegate <NSObject>
/// Fire a flasher dome, by its table id.
- (void)ruleEngine:(PBRuleEngine *)engine flash:(NSString *)flasherIdentifier;
/// A notable moment, for sound: "multiball", "jackpot", "extraBall", "tilt", "gameOver", "start", "ballSave".
- (void)ruleEngine:(PBRuleEngine *)engine fanfare:(NSString *)name;
@end

@interface PBRuleEngine : NSObject

@property (nonatomic, weak, nullable) id<PBRuleEngineDelegate> delegate;
@property (nonatomic, readonly) PBGamePhase phase;
@property (nonatomic, readonly) int64_t score;
@property (nonatomic, readonly) int64_t highScore;
@property (nonatomic, readonly) NSInteger ballNumber;
@property (nonatomic, readonly) NSInteger bonusMultiplier;
@property (nonatomic, readonly) BOOL multiballActive;
@property (nonatomic, readonly) BOOL tilted;

/// Current text for the dot-matrix display.
@property (nonatomic, copy, readonly) NSString *displayTop;
@property (nonatomic, copy, readonly) NSString *displayBottom;
/// True while a transient message owns the display, so it can be drawn larger.
@property (nonatomic, readonly) BOOL displayIsMessage;

- (instancetype)initWithWorld:(PBPhysicsWorld *)world highScore:(int64_t)highScore;
- (void)startGame;
- (void)handleEvent:(const PBEvent *)event;
- (void)update:(double)dt;
- (void)nudged;
/// Lane-change: lit lamps in rotating groups shift with the flippers.
- (void)flipperPressedLeft:(BOOL)left;
- (PBLampMode)modeForLamp:(NSInteger)lampIndex;

@end

NS_ASSUME_NONNULL_END
