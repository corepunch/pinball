// Compiled mesh kits with semantic materials rebound to the current skin.
#import <SceneKit/SceneKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface PBModelLibrary : NSObject
- (instancetype)initWithBundle:(NSBundle *)bundle kit:(NSString *)kit;
/// Returns an independent hierarchy/geometry copy; nil allows procedural fallback.
- (nullable SCNNode *)nodeNamed:(NSString *)name;
@end
NS_ASSUME_NONNULL_END
