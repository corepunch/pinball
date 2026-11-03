#import <SpriteKit/SpriteKit.h>
#import "PBTableDefinition.h"

NS_ASSUME_NONNULL_BEGIN

/// Flat presentation over the 3D world. This node never captures gameplay input.
@interface PBGameHUD : SKNode
@property (nonatomic, strong, nullable) PBTableDefinition *table;
+ (void)registerFontsInBundle:(NSBundle *)bundle;
/// Shares the HUD's font/gradient, with a black outline for moving score awards.
+ (SKSpriteNode *)flyingScoreForPoints:(int64_t)points;
- (void)layoutForViewSize:(CGSize)size topInset:(CGFloat)top bottomInset:(CGFloat)bottom;
- (void)updateScore:(int64_t)score goal:(int64_t)goal progress:(int64_t)progress kind:(NSString *)kind;
@end

NS_ASSUME_NONNULL_END
