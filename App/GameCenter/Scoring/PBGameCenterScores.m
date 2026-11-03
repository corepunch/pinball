#import "PBGameCenterScores.h"

static NSString *const kPendingScoresKey = @"PBGameCenter.PendingScores.v1";

@implementation PBGameCenterScores {
    NSUserDefaults *_defaults;
    NSString *_sessionPlayerID;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) _defaults = defaults;
    return self;
}

- (void)beginGameForPlayer:(NSString *)playerID { _sessionPlayerID = [playerID copy]; }

- (void)playerDidChange:(NSString *)playerID {
    if (![_sessionPlayerID isEqualToString:playerID]) _sessionPlayerID = nil;
}

- (void)finishGameWithScore:(int64_t)score leaderboardID:(NSString *)leaderboardID playerID:(NSString *)playerID {
    BOOL eligible = _sessionPlayerID.length && [_sessionPlayerID isEqualToString:playerID];
    _sessionPlayerID = nil;
    if (!eligible || !leaderboardID.length || score <= 0) return;
    NSMutableDictionary *players = [[_defaults dictionaryForKey:kPendingScoresKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *scores = [players[playerID] mutableCopy] ?: [NSMutableDictionary dictionary];
    scores[leaderboardID] = @(MAX(score, [scores[leaderboardID] longLongValue]));
    players[playerID] = scores;
    [_defaults setObject:players forKey:kPendingScoresKey];
}

- (NSDictionary<NSString *, NSNumber *> *)pendingScoresForPlayer:(NSString *)playerID {
    return [[_defaults dictionaryForKey:kPendingScoresKey][playerID] copy] ?: @{};
}

- (void)acknowledgeScore:(int64_t)score leaderboardID:(NSString *)leaderboardID playerID:(NSString *)playerID {
    NSMutableDictionary *players = [[_defaults dictionaryForKey:kPendingScoresKey] mutableCopy];
    NSMutableDictionary *scores = [players[playerID] mutableCopy];
    NSNumber *pending = scores[leaderboardID];
    if (!pending || pending.longLongValue > score) return;
    [scores removeObjectForKey:leaderboardID];
    if (scores.count) players[playerID] = scores;
    else [players removeObjectForKey:playerID];
    [_defaults setObject:players forKey:kPendingScoresKey];
}

@end
