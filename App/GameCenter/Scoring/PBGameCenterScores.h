#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Player-scoped, persistent best-score outbox. All methods run on the main thread.
@interface PBGameCenterScores : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (void)beginGameForPlayer:(nullable NSString *)playerID;
/// Invalidates a live run if authentication is lost or the player changes.
- (void)playerDidChange:(nullable NSString *)playerID;
/// Only scores earned by the same signed-in player from start to finish qualify.
- (void)finishGameWithScore:(int64_t)score leaderboardID:(nullable NSString *)leaderboardID
                  playerID:(nullable NSString *)playerID;
- (NSDictionary<NSString *, NSNumber *> *)pendingScoresForPlayer:(NSString *)playerID;
/// Acknowledging an older in-flight score must preserve a newer personal best.
- (void)acknowledgeScore:(int64_t)score leaderboardID:(NSString *)leaderboardID playerID:(NSString *)playerID;
@end

NS_ASSUME_NONNULL_END
