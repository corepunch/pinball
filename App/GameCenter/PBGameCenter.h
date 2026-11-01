#import <Foundation/Foundation.h>
@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

/// GameKit stays outside the simulation. This service is main-thread-only.
@interface PBGameCenter : NSObject
@property (nonatomic) BOOL showsAccessPoint;
@property (nonatomic, copy, nullable) void (^presentationChanged)(BOOL presented);
- (instancetype)initWithBundle:(NSBundle *)bundle;
- (void)startWithViewController:(UIViewController *)viewController;
- (void)showLeaderboardForTable:(NSString *)tableIdentifier;
- (void)beginGame;
- (void)finishGameWithScore:(int64_t)score tableIdentifier:(NSString *)tableIdentifier;
- (void)retryPendingScores;
@end

NS_ASSUME_NONNULL_END
