//
//  PBTableScene.h
//  The view of the game: builds the SceneKit graph from a table and a skin, then
//  mirrors the simulation onto it every frame. It only reads game state. It never
//  influences play, so the same PBGame runs headless in tests.
//

#import <SceneKit/SceneKit.h>
#import "PBGame.h"
#import "PBSkin.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBTableScene : NSObject <PBGameObserver>

@property (nonatomic, strong, readonly) SCNScene *scene;
@property (nonatomic, strong, readonly) SCNNode *cameraNode;

- (instancetype)initWithTable:(PBTableDefinition *)table skin:(PBSkin *)skin;

/// Fits the camera so the table fills the view, for this view's height/width ratio.
- (void)fitCameraToAspect:(CGFloat)heightOverWidth;

/// Call once per frame after the game has updated, on the render thread.
- (void)syncWithGame:(PBGame *)game elapsed:(double)elapsed;

@end

NS_ASSUME_NONNULL_END
