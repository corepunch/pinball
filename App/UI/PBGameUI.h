#import <SpriteKit/SpriteKit.h>
#import "PBMenuFlow.h"

NS_ASSUME_NONNULL_BEGIN

/// Explicit input forwarding keeps menu touches out of the flipper controls.
@interface PBGameUI : SKScene
@property (nonatomic, copy, nullable) void (^actionHandler)(PBUIAction action);
@property (nonatomic, copy) NSString *skinName;
@property (nonatomic) BOOL soundEnabled;
@property (nonatomic) BOOL hapticsEnabled;
@property (nonatomic) BOOL newRecord;
@property (nonatomic, readonly) PBMenuScreen screen;
- (instancetype)initWithBundle:(NSBundle *)bundle;
- (void)layoutForViewSize:(CGSize)size topInset:(CGFloat)top bottomInset:(CGFloat)bottom;
- (void)showScreen:(PBMenuScreen)screen;
- (void)updateScore:(int64_t)score best:(int64_t)best ball:(NSInteger)ball
         ballCount:(NSInteger)ballCount plungerReady:(BOOL)ready;
/// Points use view coordinates with a top-left origin.
- (BOOL)pointerBegan:(id)pointer atPoint:(CGPoint)point;
- (BOOL)pointerMoved:(id)pointer atPoint:(CGPoint)point;
- (BOOL)pointerEnded:(id)pointer atPoint:(CGPoint)point cancelled:(BOOL)cancelled;
- (void)cancelPointers;
@end

NS_ASSUME_NONNULL_END
