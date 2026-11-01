#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PBMenuScreen) {
    PBMenuHome, PBMenuPlaying, PBMenuPaused, PBMenuSettings, PBMenuHelp,
    PBMenuResults, PBMenuConfirmHome, PBMenuConfirmRestart,
};

typedef NS_ENUM(NSInteger, PBUIAction) {
    PBUIPlay, PBUIPause, PBUIResume, PBUIRestart, PBUIHome, PBUIConfirm,
    PBUICancel, PBUIBack, PBUISettings, PBUIHelp, PBUILeaderboard,
    PBUINextSkin, PBUISound, PBUIHaptics,
};

typedef NS_ENUM(NSInteger, PBMenuCommand) { PBMenuNoCommand, PBMenuStartGame, PBMenuAbandonGame };

/// Navigation policy is separate from SpriteKit and the simulation.
@interface PBMenuFlow : NSObject
@property (nonatomic, readonly) PBMenuScreen screen;
@property (nonatomic, readonly) BOOL hasActiveGame;
- (PBMenuCommand)performAction:(PBUIAction)action;
- (void)gameDidFinish;
@end
