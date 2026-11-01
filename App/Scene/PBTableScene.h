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

/// Relative device attitude (x right, y screen-up, z out of screen). Render thread only.
/// Moves illumination/reflections while the camera, table and physics stay fixed.
- (void)updateLightingForAttitude:(simd_quatf)attitude elapsed:(double)elapsed;

/// Where a point on the table is, for effects drawn over the scene.
- (SCNVector3)worldPointAt:(simd_float2)position height:(float)height;
/// The colour a hit on this kind of part sparks in.
- (simd_float3)impactColorForEvent:(PBEventKind)kind;

@end

NS_ASSUME_NONNULL_END
