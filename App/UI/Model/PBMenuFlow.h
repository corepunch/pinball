#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PBMenuScreen) {
    PBMenuHome, PBMenuPlaying, PBMenuPaused, PBMenuSettings, PBMenuHelp,
    PBMenuResults, PBMenuConfirmHome, PBMenuConfirmRestart, PBMenuLevels, PBMenuLevelIntro,
};

typedef NS_ENUM(NSInteger, PBUIAction) {
    PBUIPlay, PBUIPause, PBUIResume, PBUIRestart, PBUIHome, PBUIConfirm,
    PBUICancel, PBUIBack, PBUISettings, PBUIHelp, PBUILeaderboard,
    PBUINextSkin, PBUISound, PBUIHaptics, PBUILevels, PBUISelectLevel, PBUINextLevel,
    PBUIPreviousPage, PBUINextPage,
};

typedef NS_ENUM(NSInteger, PBMenuCommand) { PBMenuNoCommand, PBMenuStartGame, PBMenuAbandonGame };

/// Navigation policy is separate from SpriteKit and the simulation.
@interface PBMenuFlow : NSObject
@property (nonatomic, readonly) PBMenuScreen screen;
@property (nonatomic, readonly) BOOL hasActiveGame;
/// Play opens the level map, rather than starting a single table straight away.
@property (nonatomic) BOOL usesLevelMap;
- (PBMenuCommand)performAction:(PBUIAction)action;
- (void)gameDidFinish;
@end
