//
//  PBGameController.h
//  Owns the game and scene, and runs the frame loop through
//  SCNSceneRendererDelegate. The iPhone view controller forwards input.
//

#import <SceneKit/SceneKit.h>
#import "PBGame.h"
#import "PBGameCenter.h"
#import "PBMenuFlow.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBGameController : NSObject <SCNSceneRendererDelegate>

@property (nonatomic, strong, readonly) PBGame *game;
@property (nonatomic, readonly, getter=isPaused) BOOL paused;
@property (nonatomic, readonly) BOOL hapticsEnabled;

- (instancetype)initWithView:(SCNView *)view;
/// The game is replaced when a level changes table, so observers register here to follow it.
- (void)addGameObserver:(id<PBGameObserver>)observer;
/// Call whenever the view's size changes.
- (void)viewDidResize;
- (void)selectNextSkin;
/// Called by the view controller once its window is visible. Skipped for autopilot.
- (void)startGameCenterWithViewController:(UIViewController *)viewController;
- (void)showLeaderboard;
- (void)setApplicationActive:(BOOL)active;
- (void)performUIAction:(PBUIAction)action;
/// The view controller forwards menu touches before considering flippers or plungers.
- (BOOL)pointerBegan:(id)pointer atPoint:(CGPoint)point;
- (BOOL)pointerMoved:(id)pointer atPoint:(CGPoint)point;
- (BOOL)pointerEnded:(id)pointer atPoint:(CGPoint)point cancelled:(BOOL)cancelled;
- (void)cancelUIPointers;
/// Device attitude relative to the player's neutral grip; safe from any thread.
- (void)setLightingAttitude:(simd_quatf)attitude;

@end

NS_ASSUME_NONNULL_END
