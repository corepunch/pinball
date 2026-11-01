#import "PBGameCenter.h"
#import "PBGameCenterScores.h"
#import <GameKit/GameKit.h>

static void *kAccessPointPresentationContext = &kAccessPointPresentationContext;

@implementation PBGameCenter {
    __weak UIViewController *_presenter;
    PBGameCenterScores *_scores;
    NSDictionary<NSString *, NSString *> *_leaderboards;
    NSMutableSet<NSArray<NSString *> *> *_submissionsInFlight;
    BOOL _started, _authenticationPresented;
}

@synthesize showsAccessPoint = _showsAccessPoint;

- (instancetype)initWithBundle:(NSBundle *)bundle {
    if ((self = [super init])) {
        _showsAccessPoint = YES;
        _scores = [[PBGameCenterScores alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];
        _submissionsInFlight = [NSMutableSet set];
        NSURL *url = [bundle URLForResource:@"GameCenter" withExtension:@"json" subdirectory:@"GameData"];
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        NSDictionary *config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        _leaderboards = config[@"leaderboards"] ?: @{};
    }
    return self;
}

- (void)setShowsAccessPoint:(BOOL)showsAccessPoint {
    _showsAccessPoint = showsAccessPoint;
    if (_started) GKAccessPoint.shared.active = showsAccessPoint;
}

- (NSString *)currentPlayerID {
    GKLocalPlayer *player = GKLocalPlayer.localPlayer;
    return player.isAuthenticated ? player.gamePlayerID : nil;
}

- (void)startWithViewController:(UIViewController *)viewController {
    _presenter = viewController;
    GKAccessPoint *accessPoint = GKAccessPoint.shared;
    accessPoint.parentWindow = viewController.view.window;
    accessPoint.location = GKAccessPointLocationTopLeading;
    if (_started) return;
    _started = YES;
    [accessPoint addObserver:self forKeyPath:@"isPresentingGameCenter" options:0 context:kAccessPointPresentationContext];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(authenticationChanged:)
                                               name:GKPlayerAuthenticationDidChangeNotificationName object:nil];
    __weak typeof(self) weakSelf = self;
    GKLocalPlayer.localPlayer.authenticateHandler = ^(UIViewController *controller, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleAuthenticationController:controller error:error];
        });
    };
}

- (void)handleAuthenticationController:(UIViewController *)controller error:(NSError *)error {
    if (controller) {
        if (_authenticationPresented || !_presenter.view.window) return;
        _authenticationPresented = YES;
        [self updatePresentation];
        [_presenter presentViewController:controller animated:YES completion:nil];
        return;
    }
    _authenticationPresented = NO;
    [self updatePresentation];
    // The native access point also offers sign-in after a player declines it.
    GKAccessPoint.shared.active = self.showsAccessPoint;
    if (error) NSLog(@"Game Center sign-in unavailable: %@", error.localizedDescription);
    [self retryPendingScores];
}

- (void)authenticationChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self retryPendingScores]; });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context == kAccessPointPresentationContext) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updatePresentation]; });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)updatePresentation {
    if (self.presentationChanged) self.presentationChanged(_authenticationPresented || GKAccessPoint.shared.isPresentingGameCenter);
}

- (void)showLeaderboardForTable:(NSString *)tableIdentifier {
    if (!_started || _authenticationPresented || GKAccessPoint.shared.isPresentingGameCenter) return;
    NSString *identifier = _leaderboards[tableIdentifier];
    if (identifier.length) {
        if (@available(iOS 18.0, *)) {
            [GKAccessPoint.shared triggerAccessPointWithLeaderboardID:identifier
                                                         playerScope:GKLeaderboardPlayerScopeGlobal
                                                           timeScope:GKLeaderboardTimeScopeAllTime handler:^{}];
            return;
        }
    }
    [GKAccessPoint.shared triggerAccessPointWithState:GKGameCenterViewControllerStateLeaderboards handler:^{}];
}

- (void)beginGame { [_scores beginGameForPlayer:[self currentPlayerID]]; }

- (void)finishGameWithScore:(int64_t)score tableIdentifier:(NSString *)tableIdentifier {
    [_scores finishGameWithScore:score leaderboardID:_leaderboards[tableIdentifier] playerID:[self currentPlayerID]];
    [self retryPendingScores];
}

- (void)retryPendingScores {
    if (!_started) return;
    NSString *playerID = [self currentPlayerID];
    if (!playerID.length) return;
    NSDictionary<NSString *, NSNumber *> *pending = [_scores pendingScoresForPlayer:playerID];
    for (NSString *leaderboardID in pending) {
        NSArray *key = @[playerID, leaderboardID];
        if ([_submissionsInFlight containsObject:key]) continue;
        int64_t score = pending[leaderboardID].longLongValue;
        [_submissionsInFlight addObject:key];
        [GKLeaderboard submitScore:(NSInteger)score context:0 player:GKLocalPlayer.localPlayer leaderboardIDs:@[leaderboardID]
                 completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_submissionsInFlight removeObject:key];
                if (error) {
                    // Keep the player-scoped best score for the next auth/foreground/game-over retry.
                    NSLog(@"Game Center score upload deferred: %@", error.localizedDescription);
                    return;
                }
                [self->_scores acknowledgeScore:score leaderboardID:leaderboardID playerID:playerID];
                [self retryPendingScores];
            });
        }];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_started) [GKAccessPoint.shared removeObserver:self forKeyPath:@"isPresentingGameCenter" context:kAccessPointPresentationContext];
}

@end
