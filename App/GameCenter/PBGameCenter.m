#import "PBGameCenter.h"
#import "PBGameCenterScores.h"
#import <GameKit/GameKit.h>
#import <Network/Network.h>

static void *kAccessPointPresentationContext = &kAccessPointPresentationContext;

@implementation PBGameCenter {
    __weak UIViewController *_presenter;
    PBGameCenterScores *_scores;
    UIViewController *_pendingAuthenticationController;
    NSDictionary<NSString *, NSString *> *_leaderboards;
    NSMutableSet<NSArray<NSString *> *> *_submissionsInFlight;
    nw_path_monitor_t _pathMonitor;
    NSTimer *_retryTimer;
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
    if (_started) GKAccessPoint.shared.active = showsAccessPoint && [self currentPlayerID].length > 0;
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
    if (_started) { [self presentPendingAuthentication]; return; }
    _started = YES;
    [accessPoint addObserver:self forKeyPath:@"isPresentingGameCenter" options:0 context:kAccessPointPresentationContext];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(authenticationChanged:)
                                               name:GKPlayerAuthenticationDidChangeNotificationName object:nil];
    __weak typeof(self) weakSelf = self;
    // Observe connectivity on the main queue, which owns the outbox and in-flight set.
    _pathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_pathMonitor, dispatch_get_main_queue());
    nw_path_monitor_set_update_handler(_pathMonitor, ^(nw_path_t path) {
        if (nw_path_get_status(path) == nw_path_status_satisfied) [weakSelf retryPendingScores];
    });
    nw_path_monitor_start(_pathMonitor);
    // Reachability does not prove Apple is reachable; retry transient service failures too.
    _retryTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *timer) {
        [weakSelf presentPendingAuthentication];
        [weakSelf retryPendingScores];
    }];
    GKLocalPlayer.localPlayer.authenticateHandler = ^(UIViewController *controller, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf handleAuthenticationController:controller error:error];
        });
    };
}

- (void)handleAuthenticationController:(UIViewController *)controller error:(NSError *)error {
    [_scores playerDidChange:[self currentPlayerID]];
    if (controller) {
        _pendingAuthenticationController = controller;
        [self presentPendingAuthentication];
        return;
    }
    _pendingAuthenticationController = nil;
    _authenticationPresented = NO;
    [self updatePresentation];
    GKAccessPoint.shared.active = self.showsAccessPoint && [self currentPlayerID].length > 0;
    if (error) NSLog(@"Game Center sign-in unavailable: %@", error.localizedDescription);
    [self retryPendingScores];
}

- (void)presentPendingAuthentication {
    UIViewController *controller = _pendingAuthenticationController;
    if (!controller || _authenticationPresented || !_presenter.view.window ||
        _presenter.presentedViewController ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    _pendingAuthenticationController = nil;
    _authenticationPresented = YES;
    [self updatePresentation];
    [_presenter presentViewController:controller animated:YES completion:nil];
}

- (void)authenticationChanged:(NSNotification *)notification {
    // Capture before hopping queues so a quick A -> B -> A change is not collapsed to A.
    NSString *playerID = [[self currentPlayerID] copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_scores playerDidChange:playerID];
        GKAccessPoint.shared.active = self.showsAccessPoint && [self currentPlayerID].length > 0;
        [self retryPendingScores];
    });
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
    if (![self currentPlayerID].length) {
        if (_authenticationPresented || !_presenter.view.window || _presenter.presentedViewController) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Game Center unavailable"
            message:@"Sign in to Game Center in Settings to view scores. You can keep playing without signing in."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [_presenter presentViewController:alert animated:YES completion:nil];
        return;
    }
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
    if (!_started || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
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
    if (_pathMonitor) nw_path_monitor_cancel(_pathMonitor);
    [_retryTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_started) [GKAccessPoint.shared removeObserver:self forKeyPath:@"isPresentingGameCenter" context:kAccessPointPresentationContext];
}

@end
