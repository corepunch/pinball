//
//  PBGameController.h
//  Shared between iOS and macOS, like AAPLGameViewController's common code in Apple's
//  Fox sample. It owns the game and the scene, and runs the frame loop through
//  SCNSceneRendererDelegate. Platform hosts only create a view and forward input.
//

#import <SceneKit/SceneKit.h>
#import "PBGame.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBGameController : NSObject <SCNSceneRendererDelegate>

@property (nonatomic, strong, readonly) PBGame *game;

- (instancetype)initWithView:(SCNView *)view;
/// Call whenever the view's size changes.
- (void)viewDidResize;
- (void)selectNextSkin;
/// Device attitude relative to the player's neutral grip; safe from any thread.
- (void)setLightingAttitude:(simd_quatf)attitude;

@end

NS_ASSUME_NONNULL_END
