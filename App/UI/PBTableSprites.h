#import <SpriteKit/SpriteKit.h>
#import "PBGame.h"

NS_ASSUME_NONNULL_BEGIN
/// Shipping table renderer. Textured quads consume the same definitions and live physics as the tests.
@interface PBTableSprites : SKNode
- (instancetype)initWithTable:(PBTableDefinition *)table;
- (void)layoutForViewSize:(CGSize)size topInset:(CGFloat)top bottomInset:(CGFloat)bottom;
- (void)syncWithGame:(PBGame *)game;
/// Apply before attachment, or through the scene update queue.
- (void)setPlayfieldColor:(SKColor *)color;
@end
NS_ASSUME_NONNULL_END
