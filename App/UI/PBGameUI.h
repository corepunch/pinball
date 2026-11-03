#import <SpriteKit/SpriteKit.h>
#import "PBMenuFlow.h"

NS_ASSUME_NONNULL_BEGIN
@class PBTableDefinition;

/// Explicit input forwarding keeps menu touches out of the flipper controls.
@interface PBGameUI : SKScene
/// Geometry is read only to align the 2D boundary with the world camera.
@property (nonatomic, strong, nullable) PBTableDefinition *tableDefinition;
@property (nonatomic, copy, nullable) void (^actionHandler)(PBUIAction action);
/// Told when a popup appears over the game, or the last one goes. Every screen but the game itself is one.
@property (nonatomic, copy, nullable) void (^popupHandler)(BOOL shown);
@property (nonatomic, copy) NSString *skinName;
@property (nonatomic, copy) NSString *tableName;
@property (nonatomic, strong) SKColor *messageColor;
@property (nonatomic) NSInteger bonusMultiplier;
/// With no level list, the menus show a single free-play table.
/// One entry per level: its stars, or -1 while locked.
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *levelStars;
@property (nonatomic) NSInteger totalStars;
@property (nonatomic) NSInteger currentLevel;
/// The level whose tile was last tapped.
@property (nonatomic, readonly) NSInteger selectedLevel;
@property (nonatomic, copy, nullable) NSString *levelName, *levelGoal;
@property (nonatomic, copy, nullable) NSString *levelGoalKind;
@property (nonatomic) int64_t levelTarget, levelProgress;
@property (nonatomic) int64_t levelTwoStarScore, levelThreeStarScore, levelBest;
@property (nonatomic) NSInteger resultStars;
@property (nonatomic) BOOL resultGoalMet, hasNextLevel;
@property (nonatomic) BOOL soundEnabled;
@property (nonatomic) BOOL hapticsEnabled;
@property (nonatomic) BOOL newRecord;
@property (nonatomic, readonly) PBMenuScreen screen;
- (instancetype)initWithBundle:(NSBundle *)bundle;
/// Set once SceneKit is drawing this overlay: changes then wait for -update: on its render thread.
@property (nonatomic) BOOL deferChanges;
- (void)applyChange:(dispatch_block_t)change;
- (BOOL)onRenderThread;
- (void)layoutForViewSize:(CGSize)size topInset:(CGFloat)top bottomInset:(CGFloat)bottom;
- (void)showScreen:(PBMenuScreen)screen;
/// Receives legacy game events; the compact gameplay HUD omits message text.
- (void)showMessage:(nullable NSString *)message;
/// Opens the map on the page holding this level, and makes it the one the goal screen describes.
- (void)showLevelPageForLevel:(NSInteger)index;
- (void)updateScore:(int64_t)score best:(int64_t)best ball:(NSInteger)ball
         ballCount:(NSInteger)ballCount;
/// A hit on the table: sparks at this view point and, with points, a score flying up from it.
- (void)showImpactAtPoint:(CGPoint)point color:(SKColor *)color sparks:(NSInteger)sparks points:(int64_t)points;
/// Points use view coordinates with a top-left origin.
- (BOOL)pointerBegan:(id)pointer atPoint:(CGPoint)point;
- (BOOL)pointerMoved:(id)pointer atPoint:(CGPoint)point;
- (BOOL)pointerEnded:(id)pointer atPoint:(CGPoint)point cancelled:(BOOL)cancelled;
- (void)cancelPointers;
@end

NS_ASSUME_NONNULL_END
