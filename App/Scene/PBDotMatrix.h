//
//  PBDotMatrix.h
//  A 128x32 dot-matrix display drawn with a built-in 5x7 font, so no font files ship
//  with a consistent appearance. The dots themselves are a shader on the plane.
//

#import <SceneKit/SceneKit.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface PBDotMatrix : NSObject

/// The plane node. Sized by the caller; its origin is the plane's centre.
@property (nonatomic, strong, readonly) SCNNode *node;

- (instancetype)initWithWidth:(float)width height:(float)height color:(simd_float3)color;
/// Redraws only if the text changed. A message is drawn double size and centred.
- (void)showTop:(NSString *)top bottom:(NSString *)bottom large:(BOOL)large;

@end

NS_ASSUME_NONNULL_END
