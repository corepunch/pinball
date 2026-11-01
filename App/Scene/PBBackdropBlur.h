#import <SceneKit/SceneKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Blurs what SceneKit draws behind a popup. The popups are in the view's SpriteKit overlay, drawn
/// after a technique, so they stay sharp: a UIVisualEffectView over the view would blur them as well.
@interface PBBackdropBlur : NSObject
/// Nil if the device can't build its shaders: popups then show over the sharp game.
+ (nullable SCNTechnique *)techniqueForDevice:(id<MTLDevice>)device;
@end

NS_ASSUME_NONNULL_END
